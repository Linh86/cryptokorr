defmodule BankWeb.LiveAuth do
  @moduledoc """
  `on_mount` hooks for the LiveView pipeline (epic #153, issue
  #157).

  Three named hooks:

    * `:require_workspace` — used on the operator-console
      live_session. Anonymous → `/login`. Authenticated but no
      active workspace (pending or ambiguous-multi-workspace) →
      `/pending`. Active single-workspace → through.
    * `{:require_role, role}` — superset of `:require_workspace`
      that also enforces a minimum membership role under the
      authority order `viewer < operator < admin < owner` (#159a).
      Insufficient role → `/unauthorized`. The hook is
      self-contained: it does the same anonymous/pending checks as
      `:require_workspace` so a `live_session` only needs one
      `on_mount` entry.
    * `:require_admin` — used on the bootstrap admin live_session
      (`/admin/...`). Anonymous → `/login`. Authenticated but not
      in the bootstrap admin allowlist → `/` with an error flash.
      Kept distinct from `{:require_role, :admin}` because
      `Bank.Access.can_admin_access?/1` honours the
      `BANK_ADMIN_EMAILS` allowlist for users whose membership row
      hasn't been provisioned yet — the bootstrap path that #157
      shipped MUST keep working until every alpha admin has an
      explicit membership.

  All three hooks populate `socket.assigns.current_user` and
  `socket.assigns.current_scope` so LiveViews can read the user
  identity and workspace scope without re-querying.

  ## Why a LiveView hook (not just the controller plug)

  `BankWeb.Plugs.FetchCurrentUser` runs on the initial HTTP request
  and assigns to `conn.assigns`. LiveView mount runs again when the
  WebSocket upgrade lands, with `socket` instead of `conn`, and
  `socket.assigns` is empty until the on_mount hook populates it.
  Without this hook, an authenticated user's identity is invisible
  to LiveView code.
  """

  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.LiveView, only: [redirect: 2, put_flash: 3]

  alias Bank.Access
  alias Bank.Accounts
  alias Bank.Accounts.User
  alias Bank.Workspaces
  alias Bank.Workspaces.Membership

  @session_user_key "user_id"

  @doc """
  on_mount entry point — invoked by `live_session` via the
  `on_mount: {BankWeb.LiveAuth, name}` tuple.
  """
  def on_mount(:require_workspace, _params, session, socket) do
    case load_user(session) do
      nil ->
        {:halt, redirect_to(socket, "/login")}

      %User{} = user ->
        scope = Workspaces.resolve_scope(user)

        case scope do
          {:single, _membership} ->
            {:cont, assign_user_and_scope(socket, user, scope)}

          _ ->
            {:halt, redirect_to(socket, "/pending")}
        end
    end
  end

  # Superset of :require_workspace — also gates by minimum role
  # under the authority order `viewer < operator < admin < owner`
  # (#159a). Used by every operator-console live_session that
  # carries mutation surfaces.
  def on_mount({:require_role, required_role}, _params, session, socket)
      when required_role in [:viewer, :operator, :admin, :owner] do
    case load_user(session) do
      nil ->
        {:halt, redirect_to(socket, "/login")}

      %User{} = user ->
        scope = Workspaces.resolve_scope(user)

        case scope do
          {:single, membership} ->
            if Membership.role_at_least?(membership.role, required_role) do
              {:cont, assign_user_and_scope(socket, user, scope)}
            else
              {:halt, redirect_to(socket, "/unauthorized")}
            end

          _ ->
            {:halt, redirect_to(socket, "/pending")}
        end
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    case load_user(session) do
      nil ->
        {:halt, redirect_to(socket, "/login")}

      %User{} = user ->
        if Access.can_admin_access?(user) do
          scope = Workspaces.resolve_scope(user)
          {:cont, assign_user_and_scope(socket, user, scope)}
        else
          {:halt,
           socket
           |> put_flash(:error, "You don't have access to this page.")
           |> redirect_to("/")}
        end
    end
  end

  defp load_user(session) do
    case Map.get(session, @session_user_key) do
      user_id when is_binary(user_id) ->
        case Accounts.get_user(user_id) do
          %User{} = user ->
            if Accounts.session_allowed?(user), do: user, else: nil

          nil ->
            nil
        end

      _ ->
        nil
    end
  end

  defp assign_user_and_scope(socket, user, scope) do
    socket
    |> assign_new(:current_user, fn -> user end)
    |> assign_new(:current_scope, fn -> scope_assign(user, scope) end)
  end

  defp scope_assign(user, {:single, membership}) do
    %{
      user: user,
      workspace: membership.workspace,
      membership: membership,
      role: membership.role
    }
  end

  defp scope_assign(user, _other) do
    %{user: user, workspace: nil, membership: nil, role: nil}
  end

  defp redirect_to(socket, path), do: redirect(socket, to: path)

  # --- Action-level authorization -----------------------------------------

  @doc """
  Authorize an in-page action against a minimum role (#159a).

  Used in `handle_event` callbacks where the page itself is
  operator-readable but a specific action requires `admin`+ —
  e.g. `pause_runtime`, `revoke_delegation`, `archive`. Splitting
  the live_session would force operators to a separate page and
  full-reload to navigate; gating the action keeps the page
  cohesive while still refusing the privileged operation.

  Returns `:ok` if the socket's `current_scope.role` meets
  `required_role` under the same authority order as
  `Bank.Workspaces.Membership.role_at_least?/2`. Returns
  `{:error, {:insufficient_role, required_role}}` otherwise so the
  caller can branch on the failure shape.
  """
  @spec authorize_action(Phoenix.LiveView.Socket.t(), Membership.role()) ::
          :ok | {:error, {:insufficient_role, Membership.role()}}
  def authorize_action(socket, required_role) do
    scope = socket.assigns[:current_scope] || %{}
    role = Map.get(scope, :role)

    if Membership.role_at_least?(role, required_role) do
      :ok
    else
      {:error, {:insufficient_role, required_role}}
    end
  end
end
