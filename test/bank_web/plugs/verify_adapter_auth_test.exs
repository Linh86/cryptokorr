defmodule BankWeb.Plugs.VerifyAdapterAuthTest do
  use BankWeb.ConnCase, async: true

  import Plug.Conn, only: [put_req_header: 3]

  describe "POST /internal/adapter/callback authorization" do
    test "401 missing_authorization when no header is sent", %{conn: conn} do
      conn = post(conn, "/internal/adapter/callback", %{})

      body = json_response(conn, 401)
      assert body["error"]["code"] == "missing_authorization"
    end

    test "401 invalid_authorization_scheme when scheme is not Bearer", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> post("/internal/adapter/callback", %{})

      body = json_response(conn, 401)
      assert body["error"]["code"] == "invalid_authorization_scheme"
    end

    test "401 invalid_credentials when bearer secret does not match", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-the-secret")
        |> post("/internal/adapter/callback", %{})

      body = json_response(conn, 401)
      assert body["error"]["code"] == "invalid_credentials"
    end

    test "200 accepted when bearer matches the configured secret", %{conn: conn} do
      secret =
        Application.fetch_env!(:bank, Bank.AdapterClient) |> Keyword.fetch!(:auth_secret)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> secret)
        |> post("/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "delegation.state_changed",
          "smart_account_id" => "sa_plug_test",
          "delegation_id" => "del_plug_test",
          "state" => "granted",
          "reason" => "initial_grant"
        })

      # Past the plug — the controller handles it.
      json_response(conn, 200)
    end
  end
end
