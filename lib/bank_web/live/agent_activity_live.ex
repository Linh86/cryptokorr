defmodule BankWeb.AgentActivityLive do
  @moduledoc """
  Activity screen — full audit log with filter chips.

  Reads the workspace's audit slice via `Bank.Audit.list_events/2`
  (newest first, capped at 50 entries) and subscribes to
  `Bank.Runtime.PubSub.audit_stream/0` to keep the timeline live.
  Rows are transformed through `Bank.Audit.ActivityView` so the
  agent strip and this screen render identically.

  Filter chips operate on the cached raw events so toggling between
  "All", "Executed", "Blocked & failed", and "Permission & wallet"
  doesn't re-hit the database.
  """
  use BankWeb, :live_view

  import BankWeb.AgentComponents
  alias Bank.Audit
  alias Bank.Audit.{ActivityView, AuditEvent}
  alias Bank.Repo
  alias BankWeb.AgentLayouts
  alias BankWeb.AgentLive.GlobalState

  # Same cap as `BankWeb.AgentLive` — 50 entries is plenty for the
  # full screen (the Audit reader handles deeper history; the chips
  # filter in-memory).
  @activity_cap 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())
      GlobalState.subscribe()
    end

    raw_events = load_events(socket)

    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:filter, "all")
     |> assign(:raw_events, raw_events)
     |> assign(:activity, ActivityView.render(raw_events))
     |> GlobalState.init()}
  end

  @impl true
  def handle_event("filter:set", %{"id" => id}, socket)
      when id in ~w(all executed blocked permission) do
    filtered = filter_events(socket.assigns.raw_events, id)

    {:noreply,
     socket
     |> assign(:filter, id)
     |> assign(:activity, ActivityView.render(filtered))}
  end

  # Topbar Stop button + revoke modal — delegated to GlobalState so
  # the same flow runs on every screen.
  def handle_event("topbar:stop_agent", _, socket),
    do: {:noreply, assign(socket, :stop_open, true)}

  def handle_event("confirm_stop:cancel", _, socket),
    do: {:noreply, assign(socket, :stop_open, false)}

  def handle_event("confirm_stop:revoke", _, socket),
    do: {:noreply, GlobalState.revoke(socket)}

  # TopBar Connect / Switch network buttons live on the agent screen
  # only; here they're no-ops so a stale click doesn't crash.
  def handle_event("topbar:" <> _, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info(%{topic: :audit_stream, event: :appended, payload: %{id: event_id}}, socket) do
    workspace_id = workspace_id(socket)

    case Repo.get(AuditEvent, event_id) do
      %AuditEvent{workspace_id: ^workspace_id} = event ->
        if visible_event?(event) do
          raw_events =
            [event | socket.assigns.raw_events]
            |> Enum.take(@activity_cap)

          filtered = filter_events(raw_events, socket.assigns.filter)

          {:noreply,
           socket
           |> assign(:raw_events, raw_events)
           |> assign(:activity, ActivityView.render(filtered))}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # security:events broadcast → re-load wallet binding + delegation +
  # derived states so the TopBar/NavRail track the latest revoke /
  # install transitions.
  def handle_info(%{topic: :security_events} = _msg, socket),
    do: {:noreply, GlobalState.refresh(socket)}

  def handle_info({event, %{smart_account_id: sa_id}}, socket)
      when event in [:revoke_requested, :revoked, :revoke_failed] do
    case socket.assigns[:delegation] do
      %{smart_account_id: ^sa_id} -> {:noreply, GlobalState.refresh(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <AgentLayouts.app
      flash={@flash}
      wallet={@wallet}
      permission={@permission}
      address={@address}
      active={:activity}
      delegation={@delegation}
    >
      <header class="ac__hero">
        <div>
          <div class="ucase" style="color: var(--ink-3);">Activity</div>
          <h1 class="ac__title serif">Everything the agent has touched</h1>
          <p class="ac__lede">A plain-language audit log. Each entry links to its on-chain trace.</p>
        </div>
      </header>

      <div class="filterbar">
        <button
          :for={f <- filters()}
          type="button"
          class={["filterbar__chip", @filter == f.id && "is-on"]}
          phx-click="filter:set"
          phx-value-id={f.id}
        >
          {f.label}
        </button>
        <div class="filterbar__spacer"></div>
        <button type="button" class="link-btn">
          <.cb_icon name="external" size={12} /> Export CSV
        </button>
      </div>

      <.card>
        <ol class="timeline timeline--full">
          <li :if={@activity == []} class="timeline__empty">Nothing here yet.</li>
          <.activity_row :for={item <- @activity} item={item} />
        </ol>
      </.card>

      <AgentLayouts.confirm_stop_modal open={@stop_open} />
    </AgentLayouts.app>
    """
  end

  defp filters do
    [
      %{id: "all", label: "All"},
      %{id: "executed", label: "Executed"},
      %{id: "blocked", label: "Blocked & failed"},
      %{id: "permission", label: "Permission & wallet"}
    ]
  end

  # --- private helpers --------------------------------------------------

  defp load_events(socket) do
    case workspace_id(socket) do
      nil ->
        []

      ws_id ->
        %{events: events} =
          Audit.list_events(%{workspace_id: ws_id}, limit: @activity_cap, order: :desc)

        Enum.filter(events, &visible_event?/1)
    end
  end

  defp workspace_id(socket) do
    case socket.assigns[:current_scope] do
      %{workspace: %{id: id}} -> id
      _ -> nil
    end
  end

  defp visible_event?(%AuditEvent{event_type: "auth." <> _}), do: false
  defp visible_event?(%AuditEvent{event_type: "api_key." <> _}), do: false
  defp visible_event?(%AuditEvent{}), do: true

  # --- chip filtering ---------------------------------------------------

  defp filter_events(events, "all"), do: events

  defp filter_events(events, "executed"), do: Enum.filter(events, &executed_event?/1)

  defp filter_events(events, "blocked"), do: Enum.filter(events, &blocked_event?/1)

  defp filter_events(events, "permission"),
    do: Enum.filter(events, &(&1.subject_type in ["wallet_binding", "delegation"]))

  defp executed_event?(%AuditEvent{event_type: type})
       when type in [
              "execution.confirmed",
              "execution.dispatched",
              "delegation.install_confirmed_onchain",
              "wallet_binding.confirmed",
              "wallet_binding.verified",
              "approval.granted"
            ],
       do: true

  defp executed_event?(%AuditEvent{
         event_type: "intent.state_changed",
         after_ref: %{"state" => "executed"}
       }),
       do: true

  defp executed_event?(_), do: false

  defp blocked_event?(%AuditEvent{event_type: type})
       when type in [
              "execution.reverted",
              "execution.aborted",
              "wallet_binding.failed",
              "delegation.install_failed"
            ],
       do: true

  defp blocked_event?(%AuditEvent{
         event_type: "intent.state_changed",
         after_ref: %{"state" => "blocked"}
       }),
       do: true

  defp blocked_event?(_), do: false
end
