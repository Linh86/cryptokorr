defmodule BankWeb.API.V1.IntentCancelControllerTest do
  @moduledoc """
  Live tests for `POST /v1/intents/:id/cancel` (issue #139).

  Pin the cancel contract end-to-end: state transition,
  `intent.cancelled` audit event with reason, idempotent re-cancel,
  and the wrong-state / not-found / invalid-body error envelopes.
  """

  use BankWeb.ConnCase, async: true

  setup :setup_api_key_admin

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  describe "POST /v1/intents/:id/cancel — happy paths" do
    test "cancels a submitted intent and writes intent.cancelled audit", %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn =
        post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{
          "reason" => "operator changed mind"
        })

      body = json_response(conn, 200)

      assert body["intent_id"] == intent.id
      assert body["state"] == "cancelled"
      assert body["idempotent"] == false
      assert body["reason"] == "operator changed mind"
      assert body["intent"]["state"] == "cancelled"
      assert body["links"]["self"] == "/v1/intents/#{intent.id}"

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :cancelled

      audit = audit_for(intent.id, "intent.cancelled")
      assert audit, "expected an intent.cancelled audit event"
      assert audit.subject_id == intent.id
      assert audit.correlation_id == intent.id
      assert audit.actor == :user
      assert audit.before_ref["state"] == "submitted"
      assert audit.after_ref["state"] == "cancelled"
      assert audit.after_ref["reason"] == "operator changed mind"
    end

    test "cancels a decided intent", %{conn: conn} do
      intent =
        Fixtures.agent_intent()
        |> Ecto.Changeset.change(%{state: :decided})
        |> Repo.update!()

      conn =
        post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{
          "reason" => "supersession"
        })

      body = json_response(conn, 200)
      assert body["state"] == "cancelled"
      assert body["idempotent"] == false

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :cancelled

      audit = audit_for(intent.id, "intent.cancelled")
      assert audit.before_ref["state"] == "decided"
    end

    test "cancels an evaluating intent", %{conn: conn} do
      intent =
        Fixtures.agent_intent()
        |> Ecto.Changeset.change(%{state: :evaluating})
        |> Repo.update!()

      conn =
        post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{
          "reason" => "policy change"
        })

      body = json_response(conn, 200)
      assert body["state"] == "cancelled"
      assert body["idempotent"] == false
    end
  end

  describe "POST /v1/intents/:id/cancel — idempotent re-cancel" do
    test "re-cancelling a cancelled intent returns 200 with idempotent=true", %{conn: conn} do
      intent = Fixtures.agent_intent()

      first =
        post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{"reason" => "first"})
        |> json_response(200)

      assert first["idempotent"] == false

      audits_before =
        Repo.all(
          from e in AuditEvent,
            where: e.event_type == "intent.cancelled" and e.subject_id == ^intent.id
        )

      second =
        post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{"reason" => "second"})
        |> json_response(200)

      assert second["idempotent"] == true
      assert second["state"] == "cancelled"
      assert second["intent_id"] == intent.id

      # Re-cancel must not write another audit event.
      audits_after =
        Repo.all(
          from e in AuditEvent,
            where: e.event_type == "intent.cancelled" and e.subject_id == ^intent.id
        )

      assert length(audits_after) == length(audits_before)
    end
  end

  describe "POST /v1/intents/:id/cancel — wrong state" do
    test "rejects an executing intent with 409 wrong_state", %{conn: conn} do
      intent =
        Fixtures.agent_intent()
        |> Ecto.Changeset.change(%{state: :executing})
        |> Repo.update!()

      conn =
        post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{"reason" => "halt"})

      body = json_response(conn, 409)
      assert body["error"]["code"] == "wrong_state"
      assert body["error"]["message"] =~ "executing"
      # The hint must steer operators to the security surface.
      assert body["error"]["hint"] =~ "security"

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :executing
    end

    test "rejects an executed intent with 409 wrong_state", %{conn: conn} do
      intent =
        Fixtures.agent_intent()
        |> Ecto.Changeset.change(%{state: :executed})
        |> Repo.update!()

      conn = post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{"reason" => "n/a"})
      body = json_response(conn, 409)
      assert body["error"]["code"] == "wrong_state"
      assert body["error"]["message"] =~ "executed"
    end

    test "rejects a blocked intent with 409 wrong_state", %{conn: conn} do
      intent =
        Fixtures.agent_intent()
        |> Ecto.Changeset.change(%{state: :blocked})
        |> Repo.update!()

      conn = post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{"reason" => "n/a"})
      body = json_response(conn, 409)
      assert body["error"]["code"] == "wrong_state"
    end

    test "rejects an expired intent with 409 wrong_state", %{conn: conn} do
      intent =
        Fixtures.agent_intent()
        |> Ecto.Changeset.change(%{state: :expired})
        |> Repo.update!()

      conn = post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{"reason" => "n/a"})
      body = json_response(conn, 409)
      assert body["error"]["code"] == "wrong_state"
    end
  end

  describe "POST /v1/intents/:id/cancel — invalid body" do
    test "rejects a missing reason with 422", %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn = post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["message"] =~ "reason"

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :submitted
    end

    test "rejects a blank reason with 422", %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn = post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{"reason" => "   "})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end

    test "rejects a non-string reason with 422", %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn = post(conn, ~p"/v1/intents/#{intent.id}/cancel", %{"reason" => 42})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end
  end

  describe "POST /v1/intents/:id/cancel — not found" do
    test "returns 404 for an unknown id", %{conn: conn} do
      missing = Ecto.UUID.generate()

      conn = post(conn, ~p"/v1/intents/#{missing}/cancel", %{"reason" => "n/a"})
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "returns 404 for a malformed id", %{conn: conn} do
      conn = post(conn, "/v1/intents/not-a-uuid/cancel", %{"reason" => "n/a"})
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end
  end

  defp audit_for(intent_id, event_type) do
    Repo.one(
      from e in AuditEvent,
        where: e.subject_id == ^intent_id and e.event_type == ^event_type,
        order_by: [desc: e.inserted_at],
        limit: 1
    )
  end
end
