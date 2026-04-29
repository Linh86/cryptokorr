defmodule BankWeb.API.V1.IntentSimulateControllerTest do
  @moduledoc """
  Controller tests for `POST /v1/intents/:id/simulate` (issue #138).

  Pins the live HTTP contract: 200 with `IntentSimulationResponse`
  on success, 404 for missing/malformed id, 409 for terminal /
  in-flight intents, 422 for missing or invalid `reason`. The
  facade-level matrix (refresh vs dry-run, supersession, audit
  events, replay surface) lives in
  `test/bank/intents/simulate_test.exs`.
  """

  use BankWeb.ConnCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Decisions.SimulationReport
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  describe "POST /v1/intents/:id/simulate — 200 happy paths" do
    test "refresh produces a current report and updates intent pointer",
         %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn = post(conn, ~p"/v1/intents/#{intent.id}/simulate", %{"reason" => "refresh"})
      body = json_response(conn, 200)

      assert body["intent_id"] == intent.id
      assert body["reason"] == "refresh"
      assert body["refreshed"] == true
      assert body["state"] == "submitted"
      assert body["links"]["self"] == "/v1/intents/#{intent.id}"
      assert body["links"]["replay"] == "/v1/intents/#{intent.id}/replay"

      assert body["simulation"]["current"] == true
      assert body["simulation"]["status"] == "completed"
      assert body["simulation"]["provider"] == "stub"
      assert body["simulation"]["chain"] == intent.chain
      assert body["simulation"]["asset"] == intent.asset
      assert body["simulation"]["id"]

      assert Repo.get!(AgentIntent, intent.id).current_simulation_id ==
               body["simulation"]["id"]
    end

    test "pre_submit_dry_run produces a non-current report; intent pointer unchanged",
         %{conn: conn} do
      intent = Fixtures.agent_intent()
      prior_pointer = Repo.get!(AgentIntent, intent.id).current_simulation_id

      conn =
        post(conn, ~p"/v1/intents/#{intent.id}/simulate", %{"reason" => "pre_submit_dry_run"})

      body = json_response(conn, 200)

      assert body["refreshed"] == false
      assert body["simulation"]["current"] == false

      assert Repo.get!(AgentIntent, intent.id).current_simulation_id == prior_pointer
    end

    test "operator_inspection mirrors pre_submit_dry_run", %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn =
        post(conn, ~p"/v1/intents/#{intent.id}/simulate", %{"reason" => "operator_inspection"})

      body = json_response(conn, 200)

      assert body["refreshed"] == false
      assert body["simulation"]["current"] == false
      assert body["reason"] == "operator_inspection"
    end

    test "never enqueues RunExecution", %{conn: conn} do
      intent = Fixtures.agent_intent()

      _ = post(conn, ~p"/v1/intents/#{intent.id}/simulate", %{"reason" => "refresh"})

      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
      refute_enqueued(worker: Bank.Runtime.Workers.ConfirmExecution)
      assert Repo.aggregate(Bank.Decisions.ExecutionPlan, :count, :id) == 0
    end
  end

  describe "POST /v1/intents/:id/simulate — 404" do
    test "returns 404 for a malformed UUID", %{conn: conn} do
      conn = post(conn, "/v1/intents/not-a-uuid/simulate", %{"reason" => "refresh"})
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      missing = Ecto.UUID.generate()
      conn = post(conn, ~p"/v1/intents/#{missing}/simulate", %{"reason" => "refresh"})
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end
  end

  describe "POST /v1/intents/:id/simulate — 409 wrong state" do
    for state <- [:executing, :executed, :cancelled, :expired] do
      @state state

      test "rejects #{@state} intent with 409 wrong_state", %{conn: conn} do
        intent = bump_state!(Fixtures.agent_intent(), @state)

        conn = post(conn, ~p"/v1/intents/#{intent.id}/simulate", %{"reason" => "refresh"})
        body = json_response(conn, 409)
        assert body["error"]["code"] == "wrong_state"
        assert body["error"]["message"] =~ Atom.to_string(@state)

        # No simulation report was written.
        assert Repo.aggregate(SimulationReport, :count, :id) == 0
      end
    end
  end

  describe "POST /v1/intents/:id/simulate — 422 invalid body" do
    test "missing reason returns 422 invalid_body", %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn = post(conn, ~p"/v1/intents/#{intent.id}/simulate", %{})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["message"] =~ "reason"
    end

    test "blank reason returns 422 invalid_body", %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn = post(conn, ~p"/v1/intents/#{intent.id}/simulate", %{"reason" => "   "})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end

    test "non-enum reason returns 422 invalid_reason", %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn =
        post(conn, ~p"/v1/intents/#{intent.id}/simulate", %{"reason" => "force_run"})

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_reason"
      assert body["error"]["message"] =~ "pre_submit_dry_run"
    end

    test "non-string reason returns 422 invalid_reason", %{conn: conn} do
      intent = Fixtures.agent_intent()

      conn = post(conn, ~p"/v1/intents/#{intent.id}/simulate", %{"reason" => 42})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_reason"
    end
  end

  defp bump_state!(intent, state) do
    {:ok, updated} =
      intent
      |> AgentIntent.current_pointer_changeset(%{state: state})
      |> Repo.update()

    updated
  end
end
