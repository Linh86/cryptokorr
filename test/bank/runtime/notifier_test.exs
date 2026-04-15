defmodule Bank.Runtime.NotifierTest do
  use Bank.DataCase, async: true

  alias Bank.Fixtures
  alias Bank.Runtime.Notifier
  alias Bank.Runtime.PubSub

  describe "intent_lifecycle/3" do
    test "broadcasts on intent:{id} with an %AgentIntent{}" do
      intent = Fixtures.agent_intent()
      :ok = PubSub.subscribe(PubSub.intent(intent.id))

      :ok = Notifier.intent_lifecycle(intent, :state_changed, %{from: :submitted, to: :decided})

      assert_receive %{
        topic: :intent_lifecycle,
        event: :state_changed,
        intent_id: iid,
        payload: %{from: :submitted, to: :decided, state: :submitted}
      }

      assert iid == intent.id
    end

    test "broadcasts with a bare intent_id string" do
      intent_id = Ecto.UUID.generate()
      :ok = PubSub.subscribe(PubSub.intent(intent_id))

      :ok = Notifier.intent_lifecycle(intent_id, :decision_updated, %{outcome: :block})

      assert_receive %{topic: :intent_lifecycle, event: :decision_updated, intent_id: ^intent_id}
    end
  end

  describe "approval_queue/3" do
    test "broadcasts on approval:queue" do
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

      :ok = PubSub.subscribe(PubSub.approval_queue())

      :ok =
        Notifier.approval_queue(:enqueued, envelope, %{
          successor_decision_envelope_id: nil
        })

      assert_receive %{
        topic: :approval_queue,
        event: :enqueued,
        decision_envelope_id: eid,
        intent_id: iid,
        payload: %{outcome: :approval_required, risk_tier: :moderate}
      }

      assert eid == envelope.id
      assert iid == intent.id
    end
  end

  describe "dashboard_status/2" do
    test "broadcasts on dashboard:runtime_status" do
      :ok = PubSub.subscribe(PubSub.dashboard_runtime_status())

      :ok = Notifier.dashboard_status(:paused, %{reason: "operator_requested"})

      assert_receive %{
        topic: :dashboard_runtime_status,
        event: :paused,
        payload: %{reason: "operator_requested"}
      }
    end
  end

  describe "security_event/2" do
    test "broadcasts on security:events" do
      :ok = PubSub.subscribe(PubSub.security_events())

      :ok =
        Notifier.security_event(:delegation_revoke_requested, %{
          smart_account_id: "sa-1",
          reason: "operator_requested"
        })

      assert_receive %{
        topic: :security_events,
        event: :delegation_revoke_requested,
        payload: %{smart_account_id: "sa-1"}
      }
    end
  end

  describe "audit_stream/1" do
    test "broadcasts a compact summary on audit:stream" do
      intent = Fixtures.agent_intent()

      {:ok, event} =
        Bank.Audit.append_event(%{
          actor: :runtime,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: intent.id,
          correlation_id: intent.id
        })

      :ok = PubSub.subscribe(PubSub.audit_stream())

      :ok = Notifier.audit_stream(event)

      event_id = event.id
      correlation_id = event.correlation_id

      assert_receive %{
        topic: :audit_stream,
        event: :appended,
        payload: %{
          id: ^event_id,
          event_type: "intent.submitted",
          correlation_id: ^correlation_id
        }
      }
    end
  end

  describe "execution_progressed/2" do
    test "broadcasts to intent:{id} with plan progression details" do
      plan = Fixtures.execution_plan(execution_status: :confirmed, final_outcome: :confirmed)
      :ok = PubSub.subscribe(PubSub.intent(plan.intent_id))

      :ok = Notifier.execution_progressed(plan, :pending_confirmation)

      plan_id = plan.id

      assert_receive %{
        topic: :intent_lifecycle,
        event: :execution_updated,
        payload: %{
          execution_plan_id: ^plan_id,
          prior_status: :pending_confirmation,
          execution_status: :confirmed,
          final_outcome: :confirmed
        }
      }
    end
  end
end
