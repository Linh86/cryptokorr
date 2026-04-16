defmodule BankWeb.API.V1.ConnectControllerTest do
  @moduledoc """
  Tests for `POST /v1/connect/smart_account`.

  The endpoint is v1.1 scaffolding — the adapter side of the flow
  is stubbed. These tests pin down the payload contract and the
  audit trail it emits.
  """

  use BankWeb.ConnCase, async: true

  alias Bank.Audit.AuditEvent
  alias Bank.Repo

  import Ecto.Query

  describe "POST /v1/connect/smart_account" do
    test "accepts a valid payload and writes an audit event", %{conn: conn} do
      payload = %{
        "smart_account_id" => "sa_demo_01",
        "account" => "0xabc000000000000000000000000000000000dead",
        "chain_id" => 84_532
      }

      conn = post(conn, ~p"/v1/connect/smart_account", payload)
      body = json_response(conn, 202)

      assert body["status"] == "accepted"
      assert body["smart_account_id"] == "sa_demo_01"

      [event] =
        Repo.all(
          from e in AuditEvent,
            where: e.event_type == "delegation.connect_requested",
            order_by: [desc: e.inserted_at]
        )

      assert event.subject_type == "smart_account"
      assert event.subject_id == "sa_demo_01"
      assert event.after_ref["chain_id"] == 84_532
      assert event.after_ref["source"] == "browser_wallet"
    end

    test "rejects missing smart_account_id", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/connect/smart_account", %{
          "account" => "0xabc",
          "chain_id" => 84_532
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["message"] =~ "smart_account_id"
    end

    test "rejects an unsupported chain_id", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/connect/smart_account", %{
          "smart_account_id" => "sa_demo_01",
          "account" => "0xabc",
          "chain_id" => 1
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unsupported_chain"
    end

    test "rejects a non-integer chain_id", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/connect/smart_account", %{
          "smart_account_id" => "sa_demo_01",
          "account" => "0xabc",
          "chain_id" => "84532"
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["message"] =~ "chain_id"
    end
  end
end
