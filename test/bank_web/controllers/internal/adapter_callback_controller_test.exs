defmodule BankWeb.Internal.AdapterCallbackControllerTest do
  @moduledoc """
  Tests for `POST /internal/adapter/callback`.
  """

  use BankWeb.ConnCase, async: true

  alias Bank.Delegations

  describe "POST /internal/adapter/callback — delegation.state_changed" do
    test "granted creates delegation and returns accepted", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "delegation.state_changed",
          "smart_account_id" => "sa_new",
          "delegation_id" => "del_new",
          "state" => "granted",
          "reason" => "initial_grant",
          "scope" => %{"asset" => "USDC"}
        })

      body = json_response(conn, 200)
      assert body["status"] == "accepted"
      assert body["kind"] == "delegation.state_changed"

      # Verify delegation was created
      d = Delegations.get("sa_new")
      assert d.state == :active
      assert d.delegation_id == "del_new"
    end

    test "revoking transitions active delegation", %{conn: conn} do
      delegation("sa_rev", "del_rev")

      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "delegation.state_changed",
          "smart_account_id" => "sa_rev",
          "delegation_id" => "del_rev",
          "state" => "revoking",
          "reason" => "operator_requested"
        })

      body = json_response(conn, 200)
      assert body["status"] == "accepted"

      d = Delegations.get("sa_rev")
      assert d.state == :revoking
    end

    test "invalid transition returns accepted_with_warning", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "delegation.state_changed",
          "smart_account_id" => "sa_missing",
          "delegation_id" => "del_missing",
          "state" => "revoking",
          "reason" => "no_such_account"
        })

      body = json_response(conn, 200)
      assert body["status"] == "accepted_with_warning"
    end
  end

  describe "POST /internal/adapter/callback — execution callbacks" do
    test "execution.broadcast is acknowledged", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.broadcast",
          "execution_plan_id" => Ecto.UUID.generate()
        })

      body = json_response(conn, 200)
      assert body["status"] == "accepted"
      assert body["kind"] == "execution.broadcast"
    end

    test "execution.confirmed is acknowledged", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.confirmed",
          "execution_plan_id" => Ecto.UUID.generate()
        })

      assert json_response(conn, 200)["status"] == "accepted"
    end

    test "execution.reverted is acknowledged", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.reverted",
          "execution_plan_id" => Ecto.UUID.generate()
        })

      assert json_response(conn, 200)["status"] == "accepted"
    end

    test "execution.aborted is acknowledged", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.aborted",
          "execution_plan_id" => Ecto.UUID.generate()
        })

      assert json_response(conn, 200)["status"] == "accepted"
    end
  end

  describe "POST /internal/adapter/callback — validation" do
    test "missing contract_version returns 400", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "kind" => "delegation.state_changed"
        })

      body = json_response(conn, 400)
      assert body["error"]["code"] == "missing_contract_version"
    end

    test "unsupported contract_version returns 422", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 99,
          "kind" => "delegation.state_changed"
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unsupported_contract_version"
    end

    test "missing kind returns 400", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1
        })

      body = json_response(conn, 400)
      assert body["error"]["code"] == "missing_kind"
    end

    test "unknown kind returns 422", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "bogus.event"
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unknown_kind"
    end
  end

  # --- Helpers ---------------------------------------------------------------

  defp delegation(smart_account_id, delegation_id) do
    {:ok, d} = Delegations.grant(smart_account_id, delegation_id)
    d
  end
end
