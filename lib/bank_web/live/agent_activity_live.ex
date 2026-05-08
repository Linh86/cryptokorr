defmodule BankWeb.AgentActivityLive do
  @moduledoc """
  Activity screen — full audit log with filter chips.

  Mirrors `ActivityScreen` from `reference/screens.jsx`. Phase 1 reuses
  the same dummy seed list AgentLive shows; phase 2 will subscribe to
  the real activity PubSub topic and read from the audit context.
  """
  use BankWeb, :live_view

  import BankWeb.AgentComponents
  alias BankWeb.AgentLayouts

  @seed_activity [
    %{
      id: "a3",
      t: "2 min ago",
      kind: "permission",
      status: "pending",
      title: "Permission ready to install",
      reason: "Waiting for your signature.",
      amount: nil
    },
    %{
      id: "a2",
      t: "14 min ago",
      kind: "wallet",
      status: "note",
      title: "Wallet connected",
      reason: "Base Sepolia · 0x7a2f…d31c",
      amount: nil
    },
    %{
      id: "a1",
      t: "Yesterday",
      kind: "wallet",
      status: "note",
      title: "Faucet drip received",
      reason: "Test funds added to your smart account.",
      amount: "+ 25 USDC"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:filter, "all")
     |> assign(:activity, @seed_activity)
     # Topbar state lives on the redesigned shell; carry placeholders
     # so the nav rail and topbar render correctly until phase 2 wires
     # global state via PubSub.
     |> assign(:wallet, :disconnected)
     |> assign(:permission, :not_installed)
     |> assign(:address, nil)}
  end

  @impl true
  def handle_event("filter:set", %{"id" => id}, socket)
      when id in ~w(all executed blocked permission) do
    {:noreply, assign(socket, :filter, id)}
  end

  def handle_event("topbar:" <> _, _, socket), do: {:noreply, socket}
  def handle_event("confirm_stop:" <> _, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    filtered = filter(assigns.activity, assigns.filter)
    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <AgentLayouts.app
      flash={@flash}
      wallet={@wallet}
      permission={@permission}
      address={@address}
      active={:activity}
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
          <li :if={@filtered == []} class="timeline__empty">Nothing here yet.</li>
          <.activity_row :for={item <- @filtered} item={item} />
        </ol>
      </.card>
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

  defp filter(activity, "all"), do: activity

  defp filter(activity, "executed"),
    do: Enum.filter(activity, &(&1.status == "executed"))

  defp filter(activity, "blocked"),
    do: Enum.filter(activity, &(&1.status in ~w(blocked failed)))

  defp filter(activity, "permission"),
    do: Enum.filter(activity, &(&1.kind in ~w(permission wallet)))
end
