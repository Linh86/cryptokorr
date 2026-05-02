defmodule BankWeb.IntentsLive do
  @moduledoc """
  Control-tower intents page.

  Gives operators a dedicated surface for the intent stream instead of
  relying only on dashboard cards, queue rows, and replay drilldowns
  (tracked as #44).

  The page shows:

    * A status breakdown (counts per `AgentIntent.state`) scoped by
      the current `kind` and `search` filters. The `state` filter is
      intentionally excluded from the breakdown so every chip stays
      meaningful — each chip represents "how many rows would I see if
      I switched state to this, keeping kind + search as-is".
    * A filterable, paginated table of intents with direct links into
      the replay view for each row.

  Filters read from query params so links into specific slices (e.g.
  `/intents?state=blocked`) are shareable. Updates arrive live via
  PubSub on `audit:stream` — every audit write is a signal that
  something on this page may have changed.
  """

  use BankWeb, :live_view

  alias Bank.Intents

  @states [
    :all,
    :submitted,
    :evaluating,
    :decided,
    :executing,
    :executed,
    :blocked,
    :cancelled,
    :expired
  ]

  @kinds [:all, :transfer, :swap, :scheduled_transfer]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())
    end

    {:ok,
     socket
     |> assign(:page_title, "Intents")
     |> assign(:states, @states)
     |> assign(:kinds, @kinds)
     |> assign(:state_filter, :all)
     |> assign(:kind_filter, :all)
     |> assign(:search, "")
     |> load_state()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    state = parse_filter(params["state"], @states, :all)
    kind = parse_filter(params["kind"], @kinds, :all)
    search = params["q"] || ""

    {:noreply,
     socket
     |> assign(:state_filter, state)
     |> assign(:kind_filter, kind)
     |> assign(:search, search)
     |> load_state()}
  end

  # --- Events --------------------------------------------------------------

  @impl true
  def handle_event("filter", params, socket) do
    path =
      ~p"/intents?#{%{"state" => params["state"] || "all", "kind" => params["kind"] || "all", "q" => params["q"] || ""}}"

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_state() |> put_flash(:info, "Intents refreshed")}
  end

  # --- PubSub --------------------------------------------------------------

  @impl true
  def handle_info(%{topic: :audit_stream}, socket), do: {:noreply, load_state(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State loading -------------------------------------------------------

  defp load_state(socket) do
    kind_filter = socket.assigns.kind_filter
    search = socket.assigns.search
    workspace_id = socket.assigns.current_scope.workspace.id

    intents =
      Intents.list(
        state: socket.assigns.state_filter,
        kind: kind_filter,
        search: search,
        limit: 100,
        workspace_id: workspace_id
      )

    socket
    |> assign(:intents, intents)
    |> assign(
      :counts,
      Intents.counts_by_state(kind: kind_filter, search: search, workspace_id: workspace_id)
    )
    |> assign(:total_in_view, length(intents))
  end

  defp parse_filter(nil, _allowed, default), do: default

  defp parse_filter(str, allowed, default) when is_binary(str) do
    atom = safe_atom(str)
    if atom in allowed, do: atom, else: default
  end

  defp safe_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  # --- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:intents}>
      <div class="flex items-center justify-between mb-8">
        <div>
          <h1 id="page-title" class="text-2xl font-bold tracking-tight">Intents</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Every agent intent the runtime has seen. Filter to slice by state or kind;
            click any row to open its replay timeline.
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <%!-- State breakdown --%>
      <div
        id="state-breakdown"
        class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-8 gap-2 mb-6"
      >
        <.state_chip :for={state <- tl(@states)} state={state} count={Map.get(@counts, state, 0)} />
      </div>

      <%!-- Filters --%>
      <form
        phx-change="filter"
        phx-submit="filter"
        class="flex flex-wrap items-end gap-3 mb-4 p-4 rounded-xl border border-base-300 bg-base-100"
      >
        <label class="form-control">
          <span class="label-text text-xs">State</span>
          <select name="state" class="select select-sm select-bordered">
            <option :for={s <- @states} value={Atom.to_string(s)} selected={@state_filter == s}>
              {state_label(s)}
            </option>
          </select>
        </label>

        <label class="form-control">
          <span class="label-text text-xs">Kind</span>
          <select name="kind" class="select select-sm select-bordered">
            <option :for={k <- @kinds} value={Atom.to_string(k)} selected={@kind_filter == k}>
              {kind_label(k)}
            </option>
          </select>
        </label>

        <label class="form-control flex-1 min-w-[220px]">
          <span class="label-text text-xs">Search (agent id / intent id)</span>
          <input
            type="search"
            name="q"
            value={@search}
            placeholder="agent-01 or 4f2c3…"
            class="input input-sm input-bordered"
          />
        </label>

        <span class="text-xs text-base-content/50 ml-auto">
          Showing {@total_in_view}
        </span>
      </form>

      <%!-- Empty state --%>
      <div
        :if={@intents == []}
        id="intents-empty"
        class="rounded-xl border-2 border-dashed border-base-300 bg-base-200/20 p-12 text-center"
      >
        <.icon name="hero-inbox" class="size-7 text-base-content/30 mb-2 mx-auto" />
        <h2 class="text-lg font-semibold text-base-content/70">No intents match</h2>
        <p class="mt-1 text-sm text-base-content/50">
          Loosen your filters or submit a new intent via <code>POST /v1/intents</code>.
        </p>
      </div>

      <%!-- Intents table --%>
      <div
        :if={@intents != []}
        id="intents-table"
        class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
      >
        <table class="table table-sm w-full">
          <thead class="bg-base-200/50 text-xs uppercase tracking-wide">
            <tr>
              <th>Intent</th>
              <th>Agent</th>
              <th>Kind</th>
              <th>Amount</th>
              <th>Target</th>
              <th>State</th>
              <th>Submitted</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={intent <- @intents} id={"intent-row-" <> intent.id} class="hover">
              <td class="font-mono text-xs text-base-content/60">{short_id(intent.id)}</td>
              <td class="text-xs">{intent.agent_id}</td>
              <td class="text-xs">{intent.kind}</td>
              <td class="text-xs">{intent.amount} {intent.asset}</td>
              <td class="text-xs">{target_label(intent)}</td>
              <td>
                <span class={["badge badge-sm", state_badge_class(intent.state)]}>
                  {state_label(intent.state)}
                </span>
              </td>
              <td class="text-xs text-base-content/50">{format_datetime(intent.submitted_at)}</td>
              <td class="text-right">
                <.link
                  navigate={~p"/audit/replay/#{intent.id}"}
                  class="btn btn-ghost btn-xs gap-1"
                >
                  Replay <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  # --- Presentation helpers -----------------------------------------------

  attr :state, :atom, required: true
  attr :count, :integer, required: true

  defp state_chip(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border px-3 py-2 text-center",
      state_chip_class(@state)
    ]}>
      <div class="text-[0.6rem] uppercase tracking-wider opacity-60">{state_label(@state)}</div>
      <div class="text-lg font-semibold">{@count}</div>
    </div>
    """
  end

  defp state_label(:all), do: "All"
  defp state_label(s) when is_atom(s), do: s |> Atom.to_string() |> String.capitalize()

  defp kind_label(:all), do: "All"
  defp kind_label(k) when is_atom(k), do: k |> Atom.to_string() |> String.replace("_", " ")

  defp state_badge_class(:executed), do: "badge-success"
  defp state_badge_class(:executing), do: "badge-info"
  defp state_badge_class(:decided), do: "badge-info"
  defp state_badge_class(:evaluating), do: "badge-warning"
  defp state_badge_class(:submitted), do: "badge-ghost"
  defp state_badge_class(:blocked), do: "badge-error"
  defp state_badge_class(:cancelled), do: "badge-ghost"
  defp state_badge_class(:expired), do: "badge-warning"
  defp state_badge_class(_), do: "badge-ghost"

  defp state_chip_class(:executed), do: "border-success/30 bg-success/5"
  defp state_chip_class(:blocked), do: "border-error/30 bg-error/5"
  defp state_chip_class(:executing), do: "border-info/30 bg-info/5"
  defp state_chip_class(:evaluating), do: "border-warning/30 bg-warning/5"
  defp state_chip_class(_), do: "border-base-300 bg-base-200/20"

  defp target_label(%{target_counterparty: %{name: name}}) when is_binary(name), do: name
  defp target_label(%{target_raw_address: addr}) when is_binary(addr), do: short_id(addr)
  defp target_label(_), do: "—"

  defp short_id(nil), do: "-"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "..."
  defp short_id(id), do: id

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
