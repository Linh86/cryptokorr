defmodule BankWeb.Plugs.FetchCurrentUserTest do
  @moduledoc """
  Pins the contract `BankWeb.Plugs.FetchCurrentUser` exposes to
  controllers and LiveViews (epic #153, issues #154 + #155):

    * anonymous request → assigns `current_user: nil` and
      `current_scope: nil`
    * authenticated, no active membership → scope has user and
      `workspace: nil` (no silent entry into a workspace)
    * authenticated, single active membership → scope is fully
      populated (user, workspace, membership, role)
    * authenticated, ambiguous (multiple active) memberships → scope
      keeps `workspace: nil`; downstream code redirects to /pending
    * disabled user in the session → drops the session entirely
      (logs out on next request)
  """

  use BankWeb.ConnCase, async: true

  alias Bank.Accounts
  alias Bank.Workspaces
  alias BankWeb.Plugs.FetchCurrentUser

  @session_opts Plug.Session.init(
                  store: :cookie,
                  key: "_bank_test_session",
                  signing_salt: "test-salt",
                  same_site: "Lax"
                )

  defp with_session(conn) do
    conn
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(@session_opts)
    |> Plug.Conn.fetch_session()
  end

  defp create_user(overrides \\ %{}) do
    {:ok, user} =
      Accounts.find_or_create_from_oauth(
        Map.merge(
          %{
            provider: :google,
            subject: "fetch-test-#{System.unique_integer([:positive])}",
            email: "fetch-#{System.unique_integer([:positive])}@example.com",
            name: "Fetch Test"
          },
          overrides
        )
      )

    user
  end

  test "anonymous session sets nil assigns", %{conn: conn} do
    conn =
      conn
      |> with_session()
      |> FetchCurrentUser.call([])

    assert conn.assigns.current_user == nil
    assert conn.assigns.current_scope == nil
  end

  test "valid session with no membership leaves workspace unset", %{conn: conn} do
    user = create_user()

    conn =
      conn
      |> with_session()
      |> Plug.Conn.put_session(:user_id, user.id)
      |> FetchCurrentUser.call([])

    assert %Bank.Accounts.User{id: user_id} = conn.assigns.current_user
    assert user_id == user.id

    assert conn.assigns.current_scope == %{
             user: conn.assigns.current_user,
             workspace: nil,
             membership: nil,
             role: nil
           }
  end

  test "valid session with a single active membership auto-selects the workspace", %{conn: conn} do
    user = create_user()
    {:ok, ws} = Workspaces.create_workspace(%{slug: "alpha", name: "Alpha"})

    {:ok, membership} =
      Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: ws.id,
        role: :operator
      })

    conn =
      conn
      |> with_session()
      |> Plug.Conn.put_session(:user_id, user.id)
      |> FetchCurrentUser.call([])

    scope = conn.assigns.current_scope
    assert scope.user.id == user.id
    assert scope.workspace.id == ws.id
    assert scope.membership.id == membership.id
    assert scope.role == :operator
  end

  test "valid session with multiple active memberships leaves workspace nil (ambiguous)", %{
    conn: conn
  } do
    user = create_user()
    {:ok, ws1} = Workspaces.create_workspace(%{slug: "alpha", name: "Alpha"})
    {:ok, ws2} = Workspaces.create_workspace(%{slug: "bravo", name: "Bravo"})

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user.id, workspace_id: ws1.id, role: :operator})

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user.id, workspace_id: ws2.id, role: :viewer})

    conn =
      conn
      |> with_session()
      |> Plug.Conn.put_session(:user_id, user.id)
      |> FetchCurrentUser.call([])

    scope = conn.assigns.current_scope
    assert scope.user.id == user.id
    assert scope.workspace == nil
    assert scope.membership == nil
    assert scope.role == nil
  end

  test "inactive memberships do not contribute to the scope", %{conn: conn} do
    user = create_user()
    {:ok, ws} = Workspaces.create_workspace(%{slug: "alpha", name: "Alpha"})

    {:ok, m} =
      Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: ws.id,
        role: :operator
      })

    {:ok, _} = Workspaces.set_status(m, :inactive)

    conn =
      conn
      |> with_session()
      |> Plug.Conn.put_session(:user_id, user.id)
      |> FetchCurrentUser.call([])

    assert conn.assigns.current_scope.workspace == nil
    assert conn.assigns.current_scope.role == nil
  end

  test "session pointing at a disabled user is dropped", %{conn: conn} do
    user = create_user()
    {:ok, _disabled} = Accounts.disable_user(user)

    conn =
      conn
      |> with_session()
      |> Plug.Conn.put_session(:user_id, user.id)
      |> FetchCurrentUser.call([])

    assert conn.assigns.current_user == nil
    assert conn.assigns.current_scope == nil
    assert Plug.Conn.get_session(conn, :user_id) == nil
  end

  test "session pointing at a missing user is dropped", %{conn: conn} do
    conn =
      conn
      |> with_session()
      |> Plug.Conn.put_session(:user_id, Ecto.UUID.generate())
      |> FetchCurrentUser.call([])

    assert conn.assigns.current_user == nil
    assert conn.assigns.current_scope == nil
  end
end
