defmodule BankWeb.API.V1.DecisionControllerTest do
  @moduledoc """
  Tests for `/v1/decisions` — show and manual execution.
  """

  use BankWeb.ConnCase, async: false

  import Bank.Fixtures

  alias Bank.Delegations
  alias Bank.Security
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  # --- GET /v1/decisions/:id ---------------------------------------------

  describe "GET /v1/decisions/:id" do
    test "returns envelope with execution plans", %{conn: conn} do
      envelope = decision_envelope(current: true)
      plan = execution_plan(decision: envelope)

      conn = get(conn, ~p"/v1/decisions/#{envelope.id}")
      body = json_response(conn, 200)

      assert body["data"]["id"] == envelope.id
      assert body["data"]["outcome"] == "auto_exec"
      assert body["data"]["risk_tier"] == "low"
      assert body["data"]["current"] == true

      [plan_json] = body["data"]["execution_plans"]
      assert plan_json["id"] == plan.id
      assert plan_json["execution_status"] == "prepared"
    end

    test "returns 404 for unknown id", %{conn: conn} do
      conn = get(conn, ~p"/v1/decisions/#{Ecto.UUID.generate()}")
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "returns 422 for invalid UUID", %{conn: conn} do
      conn = get(conn, ~p"/v1/decisions/not-a-uuid")
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_id"
    end
  end

  # --- POST /v1/decisions/:id/execute ------------------------------------

  describe "POST /v1/decisions/:id/execute — happy path" do
    test "creates execution plan and returns 202", %{conn: conn} do
      envelope = decision_envelope(outcome: :auto_exec, current: true)

      {:ok, _del} = Delegations.grant("sa_exec", "del_exec")

      conn =
        post(conn, ~p"/v1/decisions/#{envelope.id}/execute", %{
          "smart_account_id" => "sa_exec"
        })

      body = json_response(conn, 202)
      assert body["status"] == "execution_enqueued"
      assert body["data"]["decision_id"] == envelope.id
      assert body["data"]["smart_account_id"] == "sa_exec"
      assert body["data"]["execution_status"] == "prepared"
    end
  end

  describe "POST /v1/decisions/:id/execute — gate failures" do
    test "returns 404 for unknown decision", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/decisions/#{Ecto.UUID.generate()}/execute", %{
          "smart_account_id" => "sa_1"
        })

      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "returns 422 when smart_account_id is missing", %{conn: conn} do
      envelope = decision_envelope()

      conn = post(conn, ~p"/v1/decisions/#{envelope.id}/execute", %{})

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end

    test "returns 409 when envelope is not current", %{conn: conn} do
      envelope = decision_envelope(outcome: :auto_exec, current: false)

      {:ok, _del} = Delegations.grant("sa_nc", "del_nc")

      conn =
        post(conn, ~p"/v1/decisions/#{envelope.id}/execute", %{
          "smart_account_id" => "sa_nc"
        })

      body = json_response(conn, 409)
      assert body["error"]["code"] == "not_current"
    end

    test "returns 409 when an active plan already exists", %{conn: conn} do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      _existing_plan = execution_plan(decision: envelope, smart_account_id: "sa_dup")

      {:ok, _del} = Delegations.grant("sa_dup", "del_dup")

      conn =
        post(conn, ~p"/v1/decisions/#{envelope.id}/execute", %{
          "smart_account_id" => "sa_dup"
        })

      body = json_response(conn, 409)
      assert body["error"]["code"] == "active_plan_exists"
    end

    test "returns 503 when runtime is paused", %{conn: conn} do
      envelope = decision_envelope(outcome: :auto_exec, current: true)

      {:ok, _del} = Delegations.grant("sa_paused", "del_paused")
      {:ok, :paused} = Security.pause(:global)

      conn =
        post(conn, ~p"/v1/decisions/#{envelope.id}/execute", %{
          "smart_account_id" => "sa_paused"
        })

      body = json_response(conn, 503)
      assert body["error"]["code"] == "runtime_paused"
    end

    test "returns 409 when delegation is not active", %{conn: conn} do
      envelope = decision_envelope(outcome: :auto_exec, current: true)

      # No delegation exists for this smart account
      conn =
        post(conn, ~p"/v1/decisions/#{envelope.id}/execute", %{
          "smart_account_id" => "sa_no_del"
        })

      body = json_response(conn, 409)
      assert body["error"]["code"] == "delegation_not_active"
    end

    test "returns 409 when delegation is revoking", %{conn: conn} do
      envelope = decision_envelope(outcome: :auto_exec, current: true)

      {:ok, _del} = Delegations.grant("sa_revoking", "del_revoking")
      {:ok, _} = Delegations.record_revoke_requested("sa_revoking")

      conn =
        post(conn, ~p"/v1/decisions/#{envelope.id}/execute", %{
          "smart_account_id" => "sa_revoking"
        })

      body = json_response(conn, 409)
      assert body["error"]["code"] == "delegation_not_active"
    end
  end
end
