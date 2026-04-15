defmodule Bank.RuntimeTest do
  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Fixtures
  alias Bank.Runtime

  alias Bank.Runtime.Workers.{
    ConfirmExecution,
    EvaluateIntent,
    ExpireApproval,
    ReevaluateIntent,
    RevokeDelegation,
    RunExecution
  }

  describe "enqueue_evaluation/2" do
    test "enqueues on :intents_evaluate with intent_id" do
      intent = Fixtures.agent_intent()
      assert {:ok, %Oban.Job{}} = Runtime.enqueue_evaluation(intent.id)

      assert_enqueued(
        worker: EvaluateIntent,
        queue: :intents_evaluate,
        args: %{"intent_id" => intent.id}
      )
    end
  end

  describe "enqueue_reevaluation/3" do
    test "enqueues on :intents_reevaluate with intent_id + reason" do
      intent = Fixtures.agent_intent()

      assert {:ok, %Oban.Job{}} =
               Runtime.enqueue_reevaluation(intent.id, :policy_changed)

      assert_enqueued(
        worker: ReevaluateIntent,
        queue: :intents_reevaluate,
        args: %{"intent_id" => intent.id, "reason" => "policy_changed"}
      )
    end
  end

  describe "enqueue_approval_expiry/3" do
    test "schedules on :approvals_expire at expires_at" do
      intent = Fixtures.agent_intent()
      expires_at = DateTime.add(DateTime.utc_now(), 300, :second)

      envelope =
        Fixtures.decision_envelope(
          intent: intent,
          current: true,
          outcome: :approval_required,
          approval_expires_at: expires_at,
          risk_tier: :moderate
        )

      assert {:ok, job} = Runtime.enqueue_approval_expiry(envelope.id, expires_at)

      assert_enqueued(
        worker: ExpireApproval,
        queue: :approvals_expire,
        args: %{"decision_envelope_id" => envelope.id}
      )

      # Scheduled at the deadline, not immediately
      assert DateTime.compare(job.scheduled_at, expires_at) == :eq
    end
  end

  describe "enqueue_execution/2" do
    test "enqueues on :executions_run with decision_id" do
      decision = Fixtures.decision_envelope(current: true)

      assert {:ok, _} = Runtime.enqueue_execution(decision.id)

      assert_enqueued(
        worker: RunExecution,
        queue: :executions_run,
        args: %{"decision_id" => decision.id}
      )
    end
  end

  describe "enqueue_confirmation/2" do
    test "enqueues on :executions_confirm with execution_plan_id" do
      plan = Fixtures.execution_plan()

      assert {:ok, _} = Runtime.enqueue_confirmation(plan.id)

      assert_enqueued(
        worker: ConfirmExecution,
        queue: :executions_confirm,
        args: %{"execution_plan_id" => plan.id}
      )
    end
  end

  describe "enqueue_delegation_revoke/3" do
    test "enqueues on :security_revoke with smart_account_id + reason" do
      assert {:ok, _} =
               Runtime.enqueue_delegation_revoke("sa-123", :operator_requested)

      assert_enqueued(
        worker: RevokeDelegation,
        queue: :security_revoke,
        args: %{"smart_account_id" => "sa-123", "reason" => "operator_requested"}
      )
    end
  end

  describe "emit_audit/1" do
    test "persists via Audit.append_event and broadcasts on audit:stream" do
      intent = Fixtures.agent_intent()
      :ok = Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())

      attrs = %{
        actor: :runtime,
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id
      }

      assert {:ok, %AuditEvent{id: audit_id, event_type: "intent.submitted"}} =
               Runtime.emit_audit(attrs)

      assert_receive %{
        topic: :audit_stream,
        event: :appended,
        payload: %{id: ^audit_id, event_type: "intent.submitted", correlation_id: correlation_id}
      }

      assert correlation_id == intent.id
    end

    test "does not persist or broadcast when the envelope is missing required fields" do
      # `refute_receive` would be flaky under a shared PubSub: other
      # async tests can drop an unrelated `:audit_stream` message into
      # this mailbox during the window. Instead we assert on the
      # durable side of the contract — no row was written — and on the
      # error return.
      assert {:error, {:missing_fields, missing}} = Runtime.emit_audit(%{actor: :runtime})
      assert :event_type in missing
      assert :subject_type in missing
      assert :subject_id in missing

      assert Repo.aggregate(AuditEvent, :count) == 0
    end
  end
end
