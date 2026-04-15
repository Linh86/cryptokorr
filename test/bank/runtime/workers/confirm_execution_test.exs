defmodule Bank.Runtime.Workers.ConfirmExecutionTest do
  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.PubSub
  alias Bank.Runtime.Workers.ConfirmExecution

  defp executing_intent do
    {:ok, intent} =
      Fixtures.agent_intent()
      |> AgentIntent.current_pointer_changeset(%{state: :executing})
      |> Repo.update()

    intent
  end

  describe "terminal plans — real intent transition" do
    test ":confirmed plan transitions the intent to :executed" do
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      :ok = PubSub.subscribe(PubSub.intent(intent.id))
      :ok = PubSub.subscribe(PubSub.audit_stream())

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert %AgentIntent{state: :executed, current_execution_plan_id: epid} =
               Repo.get!(AgentIntent, intent.id)

      assert epid == plan.id

      assert_receive %{topic: :intent_lifecycle, event: :execution_updated}
      assert_receive %{topic: :intent_lifecycle, event: :state_changed, payload: %{to: :executed}}
      assert_receive %{topic: :audit_stream, event: :appended}

      # Audit trail recorded the state change.
      [event] = Repo.all(from e in AuditEvent, where: e.event_type == "intent.state_changed")
      assert event.before_ref == %{"state" => "executing"}
      assert event.after_ref == %{"state" => "executed"}
    end

    test ":reverted plan transitions the intent to :blocked" do
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :reverted,
          final_outcome: :reverted,
          final_reason: "simulation mismatch on chain"
        )

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end

    test ":aborted plan also transitions the intent to :blocked" do
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :aborted,
          final_outcome: :aborted,
          final_reason: "operator abort"
        )

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end

    test "idempotent: a second confirm for the same finalised intent cancels as :already_finalised" do
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert {:cancel, :already_finalised} =
               perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})
    end
  end

  describe "non-terminal plans" do
    test "snoozes while the plan is :signing / :broadcasting / :pending_confirmation" do
      intent = executing_intent()

      for status <- [:signing, :broadcasting, :pending_confirmation] do
        plan =
          Fixtures.execution_plan(
            intent_id: intent.id,
            decision: Fixtures.decision_envelope(intent: intent),
            execution_status: status
          )

        assert {:snooze, seconds} =
                 perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

        assert is_integer(seconds) and seconds > 0
      end
    end

    test "cancels with :adapter_pending when the plan is still :prepared" do
      plan = Fixtures.execution_plan(execution_status: :prepared)

      assert {:cancel, :adapter_pending} =
               perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})
    end
  end

  describe "error paths" do
    test "cancels with :not_found for unknown plan id" do
      assert {:cancel, :not_found} =
               perform_job(ConfirmExecution, %{"execution_plan_id" => Ecto.UUID.generate()})
    end

    test "cancels with :malformed_args on bad args" do
      assert {:cancel, :malformed_args} =
               perform_job(ConfirmExecution, %{"wrong" => "shape"})
    end
  end
end
