defmodule BankWeb.AuditLive do
  @moduledoc """
  Audit trail — operator view of the append-only event stream.

  This is the operator's window into "what happened?" — a paged list
  of audit events with the basic metadata an operator needs to read
  the timeline (timestamp, event type, actor, subject, correlation id)
  and a small set of filters (event type, subject type, correlation id)
  that match the most common operational questions.

  ## Design decisions

  **Operational, not analytical.** This page is a focused log reader,
  not a SIEM. There are no aggregations, charts, or saved searches.
  The filter surface mirrors `Bank.Audit.list_events/2` directly, with
  no second interpretation layer.

  **Replay drilldown.** Every audit row whose subject is an
  `agent_intent` (or whose `correlation_id` is set) carries a "Replay"
  link to the per-intent replay view. The operator's path from "I see
  something suspicious in the log" to "show me the full decision path"
  is one click.

  **Real-time tail.** The LiveView subscribes to `audit:stream`;
  appended events trigger a state reload so the trail stays current
  without polling.
  """

  use BankWeb, :live_view

  alias Bank.Audit

  @page_limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())
    end

    socket =
      socket
      |> assign(page_title: "Audit")
      |> assign(:filters, %{
        "event_type" => "",
        "subject_type" => "",
        "correlation_id" => ""
      })
      |> load_events()

    {:ok, socket}
  end

  # --- Events ---------------------------------------------------------------

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    cleaned =
      filters
      |> Map.take(["event_type", "subject_type", "correlation_id"])
      |> Enum.into(%{}, fn {k, v} -> {k, String.trim(v || "")} end)

    {:noreply,
     socket
     |> assign(:filters, cleaned)
     |> load_events()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, %{
       "event_type" => "",
       "subject_type" => "",
       "correlation_id" => ""
     })
     |> load_events()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_events() |> put_flash(:info, "Audit refreshed")}
  end

  # --- PubSub handlers ------------------------------------------------------

  @impl true
  def handle_info(%{topic: :audit_stream}, socket) do
    {:noreply, load_events(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State loading --------------------------------------------------------

  defp load_events(socket) do
    filters = filter_query(socket.assigns.filters)

    %{events: events, next_cursor: cursor} =
      Audit.list_events(filters, limit: @page_limit, order: :desc)

    socket
    |> assign(:events, events)
    |> assign(:next_cursor, cursor)
  end

  # Translate the form-shaped filter map into the backend query map.
  # Empty strings are dropped; an invalid uuid in `correlation_id`
  # gets dropped too so we render an empty list rather than 500.
  defp filter_query(filters) do
    %{
      event_type: blank_to_nil(Map.get(filters, "event_type")),
      subject_type: blank_to_nil(Map.get(filters, "subject_type")),
      correlation_id: valid_uuid_or_nil(Map.get(filters, "correlation_id"))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp valid_uuid_or_nil(value) do
    case blank_to_nil(value) do
      nil ->
        nil

      str ->
        case Ecto.UUID.cast(str) do
          {:ok, uuid} -> uuid
          :error -> nil
        end
    end
  end

  # --- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_page={:audit}>
      <%!-- Page header --%>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 id="page-title" class="text-2xl font-bold tracking-tight">Audit trail</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Append-only stream of every state transition and operator action
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <%!-- Filters --%>
      <.filter_panel filters={@filters} />

      <%!-- Event list --%>
      <div :if={@events == []} id="audit-empty" class="empty-state">
        <div class="rounded-xl border-2 border-dashed border-base-300 bg-base-200/20 p-12 text-center">
          <div class="w-14 h-14 rounded-full bg-base-300/50 flex items-center justify-center mx-auto mb-4">
            <.icon name="hero-document-magnifying-glass" class="size-7 text-base-content/30" />
          </div>
          <h2 class="text-lg font-semibold text-base-content/70">No audit events</h2>
          <p class="mt-2 text-sm text-base-content/50 max-w-md mx-auto">
            <span :if={any_filter?(@filters)}>
              No events match the current filters. Clear filters to see all events.
            </span>
            <span :if={!any_filter?(@filters)}>
              Audit events appear here as soon as agents submit intents,
              the runtime decides, or operators take safety actions.
            </span>
          </p>
        </div>
      </div>

      <div
        :if={@events != []}
        id="audit-events"
        class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
      >
        <div class="divide-y divide-base-300">
          <.event_row :for={event <- @events} event={event} />
        </div>
        <div
          :if={@next_cursor}
          class="flex items-center justify-center px-6 py-3 border-t border-base-300 bg-base-200/30 text-xs text-base-content/50"
        >
          More events available — paging is API-only in v0.1
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Component: filter panel ----------------------------------------------

  attr :filters, :map, required: true

  defp filter_panel(assigns) do
    ~H"""
    <div id="audit-filters" class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5 mb-6">
      <form phx-change="filter">
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <label class="form-control w-full">
            <div class="label py-1">
              <span class="text-xs font-medium text-base-content/70">Event type</span>
            </div>
            <input
              type="text"
              name="filters[event_type]"
              value={Map.get(@filters, "event_type")}
              placeholder="e.g. intent.submitted"
              class="input input-bordered input-sm font-mono"
            />
          </label>
          <label class="form-control w-full">
            <div class="label py-1">
              <span class="text-xs font-medium text-base-content/70">Subject type</span>
            </div>
            <input
              type="text"
              name="filters[subject_type]"
              value={Map.get(@filters, "subject_type")}
              placeholder="e.g. agent_intent"
              class="input input-bordered input-sm font-mono"
            />
          </label>
          <label class="form-control w-full">
            <div class="label py-1">
              <span class="text-xs font-medium text-base-content/70">Correlation id</span>
            </div>
            <input
              type="text"
              name="filters[correlation_id]"
              value={Map.get(@filters, "correlation_id")}
              placeholder="intent uuid"
              class="input input-bordered input-sm font-mono"
            />
          </label>
        </div>
      </form>
      <div :if={any_filter?(@filters)} class="mt-3 flex justify-end">
        <button
          id="clear-filters-btn"
          phx-click="clear_filters"
          class="btn btn-ghost btn-xs gap-1"
        >
          <.icon name="hero-x-mark" class="size-3" /> Clear filters
        </button>
      </div>
    </div>
    """
  end

  # --- Component: event row -------------------------------------------------

  attr :event, :map, required: true

  defp event_row(assigns) do
    ~H"""
    <div class="px-6 py-3 hover:bg-base-200/30 transition-colors">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2 flex-wrap">
            <span class={[
              "badge badge-sm font-mono",
              event_type_badge_class(@event.event_type)
            ]}>
              {@event.event_type}
            </span>
            <span class="badge badge-sm badge-ghost gap-1">
              <.icon name={actor_icon(@event.actor)} class="size-3" />
              {@event.actor}
            </span>
            <span :if={@event.actor_id} class="text-[0.65rem] text-base-content/40 font-mono">
              {@event.actor_id}
            </span>
          </div>
          <div class="mt-1.5 text-xs text-base-content/60 flex items-center gap-2 flex-wrap">
            <span>
              <span class="text-base-content/40">subject</span>
              <span class="font-mono ml-1">{@event.subject_type}</span>
              <span class="font-mono text-base-content/40 ml-1">
                {short_id(@event.subject_id)}
              </span>
            </span>
            <span :if={@event.correlation_id} class="text-base-content/30">&middot;</span>
            <span :if={@event.correlation_id}>
              <span class="text-base-content/40">correlation</span>
              <span class="font-mono ml-1">{short_id(@event.correlation_id)}</span>
            </span>
          </div>
        </div>
        <div class="flex flex-col items-end gap-1.5 shrink-0">
          <span class="text-xs text-base-content/50 font-mono">
            {format_datetime(@event.ts)}
          </span>
          <.link
            :if={@event.correlation_id}
            navigate={~p"/audit/replay/#{@event.correlation_id}"}
            class="text-xs link link-primary"
          >
            Replay
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers --------------------------------------------------------------

  defp any_filter?(filters) do
    Enum.any?(["event_type", "subject_type", "correlation_id"], fn key ->
      filters |> Map.get(key, "") |> to_string() |> String.trim() != ""
    end)
  end

  defp event_type_badge_class("intent." <> _), do: "badge-info"
  defp event_type_badge_class("decision." <> _), do: "badge-primary"
  defp event_type_badge_class("trust." <> _), do: "badge-secondary"
  defp event_type_badge_class("simulation." <> _), do: "badge-accent"
  defp event_type_badge_class("approval." <> _), do: "badge-warning"
  defp event_type_badge_class("execution." <> _), do: "badge-success"
  defp event_type_badge_class("security." <> _), do: "badge-error"
  defp event_type_badge_class("delegation." <> _), do: "badge-error"
  defp event_type_badge_class(_), do: "badge-ghost"

  defp actor_icon(:user), do: "hero-user"
  defp actor_icon(:agent), do: "hero-cpu-chip"
  defp actor_icon(:runtime), do: "hero-cog-6-tooth"
  defp actor_icon(:adapter), do: "hero-link"
  defp actor_icon(_), do: "hero-question-mark-circle"

  defp short_id(nil), do: "-"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "..."
  defp short_id(id), do: id

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end
end
