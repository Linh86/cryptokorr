defmodule BankWeb.AuditLive do
  @moduledoc """
  Audit trail — operator view of the append-only event stream.

  This is the operator's window into "what happened?" — a paged list
  of audit events with the basic metadata an operator needs to read
  the timeline (timestamp, event type, actor, subject, correlation id).

  ## Design decisions

  **Operational, not analytical.** This page is a focused log reader,
  not a SIEM. There are no aggregations, charts, or saved searches.
  The filter surface mirrors `Bank.Audit.list_events/2` directly, with
  no second interpretation layer.

  **Filter surface (#45).** Event type, subject type, subject id,
  correlation id, actor, and a from/to date range. The filter form
  writes back to query params so a given slice is shareable and
  bookmarkable (`/audit?event_type=decision.recorded&actor=runtime`).

  **Cursor pagination (#45).** Page size is capped backend-side at
  500; this view uses the default 50 per page. "Next" pushes the
  current cursor onto a back-stack and loads the next slice; "Previous"
  pops. There is no `skip=N`-style offset, so page N+1 is consistent
  with page N even if new events land mid-session.

  **Replay drilldown.** Every audit row whose `correlation_id` is set
  carries a Replay link — the operator's path from "I see something
  suspicious in the log" to "show me the full decision path" is one
  click.

  **Real-time tail.** The LiveView subscribes to `audit:stream`;
  new events reload the *first* page (we never jump pages on live
  updates — that would yank the operator's reading position).
  """

  use BankWeb, :live_view

  alias Bank.Audit

  @page_limit 50

  @actors [:any, :user, :agent, :runtime, :adapter]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())
    end

    {:ok,
     socket
     |> assign(page_title: "Audit")
     |> assign(:actors, @actors)
     |> assign(:filters, empty_filters())
     |> assign(:cursor, nil)
     |> assign(:cursor_stack, [])
     |> assign(:events, [])
     |> assign(:next_cursor, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      "event_type" => trim(params["event_type"]),
      "subject_type" => trim(params["subject_type"]),
      "subject_id" => trim(params["subject_id"]),
      "correlation_id" => trim(params["correlation_id"]),
      "actor" => trim(params["actor"]),
      "from" => trim(params["from"]),
      "to" => trim(params["to"])
    }

    {:noreply,
     socket
     |> assign(:filters, filters)
     # New filters always reset pagination.
     |> assign(:cursor, nil)
     |> assign(:cursor_stack, [])
     |> load_events()}
  end

  # --- Events -------------------------------------------------------------

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: filter_path(params))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/audit")}
  end

  def handle_event("next_page", _params, socket) do
    case socket.assigns.next_cursor do
      nil ->
        {:noreply, socket}

      cursor ->
        stack = [socket.assigns.cursor | socket.assigns.cursor_stack]

        {:noreply,
         socket
         |> assign(:cursor_stack, stack)
         |> assign(:cursor, cursor)
         |> load_events()}
    end
  end

  def handle_event("prev_page", _params, socket) do
    case socket.assigns.cursor_stack do
      [] ->
        {:noreply, socket}

      [prev | rest] ->
        {:noreply,
         socket
         |> assign(:cursor_stack, rest)
         |> assign(:cursor, prev)
         |> load_events()}
    end
  end

  def handle_event("first_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:cursor, nil)
     |> assign(:cursor_stack, [])
     |> load_events()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_events() |> put_flash(:info, "Audit refreshed")}
  end

  # --- PubSub -------------------------------------------------------------

  @impl true
  def handle_info(%{topic: :audit_stream}, socket) do
    # Live updates only apply to page 1 — we don't want to yank the
    # operator's reading position when they're mid-investigation.
    if socket.assigns.cursor == nil do
      {:noreply, load_events(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State loading ------------------------------------------------------

  defp load_events(socket) do
    filters = filter_query(socket.assigns.filters)

    opts = [limit: @page_limit, order: :desc]

    opts =
      case socket.assigns.cursor do
        nil -> opts
        cursor -> Keyword.put(opts, :cursor, cursor)
      end

    %{events: events, next_cursor: next} = Audit.list_events(filters, opts)

    socket
    |> assign(:events, events)
    |> assign(:next_cursor, next)
  end

  defp filter_query(filters) do
    %{
      event_type: blank_to_nil(filters["event_type"]),
      subject_type: blank_to_nil(filters["subject_type"]),
      subject_id: blank_to_nil(filters["subject_id"]),
      correlation_id: valid_uuid_or_nil(filters["correlation_id"]),
      actor: actor_atom(filters["actor"]),
      from: parse_datetime_start(filters["from"]),
      to: parse_datetime_end(filters["to"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp filter_path(params) do
    query =
      params
      |> Map.take(~w(event_type subject_type subject_id correlation_id actor from to))
      |> Enum.reject(fn {_k, v} -> blank?(v) end)
      |> Map.new()

    ~p"/audit?#{query}"
  end

  defp empty_filters do
    %{
      "event_type" => "",
      "subject_type" => "",
      "subject_id" => "",
      "correlation_id" => "",
      "actor" => "",
      "from" => "",
      "to" => ""
    }
  end

  defp trim(nil), do: ""
  defp trim(v) when is_binary(v), do: String.trim(v)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp actor_atom(a) when a in ["user", "agent", "runtime", "adapter"],
    do: String.to_existing_atom(a)

  defp actor_atom(_), do: nil

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

  defp parse_datetime_start(nil), do: nil
  defp parse_datetime_start(""), do: nil

  defp parse_datetime_start(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} ->
        {:ok, dt} = DateTime.new(date, ~T[00:00:00.000], "Etc/UTC")
        dt

      _ ->
        nil
    end
  end

  defp parse_datetime_end(nil), do: nil
  defp parse_datetime_end(""), do: nil

  defp parse_datetime_end(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} ->
        {:ok, dt} = DateTime.new(date, ~T[23:59:59.999999], "Etc/UTC")
        dt

      _ ->
        nil
    end
  end

  # --- Render -------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_page={:audit}>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 id="page-title" class="text-2xl font-bold tracking-tight">Audit trail</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Append-only stream of every state transition and operator action.
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <.filter_panel filters={@filters} actors={@actors} />

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
      </div>

      <div
        :if={@events != []}
        id="audit-pagination"
        class="flex items-center justify-between mt-4 text-xs text-base-content/60"
      >
        <div class="flex items-center gap-2">
          <button
            id="audit-first-page"
            phx-click="first_page"
            disabled={@cursor == nil}
            class="btn btn-ghost btn-xs"
          >
            « First
          </button>
          <button
            id="audit-prev-page"
            phx-click="prev_page"
            disabled={@cursor_stack == []}
            class="btn btn-ghost btn-xs"
          >
            ‹ Previous
          </button>
          <button
            id="audit-next-page"
            phx-click="next_page"
            disabled={is_nil(@next_cursor)}
            class="btn btn-ghost btn-xs"
          >
            Next ›
          </button>
        </div>
        <div class="font-mono text-[0.65rem] text-base-content/40">
          <span>page {length(@cursor_stack) + 1}</span>
          <span :if={is_nil(@next_cursor)}> (last)</span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Component: filter panel --------------------------------------------

  attr :filters, :map, required: true
  attr :actors, :list, required: true

  defp filter_panel(assigns) do
    ~H"""
    <div id="audit-filters" class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5 mb-6">
      <form phx-change="filter" phx-submit="filter">
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
          <label class="form-control w-full">
            <div class="label py-1">
              <span class="text-xs font-medium text-base-content/70">Event type</span>
            </div>
            <input
              type="text"
              name="event_type"
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
              name="subject_type"
              value={Map.get(@filters, "subject_type")}
              placeholder="e.g. agent_intent"
              class="input input-bordered input-sm font-mono"
            />
          </label>

          <label class="form-control w-full">
            <div class="label py-1">
              <span class="text-xs font-medium text-base-content/70">Subject id</span>
            </div>
            <input
              type="text"
              name="subject_id"
              value={Map.get(@filters, "subject_id")}
              placeholder="uuid or opaque id"
              class="input input-bordered input-sm font-mono"
            />
          </label>

          <label class="form-control w-full">
            <div class="label py-1">
              <span class="text-xs font-medium text-base-content/70">Correlation id</span>
            </div>
            <input
              type="text"
              name="correlation_id"
              value={Map.get(@filters, "correlation_id")}
              placeholder="intent uuid"
              class="input input-bordered input-sm font-mono"
            />
          </label>

          <label class="form-control w-full">
            <div class="label py-1">
              <span class="text-xs font-medium text-base-content/70">Actor</span>
            </div>
            <select name="actor" class="select select-bordered select-sm">
              <option value="" selected={Map.get(@filters, "actor", "") == ""}>Any</option>
              <option
                :for={a <- tl(@actors)}
                value={Atom.to_string(a)}
                selected={Map.get(@filters, "actor") == Atom.to_string(a)}
              >
                {a}
              </option>
            </select>
          </label>

          <label class="form-control w-full">
            <div class="label py-1">
              <span class="text-xs font-medium text-base-content/70">From date (UTC)</span>
            </div>
            <input
              type="date"
              name="from"
              value={Map.get(@filters, "from")}
              class="input input-bordered input-sm"
            />
          </label>

          <label class="form-control w-full">
            <div class="label py-1">
              <span class="text-xs font-medium text-base-content/70">To date (UTC)</span>
            </div>
            <input
              type="date"
              name="to"
              value={Map.get(@filters, "to")}
              class="input input-bordered input-sm"
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

  # --- Component: event row -----------------------------------------------

  attr :event, :map, required: true

  defp event_row(assigns) do
    ~H"""
    <div class="px-6 py-3 hover:bg-base-200/30 transition-colors">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2 flex-wrap">
            <span class={["badge badge-sm font-mono", event_type_badge_class(@event.event_type)]}>
              {@event.event_type}
            </span>
            <span class="badge badge-sm badge-ghost gap-1">
              <.icon name={actor_icon(@event.actor)} class="size-3" /> {@event.actor}
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
          <span class="text-xs text-base-content/50 font-mono">{format_datetime(@event.ts)}</span>
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

  # --- Helpers ------------------------------------------------------------

  defp any_filter?(filters) do
    Enum.any?(filters, fn {_k, v} -> v not in [nil, ""] end)
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
