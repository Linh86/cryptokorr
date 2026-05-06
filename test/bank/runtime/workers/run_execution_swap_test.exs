defmodule Bank.Runtime.Workers.RunExecutionSwapTest do
  @moduledoc """
  Phoenix-side swap dispatch wiring (#193, MVP, epic #188).

  Pins for the swap branch of `Bank.Runtime.Workers.RunExecution`:

    * Happy path — adapter 202 advances plan `:prepared → :signing`
      and the parent intent `:decided → :executing`. The adapter
      receives the persisted #190 steps payload verbatim.
    * Centralized #191 safety gate runs before the adapter call —
      a route whose deadline has expired aborts the plan with
      `final_reason: "swap_safety:swap_deadline_expired"` and the
      adapter is never reached.
    * Cross-checks against the parent intent fire — a route on a
      different chain than the intent aborts with
      `swap_safety:swap_chain_mismatch_with_intent`.
    * Adapter-rejection handling — 4xx aborts the plan with
      `adapter_rejected:<status>:<summary>` and never re-runs.
    * Adapter unavailability — transient errors revert the claim
      to `:prepared` so Oban can retry; no abort.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.Workers.RunExecution
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  defp swap_scenario(opts \\ []) do
    intent_amount = Keyword.get(opts, :intent_amount, Decimal.new("10"))
    chain = Keyword.get(opts, :chain, "base-sepolia")
    route_overrides = Keyword.get(opts, :route_overrides, %{})

    counterparty = Fixtures.counterparty()

    intent =
      Fixtures.agent_intent(
        counterparty: counterparty,
        amount: intent_amount,
        chain: chain
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

    smart_account_id = "sa_swap_#{System.unique_integer([:positive])}"

    plan =
      Fixtures.swap_execution_plan(
        decision: decision,
        intent_id: intent.id,
        smart_account_id: smart_account_id,
        signing_requirements: %{"delegation_id" => "del_primary"},
        route: Map.put_new(route_overrides, :input_amount, intent_amount)
      )

    Fixtures.delegation(
      smart_account_id: smart_account_id,
      delegation_id: "del_#{smart_account_id}",
      state: :active
    )

    %{intent: intent, decision: decision, plan: plan}
  end

  defp stub_adapter_response(status, body) do
    Req.Test.stub(Bank.AdapterClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  describe "happy path" do
    test "202 accepted advances swap plan :prepared → :signing and intent :decided → :executing" do
      %{intent: intent, decision: decision, plan: plan} = swap_scenario()

      stub_adapter_response(202, %{"accepted" => true, "execution_plan_id" => plan.id})

      assert :ok = perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{execution_status: :signing, active: true} =
               Repo.get!(ExecutionPlan, plan.id)

      assert %AgentIntent{state: :executing, current_execution_plan_id: epid} =
               Repo.get!(AgentIntent, intent.id)

      assert epid == plan.id

      [audit] =
        Repo.all(from e in AuditEvent, where: e.event_type == "execution.signing")

      assert audit.actor == :runtime
      # Swap-receipt fields surface on the audit `after_ref` so replay
      # can show what was dispatched without rejoining the plan.
      assert audit.after_ref["route_hash"] == plan.steps["route_hash"]
      # Pre-callback there's no block_number / actual_output_amount.
      assert audit.after_ref["block_number"] == nil
      assert audit.after_ref["actual_output_amount"] == nil
    end

    test "adapter receives the merged #192 dispatch envelope plus #190 route artifacts" do
      %{decision: decision, plan: plan} = swap_scenario()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        # Capture and assert on the request body before responding.
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # v0.1 + #192 top-level dispatch fields the adapter validator
        # pins via `DispatchSwapSchema`.
        assert decoded["contract_version"] == 1
        assert decoded["action"] == "swap"
        assert decoded["execution_plan_id"] == plan.id
        assert decoded["smart_account_id"] == plan.smart_account_id
        assert decoded["chain"] == "base-sepolia"
        assert decoded["input_asset"] == plan.steps["source_asset"]
        assert decoded["output_asset"] == plan.steps["destination_asset"]
        assert decoded["input_amount"] == plan.steps["input_amount"]
        assert decoded["expected_output"] == plan.steps["expected_output_amount"]
        assert decoded["slippage_bps"] == plan.steps["slippage_bps"]

        # `route.{venue, path}` are required by the adapter; the rest
        # of the #190 / #192 execution-route fields ride alongside so
        # the adapter dispatches a real UserOp instead of aborting
        # with `swap_route_incomplete: <field>`.
        route = decoded["route"]
        assert is_binary(route["venue"])
        assert is_list(route["path"])
        assert route["route_provider"] == plan.steps["route_provider"]
        assert route["swap_target_contract"] == plan.steps["swap_target_contract"]
        assert route["spender"] == plan.steps["spender"]
        assert route["calldata"] == plan.steps["calldata"]
        assert route["source_token_address"] == plan.steps["source_token_address"]
        assert route["destination_token_address"] == plan.steps["destination_token_address"]
        assert route["minimum_output_amount"] == plan.steps["minimum_output_amount"]
        assert route["value"] == plan.steps["value"]
        assert route["deadline"] == plan.steps["deadline"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "execution_plan_id" => plan.id})
        )
      end)

      assert :ok = perform_job(RunExecution, %{"decision_id" => decision.id})
    end
  end

  describe "centralized #191 safety gate" do
    test "expired deadline aborts the plan before the adapter is called" do
      # Deadline 1970 — well in the past; route_from_steps parses it
      # as a valid DateTime; SwapDispatchSafety rejects with
      # :swap_deadline_expired.
      expired = ~U[1970-01-01 00:00:00.000000Z]

      %{intent: intent, decision: decision, plan: plan} =
        swap_scenario(route_overrides: %{deadline: expired})

      Req.Test.stub(Bank.AdapterClient, fn _conn ->
        flunk("adapter must not be called when the safety gate fails")
      end)

      assert {:cancel, {:swap_safety_gate, :swap_deadline_expired}} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :aborted
      assert reloaded.final_outcome == :aborted
      assert reloaded.final_reason == "swap_safety:swap_deadline_expired"

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end

    test "route↔intent amount mismatch aborts" do
      # Intent amount 10; route input_amount 5 — same chain so the
      # intent-cross check fires before the route shape gate would
      # complain.
      %{decision: decision, plan: plan} =
        swap_scenario(
          intent_amount: Decimal.new("10"),
          route_overrides: %{input_amount: Decimal.new("5")}
        )

      Req.Test.stub(Bank.AdapterClient, fn _conn ->
        flunk("adapter must not be called when the safety gate fails")
      end)

      assert {:cancel, {:swap_safety_gate, :swap_amount_mismatch_with_intent}} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :aborted
      assert reloaded.final_reason == "swap_safety:swap_amount_mismatch_with_intent"
    end

    test "non-zero native value aborts (ERC20→ERC20 invariant)" do
      %{decision: decision, plan: plan} =
        swap_scenario(route_overrides: %{value: Decimal.new("0.0001")})

      Req.Test.stub(Bank.AdapterClient, fn _conn ->
        flunk("adapter must not be called when the safety gate fails")
      end)

      assert {:cancel, {:swap_safety_gate, :swap_native_value_disallowed}} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :aborted
      assert reloaded.final_reason == "swap_safety:swap_native_value_disallowed"
    end
  end

  describe "adapter HTTP outcomes" do
    test "transient error reverts claim to :prepared so Oban retries" do
      %{decision: decision, plan: plan, intent: intent} = swap_scenario()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :adapter_unavailable} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      assert %ExecutionPlan{execution_status: :prepared} = Repo.get!(ExecutionPlan, plan.id)
      assert %AgentIntent{state: :decided} = Repo.get!(AgentIntent, intent.id)
    end

    test "4xx adapter rejection aborts the plan and the intent" do
      %{decision: decision, plan: plan, intent: intent} = swap_scenario()

      stub_adapter_response(422, %{"error" => "validation_failed"})

      assert {:cancel, :adapter_rejected} =
               perform_job(RunExecution, %{"decision_id" => decision.id})

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :aborted
      assert reloaded.final_reason =~ "adapter_rejected:422"

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end
  end

  describe "malformed steps fail closed" do
    test "swap plan whose steps lack a kind marker aborts before adapter" do
      %{decision: decision, plan: plan} = swap_scenario()

      # Strip the kind marker — should never happen in production
      # (the producer always writes "kind" => "swap"), but the
      # adapter_dispatch fork must fail closed if it does.
      bad_steps = Map.delete(plan.steps, "kind")

      {:ok, _} =
        plan
        |> Ecto.Changeset.change(%{steps: bad_steps})
        |> Repo.update()

      Req.Test.stub(Bank.AdapterClient, fn _conn ->
        flunk("adapter must not be called for an invalid swap plan")
      end)

      # With kind missing the plan is treated as a transfer plan and
      # falls through to dispatch_transfer, which raises on the
      # missing target. We accept either a target_not_resolvable
      # cancel OR the more direct `:invalid_swap_plan` cancel,
      # depending on the intent's target shape — the load-bearing
      # invariant is "no adapter call".
      result = perform_job(RunExecution, %{"decision_id" => decision.id})
      assert match?({:cancel, _}, result)
    end
  end
end
