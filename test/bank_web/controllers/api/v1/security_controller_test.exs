defmodule BankWeb.API.V1.SecurityControllerTest do
  @moduledoc """
  Tests for `/v1/security` (pause, resume, revoke_delegation).
  """

  use BankWeb.ConnCase, async: false

  alias Bank.Security
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  # --- POST /v1/security/pause -------------------------------------------

  describe "POST /v1/security/pause" do
    test "pauses the global runtime", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/pause", %{})
      body = json_response(conn, 200)

      assert body["status"] == "paused"
      assert body["scope"] == "global"
      assert Security.paused?(:global)
    end

    test "returns already_paused on double pause", %{conn: conn} do
      {:ok, :paused} = Security.pause(:global)

      conn = post(conn, ~p"/v1/security/pause", %{})
      body = json_response(conn, 200)

      assert body["status"] == "already_paused"
    end

    test "supports counterparty scope", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/pause", %{"scope" => "counterparty:cp_123"})
      body = json_response(conn, 200)

      assert body["status"] == "paused"
      assert body["scope"] == "counterparty:cp_123"
      assert Security.paused?({:counterparty, "cp_123"})
    end
  end

  # --- POST /v1/security/resume ------------------------------------------

  describe "POST /v1/security/resume" do
    test "resumes a paused runtime", %{conn: conn} do
      {:ok, :paused} = Security.pause(:global)

      conn = post(conn, ~p"/v1/security/resume", %{})
      body = json_response(conn, 200)

      assert body["status"] == "resumed"
      assert body["scope"] == "global"
      refute Security.paused?(:global)
    end

    test "returns already_running when not paused", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/resume", %{})
      body = json_response(conn, 200)

      assert body["status"] == "already_running"
    end
  end

  # --- POST /v1/security/revoke_delegation --------------------------------

  describe "POST /v1/security/revoke_delegation" do
    test "requires smart_account_id", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/revoke_delegation", %{})
      body = json_response(conn, 422)

      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["message"] =~ "smart_account_id"
    end

    test "rejects empty smart_account_id", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/security/revoke_delegation", %{"smart_account_id" => ""})

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end

    test "enqueues revoke and returns 202", %{conn: conn} do
      # The revoke enqueue goes through Oban (testing: :manual), which
      # inserts the job but doesn't execute it. Security.revoke_delegation
      # also calls Delegations.record_revoke_requested, but since there's
      # no delegation row the :not_found is swallowed.
      conn =
        post(conn, ~p"/v1/security/revoke_delegation", %{
          "smart_account_id" => "sa_test"
        })

      body = json_response(conn, 202)
      assert body["status"] == "revoke_enqueued"
      assert body["smart_account_id"] == "sa_test"
    end
  end
end
