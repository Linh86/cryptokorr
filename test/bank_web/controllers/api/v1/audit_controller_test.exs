defmodule BankWeb.API.V1.AuditControllerTest do
  use BankWeb.ConnCase, async: true

  setup :setup_api_key_admin

  alias Bank.Audit
  alias Bank.Fixtures

  describe "GET /v1/audit" do
    setup do
      intent = Fixtures.agent_intent()

      {:ok, e1} =
        Audit.append_event(%{
          actor: :runtime,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: intent.id,
          correlation_id: intent.id
        })

      {:ok, e2} =
        Audit.append_event(%{
          actor: :runtime,
          event_type: "decision.decided",
          subject_type: "decision_envelope",
          subject_id: Ecto.UUID.generate(),
          correlation_id: intent.id
        })

      %{intent: intent, e1: e1, e2: e2}
    end

    test "returns events filtered by intent_id", %{conn: conn, intent: intent} do
      conn = get(conn, ~p"/v1/audit?intent_id=#{intent.id}")

      assert %{"data" => events, "page" => %{"next_cursor" => nil}} = json_response(conn, 200)
      assert length(events) == 2

      for event <- events do
        assert event["correlation_id"] == intent.id
        assert event["payload_hash"]
        assert event["schema_version"] == "1"
      end
    end

    test "filters by event_type", %{conn: conn, intent: intent, e1: e1} do
      conn = get(conn, ~p"/v1/audit?intent_id=#{intent.id}&event_type=intent.submitted")

      assert %{"data" => [event]} = json_response(conn, 200)
      assert event["id"] == e1.id
    end

    test "422 on malformed uuid filter", %{conn: conn} do
      conn = get(conn, ~p"/v1/audit?intent_id=not-a-uuid")
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_query"
      assert body["error"]["message"] =~ "intent_id"
    end

    test "422 on malformed timestamp filter", %{conn: conn} do
      conn = get(conn, ~p"/v1/audit?from=notadate")
      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "from"
    end

    test "limit + cursor paginates", %{conn: conn, intent: intent} do
      # extra events
      for _ <- 1..3 do
        Audit.append_event(%{
          actor: :runtime,
          event_type: "execution.prepared",
          subject_type: "execution_plan",
          subject_id: Ecto.UUID.generate(),
          correlation_id: intent.id
        })
      end

      conn1 = get(conn, ~p"/v1/audit?intent_id=#{intent.id}&limit=2")
      body1 = json_response(conn1, 200)
      assert length(body1["data"]) == 2
      assert body1["page"]["next_cursor"]

      cursor = body1["page"]["next_cursor"]
      conn2 = get(conn, ~p"/v1/audit?intent_id=#{intent.id}&limit=2&cursor=#{cursor}")
      body2 = json_response(conn2, 200)
      assert length(body2["data"]) == 2

      # disjoint
      ids1 = body1["data"] |> Enum.map(& &1["id"])
      ids2 = body2["data"] |> Enum.map(& &1["id"])
      assert MapSet.disjoint?(MapSet.new(ids1), MapSet.new(ids2))
    end
  end
end
