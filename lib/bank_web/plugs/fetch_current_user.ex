defmodule BankWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Loads the session-bound user into `conn.assigns.current_scope` for
  every browser request (epic #153, issue #154).

  ## What this plug puts on the conn

      conn.assigns.current_user = %Bank.Accounts.User{} | nil
      conn.assigns.current_scope = %{user: %User{} | nil}

  `current_scope` is the opaque shape later issues (workspace +
  membership + role) extend. v0.1 keeps the shape minimal — just
  `:user` — so LiveViews and controllers pattern-matching on it
  don't break when #155 lands.

  ## Disabled-user behaviour

  If a session points at a `:disabled` user we drop the session
  entirely and clear assigns. That keeps the disabled rule from
  becoming "session expires after disable" — a disabled user is
  immediately logged out on the next request.

  ## Layering

  This plug runs in the `:browser` pipeline AFTER `:fetch_session`
  and BEFORE any role-gated plug (issue #159). It does not enforce
  authentication itself — the controller / LiveView decides what
  to do with `current_user == nil`.
  """

  import Plug.Conn

  alias Bank.Accounts
  alias Bank.Accounts.User

  @session_key :user_id

  def init(opts), do: opts

  def call(conn, _opts) do
    case fetch_user_from_session(conn) do
      {:ok, %User{} = user} ->
        assign_user(conn, user)

      :anonymous ->
        assign_user(conn, nil)

      :session_invalid ->
        # Session points at a disabled or missing user — reset.
        conn
        |> clear_session()
        |> configure_session(renew: true)
        |> assign_user(nil)
    end
  end

  defp fetch_user_from_session(conn) do
    case get_session(conn, @session_key) do
      user_id when is_binary(user_id) ->
        case Accounts.get_user(user_id) do
          %User{} = user ->
            if Accounts.session_allowed?(user) do
              {:ok, user}
            else
              :session_invalid
            end

          nil ->
            :session_invalid
        end

      _ ->
        :anonymous
    end
  end

  defp assign_user(conn, user) do
    conn
    |> assign(:current_user, user)
    |> assign(:current_scope, build_scope(user))
  end

  defp build_scope(nil), do: nil
  defp build_scope(%User{} = user), do: %{user: user}

  @doc "Session key for the user id; exposed so the auth controller can mutate it."
  def session_key, do: @session_key
end
