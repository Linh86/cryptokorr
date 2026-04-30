defmodule BankWeb.AccessAdminLive do
  @moduledoc """
  Operator surface for approving or rejecting pending users
  (epic #153, issue #157).

  Reads from `Bank.Access.list_pending_access/1` and dispatches
  approve/reject through `Bank.Access.approve_pending_user/3` /
  `Bank.Access.reject_pending_user/3`.

  Authorization is bootstrap-only: the user's email must be in
  `BANK_ADMIN_EMAILS`. The admin live_session's
  `:require_admin` `on_mount` hook enforces that before this
  module mounts.

  ## DOM ids

  Each pending row uses a stable, user-id-based DOM id so test
  helpers can locate buttons without depending on label text:

    * `#pending-row-<user_id>`
    * `#approve-<user_id>`
    * `#reject-<user_id>`

  Plus per-classification badge anchors:

    * `#classification-domain-match-<user_id>`
    * `#classification-allowlist-missed-<user_id>`
    * `#classification-exact-match-<user_id>`
  """

  use BankWeb, :live_view

  alias Bank.Access
  alias Bank.Accounts

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Pending access")
      |> load_pending()

    {:ok, socket}
  end

  @impl true
  def handle_event("approve", %{"user-id" => user_id}, socket) do
    case Accounts.get_user(user_id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "User no longer exists.") |> load_pending()}

      target ->
        actor = socket.assigns.current_user

        case Access.approve_pending_user(actor, target) do
          {:ok, outcome, _membership} ->
            {:noreply,
             socket
             |> put_flash(:info, approve_flash(outcome, target))
             |> load_pending()}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, action_error_flash(reason, target))
             |> load_pending()}
        end
    end
  end

  def handle_event("reject", %{"user-id" => user_id}, socket) do
    case Accounts.get_user(user_id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "User no longer exists.") |> load_pending()}

      target ->
        actor = socket.assigns.current_user

        case Access.reject_pending_user(actor, target) do
          {:ok, _outcome, _user} ->
            {:noreply,
             socket
             |> put_flash(:info, "Rejected #{target.email}.")
             |> load_pending()}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, action_error_flash(reason, target))
             |> load_pending()}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main id="access-admin-main" class="mx-auto max-w-4xl space-y-6 p-6">
        <header class="space-y-1">
          <p class="text-xs uppercase tracking-widest text-base-content/50">Private alpha</p>
          <h1 class="text-2xl font-semibold tracking-tight">Pending access</h1>
          <p class="text-sm text-base-content/70">
            Users who have signed in but have no active workspace membership.
          </p>
        </header>

        <%= if @pending == [] do %>
          <div id="pending-empty" class="rounded-md border border-base-300 bg-base-200 p-6 text-sm">
            No one is waiting for access right now.
          </div>
        <% else %>
          <ul id="pending-list" class="space-y-3">
            <li
              :for={row <- @pending}
              id={"pending-row-" <> row.user.id}
              class="rounded-md border border-base-300 bg-base-200 p-4 space-y-3"
            >
              <div class="flex items-start justify-between gap-4">
                <div class="space-y-1">
                  <div class="font-medium">{row.user.name || row.user.email}</div>
                  <div class="text-xs text-base-content/60">{row.user.email}</div>
                  <div class="text-xs text-base-content/60">
                    Last sign-in:
                    <%= if row.user.last_login_at do %>
                      <time datetime={DateTime.to_iso8601(row.user.last_login_at)}>
                        {format_time(row.user.last_login_at)}
                      </time>
                    <% else %>
                      never
                    <% end %>
                  </div>
                </div>
                <div>
                  {render_classification(assigns, row)}
                </div>
              </div>

              <%= if row.invite do %>
                <div class="rounded bg-base-100 p-2 text-xs">
                  Workspace <span class="font-mono">{row.invite.workspace_id}</span>
                  · role <span class="font-mono">{row.invite.role}</span>
                </div>
              <% end %>

              <div class="flex items-center gap-2">
                <button
                  id={"approve-" <> row.user.id}
                  phx-click="approve"
                  phx-value-user-id={row.user.id}
                  class="rounded bg-emerald-600 px-3 py-1 text-sm text-white hover:bg-emerald-500"
                  disabled={row.classification == :allowlist_missed and is_nil(row.invite)}
                >
                  Approve
                </button>
                <button
                  id={"reject-" <> row.user.id}
                  phx-click="reject"
                  phx-value-user-id={row.user.id}
                  class="rounded bg-rose-700 px-3 py-1 text-sm text-white hover:bg-rose-600"
                >
                  Reject
                </button>
                <%= if row.classification == :allowlist_missed do %>
                  <span class="text-xs text-base-content/60">
                    Add an invite first to approve into a workspace.
                  </span>
                <% end %>
              </div>
            </li>
          </ul>
        <% end %>
      </main>
    </Layouts.app>
    """
  end

  defp render_classification(assigns, %{classification: :domain_match} = row) do
    assigns = assign(assigns, :user_id, row.user.id)

    ~H"""
    <span
      id={"classification-domain-match-" <> @user_id}
      class="inline-flex items-center rounded-full bg-amber-200/30 px-2 py-1 text-xs"
    >
      Domain match — pending admin approval
    </span>
    """
  end

  defp render_classification(assigns, %{classification: :allowlist_missed} = row) do
    assigns = assign(assigns, :user_id, row.user.id)

    ~H"""
    <span
      id={"classification-allowlist-missed-" <> @user_id}
      class="inline-flex items-center rounded-full bg-rose-200/30 px-2 py-1 text-xs"
    >
      No matching invite
    </span>
    """
  end

  defp render_classification(assigns, %{classification: :exact_match_pending} = row) do
    assigns = assign(assigns, :user_id, row.user.id)

    ~H"""
    <span
      id={"classification-exact-match-" <> @user_id}
      class="inline-flex items-center rounded-full bg-sky-200/30 px-2 py-1 text-xs"
    >
      Exact email invite (race / stale)
    </span>
    """
  end

  defp load_pending(socket) do
    assign(socket, :pending, Access.list_pending_access())
  end

  defp approve_flash(:membership_created, target),
    do: "Approved #{target.email} into the workspace."

  defp approve_flash(:membership_reactivated, target),
    do: "Reactivated #{target.email}'s membership."

  defp approve_flash(:already_member, target),
    do: "#{target.email} was already a member."

  defp action_error_flash(:self_action, _target), do: "You cannot approve or reject yourself."
  defp action_error_flash(:unauthorized, _target), do: "You don't have permission for that."

  defp action_error_flash(:user_disabled, target),
    do: "#{target.email} is disabled and cannot be approved without reactivation."

  defp action_error_flash(:workspace_target_required, _target),
    do: "No matching invite — add an invite (workspace + role) before approving."

  defp action_error_flash(:role_required, _target),
    do: "No matching invite — pick a role for this user before approving."

  defp action_error_flash(reason, _target),
    do: "Could not complete the action (#{inspect(reason)})."

  defp format_time(%DateTime{} = ts) do
    Calendar.strftime(ts, "%Y-%m-%d %H:%M UTC")
  end
end
