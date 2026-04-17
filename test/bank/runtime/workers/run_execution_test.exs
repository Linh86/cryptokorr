defmodule Bank.Runtime.Workers.RunExecutionTest do
  # async: false because the pause-state GenServer is global and
  # tests in this module mutate it.
  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.PubSub
  alias Bank.Runtime.Workers.RunExecution
  alias Bank.Security
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  # Build a decided auto_exec envelope + active plan + active delegation
  # with the intent already at :decided — the state RunExecution expects
  # to find on a freshly-decided envelope.
  defp scenario(opts \\ []) do
    counterparty = Fixtures.counterparty()
    label = Fixtures.address_label(counterparty: counterparty, chain: "base")

    intent =
      Fixtures.agent_intent(
        counterparty: counterparty,
        target_address_label_id: label.id,
        amount: Decimal.new("25")
      )

    {:ok, intent} =
      intent
      |> AgentIntent.current_pointer_changeset(%{state: :decided})
      |> Repo.update()

    decision =
      Fixtures.decision_envelope(
        intent: intent,
        outcome: :auto_exec,
        state: :decided,
        current: true
      )

    smart_account_id = "sa_run_exec_#{System.unique_integer([:positive])}"

    plan =
      Fixtures.execution_plan(
        decision: decision,
        intent_id: intent.id,
        smart_account_id: smart_account_id,
        signing_requirements: %{"delegation_id" => "del_primary"}
      )

    delegation_state = Keyword.get(opts, :delegation_state, :active)
    _delegation = insert_delegation(smart_account_id, delegation_state)

    %{intent: intent, decision: decision, plan: plan, label: label, counterparty: counterparty}
  end

  defp insert_delegation(smart_account_id, :active) do
    Fixtures.delegation(
      smart_account_id: smart_account_id,
      delegation_id: "del_#{smart_account_id}",
      state: :active
    )
  end

  defp insert_delegation(smart_account_id, state) when state in [:revoking, :revoked, :expired] do
    # Insert an active row first then flip state, so we cover the "lost
    # between plan creation and dispatch" path.
    active =
      Fixtures.delegation(
        smart_account_id: smart_account_id,
        delegation_id: "del_#{smart_account_id}",
        state: :active
      )

    {:ok, updated} =
      active
      |> Ecto.Changeset.change(%{state: state})
      |> Repo.update()

    updated
  end

  defp stub_adapter_response(status, body) do
    Req.Test.stub(Bank.AdapterClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  describe "happy path" do
    test "202 accepted advances plan :prepared → :signing and intent :decided → :executing" do
      %{intent: intent, decision: decision, plan: plan} = scenario()

      :ok = PubSub.subscribe(PubSub.intent(intent.id))
      :ok = PubSub.subscribe(PubSub.audit_stream())

      stub_adapter_response(202, %{"accepted" => true, "execution_plan_id" => plan.id})

      assert :ok = perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{execution_status: :signing, active: true} =
               Repo.get!(ExecutionPlan, plan.id)

      assert %AgentIntent{state: :executing, current_execution_plan_id: epid} =
               Repo.get!(AgentIntent, intent.id)

      assert epid == plan.id

      # Runtime broadcasts on the intent topic (execution + intent
      # lifecycle) and on the audit stream.
      assert_receive %{
        topic: :intent_lifecycle,
        event: :execution_updated,
        payload: %{execution_status: :signing}
      }

      assert_receive %{
        topic: :intent_lifecycle,
        event: :state_changed,
        payload: %{from: :decided, to: :executing}
      }

      assert_receive %{topic: :audit_stream, event: :appended}

      # Audit trail captures both the plan and intent transitions with
      # :runtime as the actor.
      execution_events =
        Repo.all(from e in AuditEvent, where: e.event_type == "execution.signing")

      assert length(execution_events) == 1
      assert hd(execution_events).actor == :runtime

      intent_events =
        Repo.all(from e in AuditEvent, where: e.event_type == "intent.state_changed")

      assert length(intent_events) == 1
    end
  end

  describe "adapter transient failures trigger Oban retry" do
    test "transport error → {:error, :adapter_unavailable}" do
      %{decision: decision, plan: plan, intent: intent} = scenario()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :adapter_unavailable} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      # Nothing mutated — plan and intent stay where they were.
      assert %ExecutionPlan{execution_status: :prepared} = Repo.get!(ExecutionPlan, plan.id)
      assert %AgentIntent{state: :decided} = Repo.get!(AgentIntent, intent.id)
    end

    test "5xx → {:error, {:adapter_error, status}}" do
      %{decision: decision, plan: plan, intent: intent} = scenario()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Plug.Conn.resp(conn, 503, "upstream unavailable")
      end)

      assert {:error, {:adapter_error, 503}} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{execution_status: :prepared} = Repo.get!(ExecutionPlan, plan.id)
      assert %AgentIntent{state: :decided} = Repo.get!(AgentIntent, intent.id)
    end
  end

  describe "adapter terminal failures abort the plan" do
    test "4xx → cancel :adapter_rejected, plan :aborted, intent :blocked" do
      %{decision: decision, plan: plan, intent: intent} = scenario()

      :ok = PubSub.subscribe(PubSub.intent(intent.id))

      stub_adapter_response(422, %{"error" => %{"code" => "unsupported_chain"}})

      assert {:cancel, :adapter_rejected} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{
               execution_status: :aborted,
               final_outcome: :aborted,
               final_reason: reason
             } = Repo.get!(ExecutionPlan, plan.id)

      assert reason =~ "adapter_rejected:422"

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)

      assert_receive %{
        topic: :intent_lifecycle,
        event: :execution_updated,
        payload: %{execution_status: :aborted}
      }

      assert_receive %{
        topic: :intent_lifecycle,
        event: :state_changed,
        payload: %{from: :decided, to: :blocked}
      }
    end

    test "invalid 2xx body → adapter_rejected abort path" do
      %{decision: decision, plan: plan, intent: intent} = scenario()

      stub_adapter_response(200, %{"something" => "else"})

      assert {:cancel, :adapter_rejected} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{execution_status: :aborted} = Repo.get!(ExecutionPlan, plan.id)
      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end

    test "target not resolvable → cancel :target_not_resolvable, plan :aborted" do
      # Counterparty with NO address labels on the intent's chain — the
      # client has nothing to resolve and returns :no_label.
      counterparty = Fixtures.counterparty()

      intent =
        Fixtures.agent_intent(
          counterparty: counterparty,
          chain: "base"
        )

      {:ok, intent} =
        intent
        |> AgentIntent.current_pointer_changeset(%{state: :decided})
        |> Repo.update()

      decision =
        Fixtures.decision_envelope(
          intent: intent,
          outcome: :auto_exec,
          state: :decided,
          current: true
        )

      smart_account_id = "sa_unresolvable_#{System.unique_integer([:positive])}"

      plan =
        Fixtures.execution_plan(
          decision: decision,
          intent_id: intent.id,
          smart_account_id: smart_account_id
        )

      _ = insert_delegation(smart_account_id, :active)

      # The worker must never reach the network for this case.
      Req.Test.stub(Bank.AdapterClient, fn _ ->
        flunk("AdapterClient called despite unresolvable target")
      end)

      assert {:cancel, :target_not_resolvable} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{
               execution_status: :aborted,
               final_reason: reason
             } = Repo.get!(ExecutionPlan, plan.id)

      assert reason =~ "target_not_resolvable"
      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end
  end

  describe "delegation gate" do
    test "delegation in :revoking aborts the plan before any HTTP call" do
      %{decision: decision, plan: plan, intent: intent} = scenario(delegation_state: :revoking)

      Req.Test.stub(Bank.AdapterClient, fn _ ->
        flunk("AdapterClient called despite inactive delegation")
      end)

      assert {:cancel, :delegation_not_active} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{
               execution_status: :aborted,
               final_reason: "delegation_not_active"
             } = Repo.get!(ExecutionPlan, plan.id)

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end
  end

  describe "pause gate" do
    test "pause toggled before perform aborts the plan and never reaches the adapter" do
      %{decision: decision, plan: plan, intent: intent} = scenario()

      :ok = PubSub.subscribe(PubSub.intent(intent.id))

      Req.Test.stub(Bank.AdapterClient, fn _ ->
        flunk("AdapterClient called despite paused runtime")
      end)

      # Pause flips on after enqueue (simulating the race the gate
      # exists to close).
      {:ok, :paused} = Security.pause(:global)

      assert {:cancel, :runtime_paused} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{
               execution_status: :aborted,
               final_outcome: :aborted,
               final_reason: "runtime_paused"
             } = Repo.get!(ExecutionPlan, plan.id)

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)

      # Audit + realtime reflect the actual outcome (aborted), not a
      # fictional dispatch.
      assert_receive %{
        topic: :intent_lifecycle,
        event: :execution_updated,
        payload: %{execution_status: :aborted}
      }

      assert_receive %{
        topic: :intent_lifecycle,
        event: :state_changed,
        payload: %{from: :decided, to: :blocked, reason: "runtime_paused"}
      }

      aborted_events =
        Repo.all(from e in AuditEvent, where: e.event_type == "execution.aborted")

      assert length(aborted_events) == 1
    end

    test "delegation gate runs before pause gate when both fail" do
      # Both delegation revoked AND runtime paused — delegation is the
      # more permanent condition and should be reported.
      %{decision: decision, plan: plan} = scenario(delegation_state: :revoking)

      Req.Test.stub(Bank.AdapterClient, fn _ ->
        flunk("AdapterClient called")
      end)

      {:ok, :paused} = Security.pause(:global)

      assert {:cancel, :delegation_not_active} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{final_reason: "delegation_not_active"} =
               Repo.get!(ExecutionPlan, plan.id)
    end

    test "regression: unpaused runtime still dispatches normally" do
      %{decision: decision, plan: plan} = scenario()

      stub_adapter_response(202, %{"accepted" => true, "execution_plan_id" => plan.id})

      assert :ok = perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{execution_status: :signing} = Repo.get!(ExecutionPlan, plan.id)
    end
  end

  describe "envelope-level gates" do
    test "cancels :not_found for an unknown decision id" do
      assert {:cancel, :not_found} =
               perform_job(RunExecution, %{"decision_id" => Ecto.UUID.generate()})
    end

    test "cancels :not_current when the envelope has been superseded" do
      decision = Fixtures.decision_envelope(current: false, outcome: :auto_exec)

      assert {:cancel, :not_current} =
               perform_job(RunExecution, %{"decision_id" => decision.id})
    end

    test "cancels {:wrong_outcome, outcome} for non-auto_exec envelopes" do
      expires_at = DateTime.add(DateTime.utc_now(), 300, :second)

      decision =
        Fixtures.decision_envelope(
          current: true,
          outcome: :approval_required,
          approval_expires_at: expires_at
        )

      assert {:cancel, {:wrong_outcome, :approval_required}} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %DecisionEnvelope{current: true} = Repo.get!(DecisionEnvelope, decision.id)
    end

    test "cancels :no_active_plan when the decision has no active plan" do
      intent = Fixtures.agent_intent()

      {:ok, intent} =
        intent
        |> AgentIntent.current_pointer_changeset(%{state: :decided})
        |> Repo.update()

      decision =
        Fixtures.decision_envelope(
          intent: intent,
          outcome: :auto_exec,
          state: :decided,
          current: true
        )

      # No execution plan is inserted for this decision.
      assert {:cancel, :no_active_plan} =
               perform_job(RunExecution, %{"decision_id" => decision.id})
    end

    test "cancels {:already_dispatched, status} when the plan is no longer :prepared" do
      %{decision: decision, plan: plan} = scenario()

      {:ok, _} =
        plan
        |> ExecutionPlan.progress_changeset(%{execution_status: :signing})
        |> Repo.update()

      assert {:cancel, {:already_dispatched, :signing}} =
               perform_job(RunExecution, %{"decision_id" => decision.id})
    end

    test "cancels :malformed_args on bad job args" do
      assert {:cancel, :malformed_args} =
               perform_job(RunExecution, %{"wrong" => "shape"})
    end
  end
end
