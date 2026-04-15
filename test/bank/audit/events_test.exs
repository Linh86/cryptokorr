defmodule Bank.Audit.EventsTest do
  use Bank.DataCase, async: true

  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Fixtures

  describe "intent_submitted/2" do
    test "builds an intent.submitted envelope with correlation_id = intent.id" do
      intent = Fixtures.agent_intent()
      attrs = Events.intent_submitted(intent)

      assert attrs.event_type == "intent.submitted"
      assert attrs.subject_type == "agent_intent"
      assert attrs.subject_id == intent.id
      assert attrs.correlation_id == intent.id
      assert attrs.actor == :agent
      assert is_map(attrs.after_ref)
      assert attrs.after_ref.id == intent.id
    end

    test "is writeable through Audit.append_event/1" do
      intent = Fixtures.agent_intent()
      {:ok, event} = Audit.append_event(Events.intent_submitted(intent))
      assert event.event_type == "intent.submitted"
      assert event.correlation_id == intent.id
    end
  end

  describe "intent_state_changed/4" do
    test "captures from/to in before_ref / after_ref" do
      intent = Fixtures.agent_intent()
      attrs = Events.intent_state_changed(intent, :submitted, :evaluating)
      assert attrs.before_ref == %{state: "submitted"}
      assert attrs.after_ref == %{state: "evaluating"}
      assert attrs.event_type == "intent.state_changed"
    end
  end

  describe "decision_decided/2" do
    test "subject is the envelope; correlation is the intent" do
      intent = Fixtures.agent_intent()
      envelope = Fixtures.decision_envelope(intent: intent, current: true)
      attrs = Events.decision_decided(envelope)

      assert attrs.event_type == "decision.decided"
      assert attrs.subject_type == "decision_envelope"
      assert attrs.subject_id == envelope.id
      assert attrs.correlation_id == intent.id
      assert attrs.after_ref.id == envelope.id
      assert attrs.after_ref.outcome == "auto_exec"
    end
  end

  describe "execution_transition/3" do
    test "names the event after the current status" do
      plan = Fixtures.execution_plan()

      attrs = Events.execution_transition(plan, :prepared)

      assert attrs.event_type == "execution.prepared"
      assert attrs.subject_type == "execution_plan"
      assert attrs.correlation_id == plan.intent_id
    end
  end

  describe "policy_revised/3" do
    test "correlation_id is the successor rule id" do
      prior = Fixtures.policy_rule(version: 1)
      successor = Fixtures.policy_rule(version: 2, supersedes_id: prior.id)

      attrs = Events.policy_revised(prior, successor, actor_id: "user-1")

      assert attrs.event_type == "policy.revised"
      assert attrs.subject_id == successor.id
      assert attrs.correlation_id == successor.id
      assert attrs.before_ref.version == 1
      assert attrs.after_ref.version == 2
    end
  end
end
