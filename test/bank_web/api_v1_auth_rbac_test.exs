defmodule BankWeb.APIV1AuthRBACTest do
  @moduledoc """
  Cross-route auth + RBAC coverage for `/v1` (#218b).

  Each describe targets one wire-level guarantee:

    * Health endpoints stay public (no auth).
    * Internal adapter callback stays HMAC-only (does not regress
      to API-key auth).
    * Missing / malformed Authorization → 401 with the expected
      generic `invalid_credentials` shape (no internal-reason
      leak).
    * Revoked / expired keys → 401.
    * Authenticated keys can read.
    * Operator+ routes refuse a `:viewer` key with 403
      `insufficient_role`.
    * Operator+ routes accept an `:operator` key.
  """

  use BankWeb.ConnCase, async: false

  alias Bank.APIKeys
  alias Bank.Workspaces

  # --- public health endpoints (NOT API-key gated) -------------------------

  describe "public health endpoints" do
    test "GET /health is reachable without an Authorization header", %{conn: conn} do
      assert %{"status" => "ok"} = json_response(get(conn, "/health"), 200)
    end

    test "GET /v1/health is reachable without an Authorization header", %{conn: conn} do
      assert %{"status" => _} = json_response(get(conn, "/v1/health"), 200)
    end

    test "GET /v1/health/deep is in the no-auth scope (not gated by VerifyAPIKey)",
         %{conn: _conn} do
      # Deep health calls into AdapterClient which isn't mocked in
      # this test, so the controller raises mid-request. What
      # matters here is that the auth plug did NOT intercept — the
      # raised error originates inside the controller, not the
      # plug pipeline. We assert by checking the raise comes from
      # `Req.Test.__fetch_plug__/1` (the AdapterClient HTTP path),
      # NOT from a `send_resp(conn, 401, ...)` returning normally.
      assert_raise RuntimeError, ~r/Bank.AdapterClient/, fn ->
        get(Phoenix.ConnTest.build_conn(), "/v1/health/deep")
      end
    end
  end

  # --- /v1 missing / malformed auth ----------------------------------------

  describe "/v1 routes without an Authorization header" do
    test "GET /v1/intents/:id → 401 missing_authorization", %{conn: conn} do
      assert %{"error" => %{"code" => "missing_authorization"}} =
               json_response(get(conn, ~p"/v1/intents/#{Ecto.UUID.generate()}"), 401)
    end

    test "GET /v1/audit (operator+) → 401 missing_authorization (auth runs before role)",
         %{conn: conn} do
      assert %{"error" => %{"code" => "missing_authorization"}} =
               json_response(get(conn, ~p"/v1/audit"), 401)
    end

    test "POST /v1/security/pause (operator+) → 401 missing_authorization", %{conn: conn} do
      assert %{"error" => %{"code" => "missing_authorization"}} =
               json_response(post(conn, ~p"/v1/security/pause", %{}), 401)
    end
  end

  describe "/v1 routes with malformed Authorization scheme" do
    test "Basic credentials → 401 invalid_authorization_scheme", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic abc123")
        |> get(~p"/v1/intents/#{Ecto.UUID.generate()}")

      assert %{"error" => %{"code" => "invalid_authorization_scheme"}} =
               json_response(conn, 401)
    end
  end

  describe "/v1 routes with malformed bearer body" do
    test "non-`cb_` token → 401 invalid_credentials (generic)", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-valid-cb-key")
        |> get(~p"/v1/intents/#{Ecto.UUID.generate()}")

      assert %{"error" => %{"code" => "invalid_credentials"}} = json_response(conn, 401)
    end

    test "right shape but missing prefix → 401 invalid_credentials", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer cb_aaaaaaaaaaaaaaaaaaaaaaaa")
        |> get(~p"/v1/intents/#{Ecto.UUID.generate()}")

      assert %{"error" => %{"code" => "invalid_credentials"}} = json_response(conn, 401)
    end
  end

  # --- revoked / expired keys ----------------------------------------------

  describe "/v1 routes with a revoked API key" do
    test "401 invalid_credentials" do
      {ws, user} = ws_and_user()
      {:ok, key, raw} = APIKeys.create_key(ws, user, :operator, "to-revoke")
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/v1/intents/#{Ecto.UUID.generate()}")

      assert %{"error" => %{"code" => "invalid_credentials"}} = json_response(conn, 401)
    end
  end

  describe "/v1 routes with an expired API key" do
    test "401 invalid_credentials" do
      {ws, user} = ws_and_user()

      past = DateTime.utc_now() |> DateTime.add(-1, :hour)

      {:ok, _key, raw} =
        APIKeys.create_key(ws, user, :operator, "expired", expires_at: past)

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/v1/intents/#{Ecto.UUID.generate()}")

      assert %{"error" => %{"code" => "invalid_credentials"}} = json_response(conn, 401)
    end
  end

  # --- valid auth + role gating --------------------------------------------

  describe "/v1 authenticated-only routes accept a viewer key" do
    test "GET /v1/counterparties returns 200 with a viewer key" do
      conn = conn_with_role(:viewer)
      assert %{"data" => _} = json_response(get(conn, ~p"/v1/counterparties"), 200)
    end
  end

  describe "/v1 operator+ routes refuse a viewer key (403)" do
    setup do
      {:ok, %{conn: conn_with_role(:viewer)}}
    end

    test "GET /v1/audit → 403 insufficient_role", %{conn: conn} do
      assert %{"error" => %{"code" => "insufficient_role"}, "required_role" => "operator"} =
               json_response(get(conn, ~p"/v1/audit"), 403)
    end

    test "POST /v1/security/pause → 403 insufficient_role", %{conn: conn} do
      assert %{"error" => %{"code" => "insufficient_role"}} =
               json_response(post(conn, ~p"/v1/security/pause", %{}), 403)
    end

    test "GET /v1/approvals → 403 insufficient_role", %{conn: conn} do
      assert %{"error" => %{"code" => "insufficient_role"}} =
               json_response(get(conn, ~p"/v1/approvals"), 403)
    end
  end

  describe "/v1 operator+ routes accept an operator key" do
    test "GET /v1/audit returns 200 with an operator key" do
      conn = conn_with_role(:operator)
      assert %{} = json_response(get(conn, ~p"/v1/audit"), 200)
    end

    test "GET /v1/approvals returns 200 with an operator key" do
      conn = conn_with_role(:operator)
      assert %{"decisions" => _} = json_response(get(conn, ~p"/v1/approvals"), 200)
    end
  end

  describe "/v1 operator+ routes accept admin and owner keys (role hierarchy)" do
    test "admin key reaches /v1/audit" do
      conn = conn_with_role(:admin)
      assert %{} = json_response(get(conn, ~p"/v1/audit"), 200)
    end

    test "owner key reaches /v1/audit" do
      conn = conn_with_role(:owner)
      assert %{} = json_response(get(conn, ~p"/v1/audit"), 200)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp ws_and_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "rbac-#{suffix}",
        email: "rbac-#{suffix}@example.com",
        name: "RBAC API Test"
      })

    {:ok, ws} =
      Workspaces.create_workspace(%{slug: "rbac-#{suffix}", name: "RBAC API"})

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :admin})

    {ws, user}
  end

  defp conn_with_role(role) do
    {ws, user} = ws_and_user()
    {:ok, _key, raw} = APIKeys.create_key(ws, user, role, "test-#{role}")

    Process.put(:bank_test_workspace_id, ws.id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
  end
end
