defmodule BankWeb.AgentAdvancedLive do
  @moduledoc """
  Advanced screen — accordion of 8 stubbed ops surfaces.

  Mirrors `AdvancedScreen` from `reference/screens.jsx`. Each section
  ships a thin static stub so the visual design lands; phase 2 will
  swap each body for a real lookup against the existing operator
  contexts (Bank.Policies, Bank.Counterparties, Bank.Audit, etc.).

  Default open section: `policies`. Only one open at a time.
  """
  use BankWeb, :live_view

  import BankWeb.AgentComponents
  alias BankWeb.AgentLayouts
  alias BankWeb.AgentLive.GlobalState

  @sections [
    %{
      id: "policies",
      icon: "shield",
      title: "Policy rules",
      sub:
        "Per-counterparty, per-token, per-mode rules. The default policy bundle is recommended for alpha."
    },
    %{
      id: "counterparties",
      icon: "agent",
      title: "Counterparties",
      sub:
        "Allowlisted destinations the agent can interact with. Adding new ones requires a fresh permission."
    },
    %{
      id: "queue",
      icon: "queue",
      title: "Action queue",
      sub: "Intents waiting for approval, simulation, or settlement."
    },
    %{
      id: "audit",
      icon: "history",
      title: "Audit replay",
      sub: "Step-through of policy decisions for any past intent."
    },
    %{
      id: "health",
      icon: "health",
      title: "Adapter health",
      sub: "0x · Morpho · Pimlico bundler · Coinbase RPC."
    },
    %{
      id: "plans",
      icon: "doc",
      title: "Raw execution plans",
      sub: "JSON plan + simulation diff. Useful when wiring a new adapter."
    },
    %{
      id: "events",
      icon: "activity",
      title: "Debug events",
      sub: "Stream of internal events from the policy engine and bundler."
    },
    %{
      id: "inbox",
      icon: "mail",
      title: "Inbox",
      sub: "Cross-org notifications and approvals from collaborators."
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: GlobalState.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Advanced")
     |> assign(:open_id, "policies")
     |> GlobalState.init()}
  end

  @impl true
  def handle_event("section:toggle", %{"id" => id}, socket) do
    new_open = if socket.assigns.open_id == id, do: nil, else: id
    {:noreply, assign(socket, :open_id, new_open)}
  end

  # Topbar Stop button + revoke modal — same flow as AgentLive.
  def handle_event("topbar:stop_agent", _, socket),
    do: {:noreply, assign(socket, :stop_open, true)}

  def handle_event("confirm_stop:cancel", _, socket),
    do: {:noreply, assign(socket, :stop_open, false)}

  def handle_event("confirm_stop:revoke", _, socket),
    do: {:noreply, GlobalState.revoke(socket)}

  def handle_event("topbar:" <> _, _, socket), do: {:noreply, socket}

  @impl true
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
    assigns = assign(assigns, :sections, @sections)

    ~H"""
    <AgentLayouts.app
      flash={@flash}
      wallet={@wallet}
      permission={@permission}
      address={@address}
      active={:advanced}
    >
      <header class="ac__hero">
        <div>
          <div class="ucase" style="color: var(--ink-3);">Advanced</div>
          <h1 class="ac__title serif">For when you need the cockpit</h1>
          <p class="ac__lede">
            Everything ops-heavy lives here so the main screen stays focused.
            Most users won't open this.
          </p>
        </div>
      </header>

      <.banner kind="info">
        You're in <strong>safe defaults</strong>.
        Editing rules below requires a fresh permission install.
      </.banner>

      <div class="adv-list">
        <article :for={s <- @sections} class={["adv", @open_id == s.id && "is-open"]}>
          <button type="button" class="adv__head" phx-click="section:toggle" phx-value-id={s.id}>
            <span class="adv__icon"><.cb_icon name={s.icon} size={16} /></span>
            <span class="adv__main">
              <span class="adv__title serif">{s.title}</span>
              <span class="adv__sub">{s.sub}</span>
            </span>
            <span class="adv__chev">
              <.cb_icon name={if(@open_id == s.id, do: "chevron-down", else: "chevron-right")} size={14} />
            </span>
          </button>
          <div :if={@open_id == s.id} class="adv__body">
            <.section_body id={s.id} />
          </div>
        </article>
      </div>

      <AgentLayouts.confirm_stop_modal open={@stop_open} />
    </AgentLayouts.app>
    """
  end

  # ── Section bodies (static stubs — phase 2 wires real contexts) ────

  attr :id, :string, required: true

  defp section_body(%{id: "policies"} = assigns) do
    ~H"""
    <table class="adv-table">
      <thead>
        <tr><th>Rule</th><th>Behaviour</th><th></th></tr>
      </thead>
      <tbody>
        <tr><td>Hold mode</td><td class="ink-2">Allow no movement</td><td><span class="tag tag--mute">default</span></td></tr>
        <tr><td>Swap mode</td><td class="ink-2">Allow 0x quotes ≤ 0.5% slippage, ≤ 100 USDC</td><td><span class="tag tag--mute">default</span></td></tr>
        <tr><td>Earn mode</td><td class="ink-2">Allow Morpho deposits to allowlisted vaults</td><td><span class="tag tag--mute">default</span></td></tr>
        <tr><td>Counterparty allowlist</td><td class="ink-2">Re7, Gauntlet, Moonwell</td><td><span class="tag tag--mute">default</span></td></tr>
        <tr><td>Daily ceiling</td><td class="ink-2">500 USDC across all intents</td><td><span class="tag tag--mute">default</span></td></tr>
      </tbody>
    </table>
    """
  end

  defp section_body(%{id: "counterparties"} = assigns) do
    ~H"""
    <table class="adv-table">
      <thead>
        <tr><th>Counterparty</th><th>Role</th><th>Status</th></tr>
      </thead>
      <tbody>
        <tr><td class="mono">0x Aggregator</td><td class="ink-2">Routing</td><td><span class="tag tag--ok">allow</span></td></tr>
        <tr><td class="mono">Morpho · Re7 USDC</td><td class="ink-2">Vault</td><td><span class="tag tag--ok">allow</span></td></tr>
        <tr><td class="mono">Morpho · Gauntlet Prime</td><td class="ink-2">Vault</td><td><span class="tag tag--ok">allow</span></td></tr>
        <tr><td class="mono">Morpho · Moonwell Flagship</td><td class="ink-2">Vault</td><td><span class="tag tag--ok">allow</span></td></tr>
        <tr><td class="mono">Coinbase RPC</td><td class="ink-2">Read</td><td><span class="tag tag--ok">allow</span></td></tr>
      </tbody>
    </table>
    """
  end

  defp section_body(%{id: "queue"} = assigns) do
    ~H"""
    <table class="adv-table">
      <thead>
        <tr><th>Intent</th><th>State</th><th>Age</th></tr>
      </thead>
      <tbody>
        <tr>
          <td>Swap 60 USDC → USDbC</td>
          <td><.status_pill kind="needs-approval" size="sm" /></td>
          <td class="mono">2 min</td>
        </tr>
        <tr><td colspan="3" class="adv-empty">— Queue is otherwise clear —</td></tr>
      </tbody>
    </table>
    """
  end

  defp section_body(%{id: "audit"} = assigns) do
    ~H"""
    <div class="audit">
      <div class="audit__step"><span class="mono">01</span> intent received · swap 10 USDC → USDbC</div>
      <div class="audit__step"><span class="mono">02</span> policy: scope check · pass</div>
      <div class="audit__step"><span class="mono">03</span> simulation: 0x quote 0.4% slippage · pass</div>
      <div class="audit__step audit__step--ok">
        <span class="mono">04</span> bundler accepted · settled in 2.1s
      </div>
    </div>
    """
  end

  defp section_body(%{id: "health"} = assigns) do
    rows = [
      {"0x Aggregator", "executed", "ok", "142 ms"},
      {"Morpho", "executed", "ok", "210 ms"},
      {"Pimlico bundler", "executed", "ok", "88 ms"},
      {"Coinbase RPC", "needs-approval", "degraded", "640 ms"}
    ]

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <ul class="adapters">
      <li :for={{name, kind, label, latency} <- @rows} class="adapters__row">
        <span>{name}</span>
        <.status_pill kind={kind} label={label} size="sm" />
        <span class="mono ink-2">{latency}</span>
      </li>
    </ul>
    """
  end

  defp section_body(%{id: "plans"} = assigns) do
    ~H"""
    <pre class="plan">{plan_json()}</pre>
    """
  end

  defp section_body(%{id: "events"} = assigns) do
    events = [
      "policy.scope.match · swap",
      "0x.quote.received · 9.961 USDbC",
      "bundler.userop.signed",
      "bundler.userop.included · block 11_209_482"
    ]

    assigns = assign(assigns, :events, events)

    ~H"""
    <ul class="eventlog">
      <li :for={e <- @events} class="mono">{e}</li>
    </ul>
    """
  end

  defp section_body(%{id: "inbox"} = assigns) do
    ~H"""
    <div class="adv-empty" style="padding: 24px 0;">
      No messages. Multi-user mode is off in private alpha.
    </div>
    """
  end

  defp section_body(assigns) do
    ~H"""
    <div class="adv-empty">—</div>
    """
  end

  defp plan_json do
    """
    {
      "intent": "swap",
      "from": "USDC",
      "to":   "USDbC",
      "amount": "10000000",
      "route": ["0x:v1.aggregator"],
      "slippageBps": 40,
      "gasEstimate": "0.000412 ETH"
    }
    """
  end
end
