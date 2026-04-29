defmodule BankWeb.API.V1.IntentControllerTest do
  @moduledoc """
  Live tests for `POST /v1/intents` and `GET /v1/intents/:id` (issue
  #135). These pin the create / show contract end-to-end: persistence,
  audit, and the `EvaluateIntent` enqueue. Decision / simulation /
  approval engines are still pending — `simulate` and `cancel`
  remain `501` and live in their own scaffolding test (see
  `intent_replay_test.exs` for the replay surface).
  """

  use BankWeb.ConnCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime.Workers.EvaluateIntent

  import Ecto.Query

  describe "POST /v1/intents — happy paths" do
    test "creates an intent with a counterparty target and enqueues evaluation",
         %{conn: conn} do
      cp = Fixtures.counterparty()

      payload =
        valid_payload(%{
          "agent_id" => "agent-create-cp",
          "idempotency_key" => "k-cp",
          "target" => %{"counterparty_id" => cp.id}
        })

      conn = post(conn, ~p"/v1/intents", payload)
      body = json_response(conn, 202)

      assert is_binary(body["intent_id"])
      assert body["state"] == "submitted"
      assert body["idempotent_replay"] == false
      assert body["links"]["self"] == "/v1/intents/#{body["intent_id"]}"
      assert body["links"]["replay"] == "/v1/intents/#{body["intent_id"]}/replay"

      intent = Repo.get!(AgentIntent, body["intent_id"])
      assert intent.state == :submitted
      assert intent.target_counterparty_id == cp.id
      assert intent.target_raw_address == nil
      assert is_binary(intent.payload_hash)

      assert_enqueued(
        worker: EvaluateIntent,
        queue: :intents_evaluate,
        args: %{"intent_id" => intent.id}
      )

      audit = audit_for_intent(intent.id, "intent.submitted")
      assert audit, "expected an intent.submitted audit event"
      assert audit.subject_id == intent.id
      assert audit.correlation_id == intent.id
    end

    test "creates an intent with a raw-address target", %{conn: conn} do
      raw = "0x1234567890abcdef1234567890abcdef12345678"

      payload =
        valid_payload(%{
          "agent_id" => "agent-create-raw",
          "idempotency_key" => "k-raw",
          "target" => %{"raw_address" => raw}
        })

      conn = post(conn, ~p"/v1/intents", payload)
      body = json_response(conn, 202)

      assert body["state"] == "submitted"

      intent = Repo.get!(AgentIntent, body["intent_id"])
      assert intent.target_raw_address == raw
      assert intent.target_counterparty_id == nil
    end
  end

  describe "POST /v1/intents — idempotency" do
    test "same body with same key returns the existing intent without re-enqueueing",
         %{conn: conn} do
      cp = Fixtures.counterparty()

      payload =
        valid_payload(%{
          "agent_id" => "agent-idem",
          "idempotency_key" => "k-replay",
          "target" => %{"counterparty_id" => cp.id}
        })

      first = post(conn, ~p"/v1/intents", payload) |> json_response(202)
      assert first["idempotent_replay"] == false

      assert_enqueued(worker: EvaluateIntent, args: %{"intent_id" => first["intent_id"]})

      # Drain the first job so we can prove the replay does not enqueue
      # another one.
      job_count_before = oban_job_count_for(first["intent_id"])

      second = post(conn, ~p"/v1/intents", payload) |> json_response(202)
      assert second["idempotent_replay"] == true
      assert second["intent_id"] == first["intent_id"]

      assert oban_job_count_for(first["intent_id"]) == job_count_before

      # Only one intent.submitted audit event for the pair.
      audits =
        Repo.all(
          from e in AuditEvent,
            where: e.event_type == "intent.submitted" and e.subject_id == ^first["intent_id"]
        )

      assert length(audits) == 1
    end

    test "same key with a different body returns 409 idempotency_conflict",
         %{conn: conn} do
      cp = Fixtures.counterparty()

      base =
        valid_payload(%{
          "agent_id" => "agent-conflict",
          "idempotency_key" => "k-conflict",
          "target" => %{"counterparty_id" => cp.id}
        })

      assert json_response(post(conn, ~p"/v1/intents", base), 202)

      different = Map.put(base, "amount", "9.99")

      conn = post(conn, ~p"/v1/intents", different)
      body = json_response(conn, 409)

      assert body["error"]["code"] == "idempotency_conflict"
    end
  end

  describe "POST /v1/intents — validation" do
    test "rejects a target with neither counterparty nor raw address",
         %{conn: conn} do
      payload = valid_payload(%{"target" => %{}})

      conn = post(conn, ~p"/v1/intents", payload)
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_target"
    end

    test "rejects a target with both counterparty and raw address",
         %{conn: conn} do
      cp = Fixtures.counterparty()

      payload =
        valid_payload(%{
          "target" => %{
            "counterparty_id" => cp.id,
            "raw_address" => "0xabcdef1234567890abcdef1234567890abcdef12"
          }
        })

      conn = post(conn, ~p"/v1/intents", payload)
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_target"
    end

    test "rejects an unsupported chain", %{conn: conn} do
      cp = Fixtures.counterparty()
      payload = valid_payload(%{"chain" => "ethereum", "target" => %{"counterparty_id" => cp.id}})

      conn = post(conn, ~p"/v1/intents", payload)
      body = json_response(conn, 422)
      assert body["error"]["code"] == "unsupported_chain"
    end

    test "rejects an unsupported asset", %{conn: conn} do
      cp = Fixtures.counterparty()
      payload = valid_payload(%{"asset" => "DAI", "target" => %{"counterparty_id" => cp.id}})

      conn = post(conn, ~p"/v1/intents", payload)
      body = json_response(conn, 422)
      assert body["error"]["code"] == "unsupported_asset"
    end

    test "rejects a non-positive amount", %{conn: conn} do
      cp = Fixtures.counterparty()
      payload = valid_payload(%{"amount" => "0", "target" => %{"counterparty_id" => cp.id}})

      conn = post(conn, ~p"/v1/intents", payload)
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_amount"
    end

    test "rejects a missing required field", %{conn: conn} do
      cp = Fixtures.counterparty()

      payload =
        %{}
        |> valid_payload()
        |> Map.delete("agent_id")
        |> Map.put("target", %{"counterparty_id" => cp.id})

      conn = post(conn, ~p"/v1/intents", payload)
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["message"] =~ "agent_id"
    end
  end

  describe "GET /v1/intents/:id" do
    test "returns the submitted intent", %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn = get(conn, ~p"/v1/intents/#{intent.id}")
      body = json_response(conn, 200)

      assert body["intent_id"] == intent.id
      assert body["state"] == "submitted"
      assert body["links"]["self"] == "/v1/intents/#{intent.id}"
      assert body["links"]["replay"] == "/v1/intents/#{intent.id}/replay"
      assert body["intent"]["id"] == intent.id
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      missing = Ecto.UUID.generate()
      conn = get(conn, ~p"/v1/intents/#{missing}")
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "returns 404 for a malformed id", %{conn: conn} do
      conn = get(conn, "/v1/intents/not-a-uuid")
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end
  end

  defp valid_payload(overrides) when is_map(overrides) do
    %{
      "idempotency_key" => "k-#{System.unique_integer([:positive])}",
      "source" => "agent",
      "agent_id" => "agent-#{System.unique_integer([:positive])}",
      "kind" => "transfer",
      "asset" => "USDC",
      "chain" => "base",
      "amount" => "12.50",
      "target" => %{"raw_address" => "0xabcdef0000000000000000000000000000000001"}
    }
    |> Map.merge(overrides)
  end

  defp audit_for_intent(intent_id, event_type) do
    Repo.one(
      from e in AuditEvent,
        where: e.subject_id == ^intent_id and e.event_type == ^event_type,
        limit: 1
    )
  end

  defp oban_job_count_for(intent_id) do
    Repo.one(
      from j in Oban.Job,
        where: j.worker == "Bank.Runtime.Workers.EvaluateIntent",
        where: fragment("?->>'intent_id' = ?", j.args, ^intent_id),
        select: count(j.id)
    )
  end
end
