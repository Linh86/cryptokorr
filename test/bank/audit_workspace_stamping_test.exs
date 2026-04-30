defmodule Bank.AuditWorkspaceStampingTest do
  @moduledoc """
  #158d-b — every runtime audit emitter stamps the audit row with
  the parent's `workspace_id` (passthrough; not in the canonical
  hash). End-to-end tests that route through the production
  `Bank.Audit.Events` builders + `Bank.Audit.append_event/1`.

  The tests deliberately produce two events with the SAME canonical
  payload but DIFFERENT workspace_id and assert:

    * the workspace_id is persisted on the row,
    * the payload_hash is unchanged across the workspace_id values
      (passthrough invariant from #158b's
      `Bank.Audit.Envelope.@passthrough_fields`).

  Plus tests that prove `Bank.Audit.list_events/2` filtered by
  `workspace_id` returns only the matching workspace's events.
  """

  use Bank.DataCase, async: false

  import Bank.Fixtures

  alias Bank.Audit
  alias Bank.Audit.AuditEvent
  alias Bank.Audit.Events
  alias Bank.Workspaces

  defp create_workspace(slug) do
    {:ok, ws} = Workspaces.create_workspace(%{slug: slug, name: "WS #{slug}"})
    ws
  end

  defp emit!(attrs) do
    {:ok, %AuditEvent{} = event} = Audit.append_event(attrs)
    event
  end

  describe "intent_submitted/2" do
    test "stamps workspace_id from the intent's column" do
      ws = create_workspace("emit-intent-#{System.unique_integer([:positive])}")
      intent = agent_intent(workspace_id: ws.id)

      event = emit!(Events.intent_submitted(intent))

      assert event.workspace_id == ws.id
      assert event.event_type == "intent.submitted"
      assert event.subject_id == intent.id
    end

    test "is nil when the intent itself is unscoped (legacy)" do
      intent = agent_intent(workspace_id: nil)
      event = emit!(Events.intent_submitted(intent))
      assert event.workspace_id == nil
    end
  end

  describe "delegation_state_changed/3" do
    test "stamps workspace_id from the delegation's column" do
      ws = create_workspace("emit-del-#{System.unique_integer([:positive])}")

      del =
        delegation(
          workspace_id: ws.id,
          smart_account_id: "sa-emit-#{System.unique_integer([:positive])}"
        )

      event = emit!(Events.delegation_state_changed(del, :pending))

      assert event.workspace_id == ws.id
      assert event.event_type == "delegation.state_changed"
      # Per the existing convention, delegation events are runtime-
      # scoped: correlation_id stays nil. workspace_id rides
      # alongside as a passthrough hint.
      assert event.correlation_id == nil
    end
  end

  describe "execution events stamp from the plan's workspace_id (#158d → #158d-b)" do
    test "execution_transition/3, manually_requested, auto_dispatched all stamp from plan.workspace_id" do
      ws = create_workspace("emit-exec-#{System.unique_integer([:positive])}")
      intent = agent_intent(workspace_id: ws.id)
      decision = decision_envelope(intent: intent, current: true)
      plan = execution_plan(decision: decision, workspace_id: ws.id)

      transition = emit!(Events.execution_transition(plan, :prepared))
      assert transition.workspace_id == ws.id

      manual = emit!(Events.execution_manually_requested(plan, actor_id: nil))
      assert manual.workspace_id == ws.id

      auto = emit!(Events.execution_auto_dispatched(plan, actor_id: nil))
      assert auto.workspace_id == ws.id
    end
  end

  describe "derived runtime events take :workspace_id from opts" do
    test "trust_assessed / simulation_produced / decision_decided / approval_* respect opts" do
      ws_a = create_workspace("emit-derived-a-#{System.unique_integer([:positive])}")
      ws_b = create_workspace("emit-derived-b-#{System.unique_integer([:positive])}")

      intent_a = agent_intent(workspace_id: ws_a.id)
      intent_b = agent_intent(workspace_id: ws_b.id)

      claim_a = trust_assessment(intent: intent_a)
      claim_b = trust_assessment(intent: intent_b)

      sim_a = simulation_report(intent: intent_a)
      sim_b = simulation_report(intent: intent_b)

      env_a = decision_envelope(intent: intent_a, current: false)
      env_b = decision_envelope(intent: intent_b, current: false)

      e1 = emit!(Events.trust_assessed(claim_a, workspace_id: ws_a.id))
      e2 = emit!(Events.trust_assessed(claim_b, workspace_id: ws_b.id))
      assert e1.workspace_id == ws_a.id
      assert e2.workspace_id == ws_b.id

      e3 = emit!(Events.simulation_produced(sim_a, workspace_id: ws_a.id))
      e4 = emit!(Events.simulation_produced(sim_b, workspace_id: ws_b.id))
      assert e3.workspace_id == ws_a.id
      assert e4.workspace_id == ws_b.id

      e5 = emit!(Events.decision_decided(env_a, workspace_id: ws_a.id))
      e6 = emit!(Events.decision_decided(env_b, workspace_id: ws_b.id))
      assert e5.workspace_id == ws_a.id
      assert e6.workspace_id == ws_b.id

      successor_a = decision_envelope(intent: intent_a, current: false)

      grant =
        emit!(
          Events.approval_granted(env_a, successor_a,
            actor_id: "operator-1",
            workspace_id: ws_a.id
          )
        )

      assert grant.workspace_id == ws_a.id

      reject =
        emit!(
          Events.approval_rejected(env_a, successor_a,
            actor_id: "operator-1",
            workspace_id: ws_a.id
          )
        )

      assert reject.workspace_id == ws_a.id
    end
  end

  describe "Audit.list_events/2 :workspace_id filter narrows to the stamped scope" do
    test "events stamped to ws_a appear in the ws_a slice; ws_b events do not" do
      ws_a = create_workspace("emit-list-a-#{System.unique_integer([:positive])}")
      ws_b = create_workspace("emit-list-b-#{System.unique_integer([:positive])}")
      intent_a = agent_intent(workspace_id: ws_a.id)
      intent_b = agent_intent(workspace_id: ws_b.id)

      e_a = emit!(Events.intent_submitted(intent_a))
      e_b = emit!(Events.intent_submitted(intent_b))

      %{events: only_a} =
        Audit.list_events(%{event_type: "intent.submitted", workspace_id: ws_a.id})

      ids = Enum.map(only_a, & &1.id)
      assert e_a.id in ids
      refute e_b.id in ids
    end
  end

  describe "payload_hash invariance" do
    test "two identical events emitted under different workspaces share payload_hash" do
      ws_a = create_workspace("hash-a-#{System.unique_integer([:positive])}")
      ws_b = create_workspace("hash-b-#{System.unique_integer([:positive])}")

      # Same intent shape but different workspace assignment.
      cp_a = counterparty(workspace_id: ws_a.id)
      cp_b = counterparty(workspace_id: ws_b.id)

      same_subject_id = Ecto.UUID.generate()
      ts = DateTime.from_naive!(~N[2026-04-15 12:00:00.000000], "Etc/UTC")
      payload_hash_seed = "hash-invariance-test"

      attrs_a = %{
        actor: :runtime,
        actor_id: nil,
        event_type: "test.workspace_hash_invariance",
        subject_type: "test_subject",
        subject_id: same_subject_id,
        correlation_id: same_subject_id,
        ts: ts,
        after_ref: %{seed: payload_hash_seed},
        workspace_id: ws_a.id
      }

      attrs_b = Map.put(attrs_a, :workspace_id, ws_b.id)

      event_a = emit!(attrs_a)
      event_b = emit!(attrs_b)

      assert event_a.payload_hash == event_b.payload_hash,
             "payload_hash MUST NOT depend on workspace_id (passthrough field)"

      assert event_a.workspace_id == ws_a.id
      assert event_b.workspace_id == ws_b.id

      # Bypass unused alias warnings.
      _ = {cp_a, cp_b}
    end
  end
end
