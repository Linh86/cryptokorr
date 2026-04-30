defmodule BankWeb.LiveAuth do
  @moduledoc """
  `on_mount` hooks for the LiveView pipeline (epic #153, issue
  #157).

  Two named hooks:

    * `:require_workspace` — used on the operator-console
      live_session. Anonymous → `/login`. Authenticated but no
      active workspace (pending or ambiguous-multi-workspace) →
      `/pending`. Active single-workspace → through.
    * `:require_admin` — used on the admin live_session
      (`/admin/...`). Anonymous → `/login`. Authenticated but not
      in the bootstrap admin allowlist → `/` with an error flash.

  Both hooks populate `socket.assigns.current_user` and
  `socket.assigns.current_scope` so LiveViews can read the user
  identity and workspace scope without re-querying.

  ## Why a LiveView hook (not just the controller plug)

  `BankWeb.Plugs.FetchCurrentUser` runs on the initial HTTP request
  and assigns to `conn.assigns`. LiveView mount runs again when the
  WebSocket upgrade lands, with `socket` instead of `conn`, and
  `socket.assigns` is empty until the on_mount hook populates it.
  Without this hook, an authenticated user's identity is invisible
  to LiveView code.

  This will be replaced (extended, not deleted) by the role-based
  authz matrix in #159.
  """

  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.LiveView, only: [redirect: 2, put_flash: 3]

  alias Bank.Access
  alias Bank.Accounts
  alias Bank.Accounts.User
  alias Bank.Workspaces

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
end
