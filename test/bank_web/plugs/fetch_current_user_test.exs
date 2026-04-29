defmodule BankWeb.Plugs.FetchCurrentUserTest do
  @moduledoc """
  Pins the contract `BankWeb.Plugs.FetchCurrentUser` exposes to
  controllers and LiveViews:

    * anonymous request → assigns `current_user: nil` and
      `current_scope: nil`
    * valid session → assigns the loaded user and a minimal
      `%{user: user}` scope
    * disabled user in the session → drops the session entirely
      (logs out on next request)
  """

  use BankWeb.ConnCase, async: true

  alias Bank.Accounts
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

  test "valid session loads the user and builds a scope", %{conn: conn} do
    user = create_user()

    conn =
      conn
      |> with_session()
      |> Plug.Conn.put_session(:user_id, user.id)
      |> FetchCurrentUser.call([])

    assert %Bank.Accounts.User{id: user_id} = conn.assigns.current_user
    assert user_id == user.id
    assert conn.assigns.current_scope == %{user: conn.assigns.current_user}
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
