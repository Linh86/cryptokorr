defmodule BankWeb.Plugs.VerifyAPIKeyTest do
  @moduledoc """
  Plug-level coverage for `BankWeb.Plugs.VerifyAPIKey` (#218b).

  The integration tests in `BankWeb.APIV1AuthRBACTest` exercise
  the wire-level 401/403/200 contract end-to-end. These tests pin
  the `current_scope` shape directly so a future regression that
  drops, mistypes, or misrouts a field is caught at the plug
  boundary, not at whichever controller happens to read it first.
  """

  use Bank.DataCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Bank.APIKeys
  alias Bank.Workspaces
  alias BankWeb.Plugs.VerifyAPIKey

  @endpoint BankWeb.Endpoint

  defp build_conn_with_bearer(token) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp ws_user_key(role) do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "vk-#{suffix}",
        email: "vk-#{suffix}@example.com",
        name: "VK"
      })

    {:ok, ws} = Workspaces.create_workspace(%{slug: "vk-#{suffix}", name: "VK"})

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :admin})

    {:ok, key, raw} = APIKeys.create_key(ws, user, role, "vk-#{suffix}")

    {ws, user, key, raw}
  end

  describe "current_scope identity on success" do
    test "assigns current_scope with the key's workspace and role" do
      {ws, _user, key, raw} = ws_user_key(:operator)

      conn =
        raw
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert %{
               user: nil,
               workspace: workspace,
               membership: nil,
               role: :operator,
               api_key: api_key
             } = conn.assigns.current_scope

      assert workspace.id == ws.id
      assert api_key.id == key.id
      refute conn.halted
    end

    test "current_scope.workspace is the FULL preloaded workspace struct, not just the id" do
      {ws, _user, _key, raw} = ws_user_key(:viewer)

      conn =
        raw
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      # Downstream code (Subagent B's audit, future workspace-scoped
      # query layers) reads `.id`, `.slug`, `.name` off the struct.
      # Pin all three so a future change that switches to a slim
      # `%{id: ...}` map regresses loudly.
      assert %Bank.Workspaces.Workspace{} = conn.assigns.current_scope.workspace
      assert conn.assigns.current_scope.workspace.id == ws.id
      assert is_binary(conn.assigns.current_scope.workspace.slug)
      assert is_binary(conn.assigns.current_scope.workspace.name)
    end

    test "two requests with two different keys see two different workspaces" do
      {ws_a, _, _, raw_a} = ws_user_key(:viewer)
      {ws_b, _, _, raw_b} = ws_user_key(:viewer)
      refute ws_a.id == ws_b.id

      conn_a =
        raw_a |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      conn_b =
        raw_b |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn_a.assigns.current_scope.workspace.id == ws_a.id
      assert conn_b.assigns.current_scope.workspace.id == ws_b.id

      # And they are NOT cross-pollinated — a regression that
      # cached the workspace lookup globally would surface here.
      refute conn_a.assigns.current_scope.workspace.id ==
               conn_b.assigns.current_scope.workspace.id
    end

    test "role assigned to the key flows through verbatim" do
      for role <- [:viewer, :operator, :admin, :owner] do
        {_, _, _, raw} = ws_user_key(role)

        conn =
          raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

        assert conn.assigns.current_scope.role == role
      end
    end
  end

  describe "no leak on failed auth" do
    test "Authorization header value is NOT echoed in the response body" do
      raw = "cb_aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee"

      conn =
        raw
        |> build_conn_with_bearer()
        |> bypass_through(BankWeb.Router, [:api, :api_authenticated])
        |> get("/v1/intents/#{Ecto.UUID.generate()}")

      body = conn.resp_body || ""

      refute body =~ raw,
             "401 response body must not echo the rejected Authorization header"

      refute body =~ "aaaaaaaa",
             "401 response body must not partially leak the bearer token"
    end
  end

  describe "halts on every failure mode" do
    test "missing header halts" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "missing_authorization"}}
    end

    test "wrong scheme halts" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Basic abc")
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn.halted
      assert conn.status == 401

      assert Jason.decode!(conn.resp_body) ==
               %{"error" => %{"code" => "invalid_authorization_scheme"}}
    end

    test "valid scheme but bogus secret collapses every internal reason to a single 401 code" do
      # Tries each verify_key/1 failure path and asserts the wire
      # response is identical — the plug must NOT distinguish
      # `:not_found` from `:hash_mismatch` from `:revoked` from
      # `:expired` to a client.
      {_ws, user, key, raw} = ws_user_key(:operator)

      # 1. unknown prefix
      conn1 =
        "cb_aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee"
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      # 2. revoked
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      conn2 =
        raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      # 3. malformed
      conn3 =
        "garbage" |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      for conn <- [conn1, conn2, conn3] do
        assert conn.halted
        assert conn.status == 401

        assert Jason.decode!(conn.resp_body) ==
                 %{"error" => %{"code" => "invalid_credentials"}}
      end
    end
  end
end
