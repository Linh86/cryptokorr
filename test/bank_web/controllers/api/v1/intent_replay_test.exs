defmodule BankWeb.API.V1.IntentReplayTest do
  use BankWeb.ConnCase, async: true

  alias Bank.Audit
  alias Bank.Fixtures

  describe "GET /v1/intents/:id/replay" do
    test "returns a deterministic bundle for a known intent", %{conn: conn} do
      intent = Fixtures.agent_intent()
      rule = Fixtures.policy_rule()
      claim = Fixtures.trust_assessment(intent: intent, current: true)
      sim = Fixtures.simulation_report(intent: intent, current: true)

      decision =
        Fixtures.decision_envelope(
          intent: intent,
          current: true,
          policy_snapshot_ref: %{"rule_ids" => [rule.id]}
        )

      plan = Fixtures.execution_plan(decision: decision)

      {:ok, _} =
        Audit.append_event(%{
          actor: :runtime,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: intent.id,
          correlation_id: intent.id
        })

      conn = get(conn, ~p"/v1/intents/#{intent.id}/replay")
      body = json_response(conn, 200)

      assert body["intent"]["id"] == intent.id

      assert Enum.map(body["policy_snapshot"], & &1["id"]) == [rule.id]
      assert Enum.map(body["trust_assessments"], & &1["id"]) == [claim.id]
      assert Enum.map(body["simulations"], & &1["id"]) == [sim.id]
      assert Enum.map(body["decisions"], & &1["id"]) == [decision.id]
      assert Enum.map(body["plans"], & &1["id"]) == [plan.id]

      assert length(body["audit"]) == 1
      [audit] = body["audit"]
      assert audit["correlation_id"] == intent.id
    end

    test "returns 404 for a missing intent", %{conn: conn} do
      missing_id = Ecto.UUID.generate()
      conn = get(conn, ~p"/v1/intents/#{missing_id}/replay")
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "returns 404 for a malformed id", %{conn: conn} do
      conn = get(conn, "/v1/intents/not-a-uuid/replay")
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "same intent id returns the same bundle on repeated calls (plus new events)",
         %{conn: conn} do
      intent = Fixtures.agent_intent()

      body1 = json_response(get(conn, ~p"/v1/intents/#{intent.id}/replay"), 200)
      body2 = json_response(get(conn, ~p"/v1/intents/#{intent.id}/replay"), 200)

      assert body1 == body2

      {:ok, _} =
        Audit.append_event(%{
          actor: :runtime,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: intent.id,
          correlation_id: intent.id
        })

      body3 = json_response(get(conn, ~p"/v1/intents/#{intent.id}/replay"), 200)
      assert length(body3["audit"]) == length(body1["audit"]) + 1
    end
  end
end
