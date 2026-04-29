defmodule BankWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Loads the session-bound user and resolves their workspace scope
  into `conn.assigns` for every browser request (epic #153, issues
  #154, #155).

  ## What this plug puts on the conn

      conn.assigns.current_user = %Bank.Accounts.User{} | nil
      conn.assigns.current_scope =
        nil
        | %{
            user: %User{},
            workspace: %Workspace{} | nil,
            membership: %Membership{} | nil,
            role: :owner | :admin | :operator | :viewer | nil
          }

  `current_scope` is `nil` for anonymous requests. For an
  authenticated user it always has all four keys; `workspace` is
  populated only when `Bank.Workspaces.resolve_scope/1` returns
  `{:single, _}`.

  ## Disabled-user behaviour

  If a session points at a `:disabled` user we drop the session
  entirely and clear assigns. A disabled user is immediately logged
  out on the next request.

  ## Workspace ambiguity

  When a user has more than one active membership, this plug does
  NOT auto-pick. `current_scope.workspace` stays `nil` and the
  controller / LiveView can read the available memberships via
  `Bank.Workspaces.list_active_memberships/1` to render a picker
  (#157). Until the picker exists the auth controller redirects
  ambiguous users to `/pending`.

  ## Layering

  This plug runs in the `:browser` pipeline AFTER `:fetch_session`
  and BEFORE any role-gated plug (issue #159). It does not enforce
  authentication itself — the controller / LiveView decides what
  to do with `current_user == nil` or `current_scope.workspace == nil`.
  """

  import Plug.Conn

  alias Bank.Accounts
  alias Bank.Accounts.User
  alias Bank.Workspaces

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

  defp build_scope(%User{} = user) do
    case Workspaces.resolve_scope(user) do
      {:single, membership} ->
        %{
          user: user,
          workspace: membership.workspace,
          membership: membership,
          role: membership.role
        }

      _ ->
        # `:no_membership` and `{:ambiguous, _}` both leave workspace
        # unset; downstream code redirects to `/pending` instead of
        # silently landing the user in some workspace.
        %{user: user, workspace: nil, membership: nil, role: nil}
    end
  end

  @doc "Session key for the user id; exposed so the auth controller can mutate it."
  def session_key, do: @session_key
end
