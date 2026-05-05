defmodule BankWeb.OperatorInboxLive do
  @moduledoc """
  Operator inbox LiveView (#235).

  Read / triage surface over `Bank.Notifications` — the
  workspace-scoped inbox model shipped in #233 and emitted from
  the runtime / access pipelines in #234. This page is the
  consumer:

    * Lists notifications addressed to the current user (via
      `user_id`) plus those addressed to one of the current
      user's workspace roles (`role_target`).
    * Filterable by `severity` (info / warning / critical),
      `status` (unread / read / archived / all), and
      `event_type` (free-form string).
    * Per-row actions: `Mark read`, `Archive`, `Open action link`
      when present.
    * Sidebar / header badge shows the unread count for the
      workspace's slice the user can see.
    * Empty states for "no notifications" and "filtered to nothing".

  ## Workspace boundary

  Every read and write goes through `Bank.Notifications`'s
  workspace-scoped helpers. There is no global `Repo.get` here.
  `mark_read/2` / `archive/2` take a `Notification` struct that
  the LiveView re-fetched via `get_in_workspace/2` on the
  current `current_scope`'s workspace — a sibling tenant cannot
  smuggle an id from another workspace into the handle_event
  payload.

  ## Auth / role

  Mounted under `live_session :workspace_viewer` (`require_role:
  :viewer` minimum). Operator and admin tiers also see the
  inbox; viewers can also mark their own notifications read /
  archived because those are personal inbox actions, not policy
  mutations. Cross-workspace probes return `nil` (the
  `get_in_workspace/2` helper collapses sibling-id lookups to
  the same outcome as a missing row).

  ## Read-only side effects

  Mark-read / archive transition `notifications.status` only.
  Nothing on this page enqueues an Oban job, broadcasts on
  PubSub, calls `Bank.AdapterClient`, or modifies any decision /
  intent / execution-plan row.

  ## Stable DOM ids

  Tests pin against:

    * `#operator-inbox` — root container
    * `#inbox-unread-count` — badge in the header
    * `#inbox-filters` — filter form
    * `#inbox-empty` — empty state container
    * `#inbox-notification-<id>` — per-row container
    * `#inbox-mark-read-<id>` — per-row button
    * `#inbox-archive-<id>` — per-row button
    * `#inbox-action-link-<id>` — action link `<a>` when set
  """

  use BankWeb, :live_view

  alias Bank.Notifications
  alias Bank.Notifications.Notification
  alias Bank.Workspaces

  @default_filters %{"severity" => "all", "status" => "unread", "event_type" => ""}

  @severity_options [
    {"All severities", "all"},
    {"Info", "info"},
    {"Warning", "warning"},
    {"Critical", "critical"}
  ]

  @status_options [
    {"Unread", "unread"},
    {"Read", "read"},
    {"Archived", "archived"},
    {"All", "all"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Inbox")
     |> assign(:active_page, :inbox)
     |> assign(:filters, @default_filters)
     |> assign(:severity_options, @severity_options)
     |> assign(:status_options, @status_options)
     |> load_inbox()}
  end

  defp load_inbox(socket) do
    %{user: user, workspace: workspace} = current_scope(socket)
    role_targets = role_targets_for(user, workspace)

    list_opts = list_opts_from_filters(socket.assigns.filters, role_targets)

    notifications = Notifications.list_for_user(workspace.id, user.id, list_opts)

    unread_count =
      Notifications.list_for_user(workspace.id, user.id,
        role_targets: role_targets,
        status: :unread,
        limit: 500
      )
      |> length()

    socket
    |> assign(:workspace_id, workspace.id)
    |> assign(:user_id, user.id)
    |> assign(:role_targets, role_targets)
    |> assign(:notifications, notifications)
    |> assign(:unread_count, unread_count)
  end

  defp current_scope(%{assigns: %{current_scope: %{user: %_{} = user, workspace: %_{} = ws}}}) do
    %{user: user, workspace: ws}
  end

  # `LiveAuth.{:require_role, :viewer}` already redirects when
  # the scope is not single-workspace — by the time this
  # function runs we know the assigns are populated. Falling
  # through with a defensive empty shape avoids a hard crash
  # if the scope is ever shaped differently in tests.
  defp current_scope(_socket) do
    %{user: %{id: nil}, workspace: %{id: nil}}
  end

  # `Bank.Workspaces.get_membership/2` returns the membership
  # for the current scope's user + workspace; we map its role
  # to the inbox's role-target allowlist so a viewer-tier user
  # also sees notifications addressed to `:viewer`. A nil
  # membership (legacy / pending users) falls back to no role
  # targeting — they only see notifications addressed by
  # explicit `user_id`.
  defp role_targets_for(user, workspace) do
    case Workspaces.get_membership(user, workspace.id) do
      %{role: role} -> roles_at_or_below(role)
      _ -> []
    end
  end

  defp roles_at_or_below(:owner), do: [:viewer, :operator, :admin, :owner]
  defp roles_at_or_below(:admin), do: [:viewer, :operator, :admin]
  defp roles_at_or_below(:operator), do: [:viewer, :operator]
  defp roles_at_or_below(:viewer), do: [:viewer]
  defp roles_at_or_below(_), do: []

  defp list_opts_from_filters(filters, role_targets) do
    [role_targets: role_targets, limit: 100]
    |> with_status(Map.get(filters, "status", "unread"))
    |> with_severity(Map.get(filters, "severity", "all"))
    |> with_event_type(Map.get(filters, "event_type", ""))
  end

  defp with_status(opts, "all"), do: Keyword.put(opts, :status, :all)
  defp with_status(opts, "unread"), do: Keyword.put(opts, :status, :unread)
  defp with_status(opts, "read"), do: Keyword.put(opts, :status, :read)
  defp with_status(opts, "archived"), do: Keyword.put(opts, :status, :archived)
  defp with_status(opts, _), do: Keyword.put(opts, :status, :unread)

  defp with_severity(opts, "all"), do: opts

  defp with_severity(opts, sev) when sev in ~w(info warning critical) do
    Keyword.put(opts, :severity, String.to_existing_atom(sev))
  end

  defp with_severity(opts, _), do: opts

  defp with_event_type(opts, ""), do: opts
  defp with_event_type(opts, nil), do: opts

  defp with_event_type(opts, event_type) when is_binary(event_type) do
    Keyword.put(opts, :event_type, String.trim(event_type))
  end

  defp with_event_type(opts, _), do: opts

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    sanitized = sanitize_filters(filters)

    {:noreply,
     socket
     |> assign(:filters, sanitized)
     |> load_inbox()}
  end

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    case fetch_in_scope(socket, id) do
      %Notification{} = n ->
        case Notifications.mark_read(n) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Notification marked read.")
             |> load_inbox()}

          {:error, :archived} ->
            {:noreply, put_flash(socket, :error, "Notification is already archived.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not mark notification read.")}
        end

      nil ->
        # Sibling-workspace id smuggle, or already-deleted row.
        # Collapse to the same not-found shape — same posture
        # `Bank.Notifications.get_in_workspace/2` already enforces.
        {:noreply, put_flash(socket, :error, "Notification not found.")}
    end
  end

  @impl true
  def handle_event("archive", %{"id" => id}, socket) do
    case fetch_in_scope(socket, id) do
      %Notification{} = n ->
        case Notifications.archive(n) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Notification archived.")
             |> load_inbox()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not archive notification.")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Notification not found.")}
    end
  end

  # Same-workspace lookup for `mark_read` / `archive`. Tightened
  # for #235 P2: workspace-scoped fetch alone is not enough — a
  # user could smuggle the id of a same-workspace notification
  # they cannot see (e.g. a `user_id` row addressed to another
  # user, or a `role_target: :admin` row viewed by an operator)
  # and mutate it. We therefore re-apply the same recipient
  # predicate the list query uses
  # (`n.user_id == current_user.id OR n.role_target in role_targets`)
  # and collapse a "row exists but not visible" outcome to the
  # same `nil` shape as a not-found row, so the caller cannot
  # distinguish the two.
  defp fetch_in_scope(socket, id) when is_binary(id) do
    case Notifications.get_in_workspace(id, socket.assigns.workspace_id) do
      %Notification{} = n -> if visible_to_principal?(n, socket), do: n, else: nil
      _ -> nil
    end
  end

  defp fetch_in_scope(_socket, _), do: nil

  defp visible_to_principal?(%Notification{} = n, socket) do
    cond do
      is_binary(n.user_id) and n.user_id == socket.assigns.user_id -> true
      not is_nil(n.role_target) and n.role_target in socket.assigns.role_targets -> true
      true -> false
    end
  end

  defp sanitize_filters(filters) when is_map(filters) do
    %{
      "severity" => sanitize_choice(filters["severity"], ~w(all info warning critical), "all"),
      "status" => sanitize_choice(filters["status"], ~w(all unread read archived), "unread"),
      "event_type" => sanitize_event_type(filters["event_type"])
    }
  end

  defp sanitize_filters(_), do: @default_filters

  defp sanitize_choice(value, allowed, default) when is_binary(value) do
    if value in allowed, do: value, else: default
  end

  defp sanitize_choice(_, _, default), do: default

  # Event-type filter is free-text but bounded — long text is
  # truncated to 64 chars and any whitespace-only / nil collapses
  # to "" (no filter). The Notifications context applies the
  # filter via an exact-match `event_type` column query, so a
  # SQL-shaped string here can't escape into anything else.
  defp sanitize_event_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 64)
  end

  defp sanitize_event_type(_), do: ""

  # --- render ----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:inbox}>
      <div id="operator-inbox" class="space-y-6">
        <header class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Inbox</h1>
            <p class="text-sm text-base-content/60">
              Operator notifications for this workspace.
              <span id="inbox-unread-count" data-unread-count={@unread_count}>
                <span :if={@unread_count > 0} class="badge badge-sm badge-warning ml-2">
                  {@unread_count} unread
                </span>
              </span>
            </p>
          </div>
        </header>

        <.filters_form
          id="inbox-filters"
          filters={@filters}
          severity_options={@severity_options}
          status_options={@status_options}
        />

        <div
          :if={@notifications == []}
          id="inbox-empty"
          class="rounded-lg border border-base-300 bg-base-100 p-8 text-center"
        >
          <p class="text-sm text-base-content/60">
            No notifications match the current filters.
          </p>
        </div>

        <ul :if={@notifications != []} class="space-y-2">
          <li
            :for={n <- @notifications}
            id={"inbox-notification-#{n.id}"}
            data-status={n.status}
            data-severity={n.severity}
            data-event-type={n.event_type}
            class={["rounded-lg border p-3 bg-base-100", row_border_class(n.severity)]}
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="flex items-center gap-2 text-xs">
                  <span
                    class={["badge badge-xs", severity_badge_class(n.severity)]}
                    data-severity={n.severity}
                  >
                    {n.severity}
                  </span>
                  <span class="badge badge-xs badge-ghost" data-status={n.status}>
                    {n.status}
                  </span>
                  <span class="font-mono text-base-content/60">{n.event_type}</span>
                </div>
                <p class="text-sm font-semibold mt-1">{n.title}</p>
                <p class="text-xs text-base-content/70 mt-0.5 break-words">{n.body}</p>
                <p :if={is_binary(n.action_link) and n.action_link != ""} class="mt-1">
                  <.link
                    id={"inbox-action-link-#{n.id}"}
                    navigate={n.action_link}
                    class="text-xs text-primary hover:underline"
                  >
                    Open
                  </.link>
                </p>
                <p class="text-[0.65rem] text-base-content/50 mt-1">
                  <time>{Calendar.strftime(n.inserted_at, "%Y-%m-%d %H:%M:%S")}</time>
                </p>
              </div>
              <div class="flex flex-col gap-1 shrink-0">
                <button
                  :if={n.status == :unread}
                  id={"inbox-mark-read-#{n.id}"}
                  type="button"
                  phx-click="mark_read"
                  phx-value-id={n.id}
                  class="btn btn-xs btn-ghost"
                >
                  Mark read
                </button>
                <button
                  :if={n.status != :archived}
                  id={"inbox-archive-#{n.id}"}
                  type="button"
                  phx-click="archive"
                  phx-value-id={n.id}
                  data-confirm="Archive this notification?"
                  class="btn btn-xs btn-ghost"
                >
                  Archive
                </button>
              </div>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :filters, :map, required: true
  attr :severity_options, :list, required: true
  attr :status_options, :list, required: true

  defp filters_form(assigns) do
    ~H"""
    <form
      id={@id}
      phx-change="filter"
      phx-submit="filter"
      class="flex flex-wrap gap-3 items-end rounded-lg border border-base-300 bg-base-100 p-3"
    >
      <label class="form-control w-full max-w-xs">
        <span class="label-text text-xs">Status</span>
        <select
          name="filters[status]"
          class="select select-sm select-bordered"
          data-testid="inbox-filter-status"
        >
          <option
            :for={{label, value} <- @status_options}
            value={value}
            selected={@filters["status"] == value}
          >
            {label}
          </option>
        </select>
      </label>

      <label class="form-control w-full max-w-xs">
        <span class="label-text text-xs">Severity</span>
        <select
          name="filters[severity]"
          class="select select-sm select-bordered"
          data-testid="inbox-filter-severity"
        >
          <option
            :for={{label, value} <- @severity_options}
            value={value}
            selected={@filters["severity"] == value}
          >
            {label}
          </option>
        </select>
      </label>

      <label class="form-control w-full max-w-xs">
        <span class="label-text text-xs">Event type</span>
        <input
          type="text"
          name="filters[event_type]"
          value={@filters["event_type"]}
          placeholder="e.g. ops.stuck_plan"
          class="input input-sm input-bordered"
          data-testid="inbox-filter-event-type"
        />
      </label>
    </form>
    """
  end

  defp severity_badge_class(:info), do: "badge-ghost"
  defp severity_badge_class(:warning), do: "badge-warning"
  defp severity_badge_class(:critical), do: "badge-error"
  defp severity_badge_class(_), do: "badge-ghost"

  defp row_border_class(:critical), do: "border-error/40"
  defp row_border_class(:warning), do: "border-warning/40"
  defp row_border_class(_), do: "border-base-300"
end
