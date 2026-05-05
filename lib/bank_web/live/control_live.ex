defmodule BankWeb.ControlLive do
  @moduledoc """
  Control tower landing page — connection and delegation status.

  This is the operator's first screen. It shows:

    * Whether the runtime is paused
    * The current smart-account delegation state
    * Whether execution is currently possible
    * Quick actions: refresh, revoke delegation
    * Next-step guidance based on the current state

  Real-time updates arrive through PubSub on `security:events`.
  The LiveView subscribes on mount and pushes state changes without
  polling.

  ## Design decisions

  **Read-only browser wallet connect.** The page renders a wallet
  status region driven by the EIP-1193 `WalletConnect` JS hook.
  The hook reads provider state only — it never asks the wallet to
  sign or broadcast — so an alpha operator can confirm their EOA
  address and chain without granting a delegation. Delegation is
  still established through the adapter callback flow; a browser
  signing path lands with the SDK + adapter integration tracked
  in `docs/wallet-connect.md`.

  **Multi-account aware.** Operators routinely run more than one
  smart account (e.g. production treasury plus a sandbox account).
  When there is at least one non-terminal delegation the page shows
  a selector row across every account and renders the delegation
  card + next-steps panel for whichever is currently selected. The
  first delegation is selected by default; selection persists in
  socket assigns and is preserved across PubSub refreshes when the
  account still exists.
  """

  use BankWeb, :live_view

  alias Bank.Delegations
  alias Bank.Security

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.security_events())
    end

    socket =
      socket
      |> assign(page_title: "Connection")
      |> assign(wallet_status: :not_connected)
      |> assign(wallet_account: nil)
      |> assign(wallet_chain_id: nil)
      |> assign(wallet_error_message: nil)
      |> load_state()

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_state() |> put_flash(:info, "Status refreshed")}
  end

  def handle_event("select_account", %{"smart-account-id" => sa_id}, socket) do
    ids = Enum.map(socket.assigns.delegations, & &1.smart_account_id)

    if sa_id in ids do
      {:noreply, socket |> assign(:selected_smart_account_id, sa_id) |> refresh_selected()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("revoke_delegation", %{"smart-account-id" => sa_id}, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      case Security.revoke_delegation(sa_id, reason: :operator_requested, actor: :user) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Delegation revoke submitted. Awaiting on-chain confirmation.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Revoke failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to revoke a delegation.")}
    end
  end

  def handle_event("pause_runtime", _params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      case Security.pause(:global, reason: :operator_requested, actor: :user) do
        {:ok, _} ->
          {:noreply, socket |> load_state() |> put_flash(:info, "Runtime paused")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Pause failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to pause the runtime.")}
    end
  end

  def handle_event("resume_runtime", _params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      case Security.resume(:global, actor: :user) do
        {:ok, _} ->
          {:noreply, socket |> load_state() |> put_flash(:info, "Runtime resumed")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Resume failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to resume the runtime.")}
    end
  end

  # --- Wallet connect events ----------------------------------------------
  #
  # The `WalletConnect` JS hook pushes these events after the EIP-1193
  # handshake. The hook only reads provider state — no signing or
  # broadcasting happens here. Full signing + delegation grant land with
  # the SDK + adapter integration tracked in `docs/wallet-connect.md`.

  def handle_event("wallet_connect:unavailable", _params, socket) do
    {:noreply,
     socket
     |> assign(wallet_status: :not_installed)
     |> assign(wallet_account: nil)
     |> assign(wallet_chain_id: nil)
     |> assign(wallet_error_message: nil)}
  end

  def handle_event("wallet_connect:connecting", _params, socket) do
    {:noreply,
     socket
     |> assign(wallet_status: :connecting)
     |> assign(wallet_error_message: nil)}
  end

  def handle_event(
        "wallet_connect:connected",
        %{"account" => account, "chain_id" => chain_id},
        socket
      ) do
    {:noreply,
     socket
     |> assign(wallet_status: :connected)
     |> assign(wallet_account: account)
     |> assign(wallet_chain_id: chain_id)
     |> assign(wallet_error_message: nil)}
  end

  def handle_event(
        "wallet_connect:wrong_chain",
        %{"chain_id" => chain_id} = params,
        socket
      ) do
    {:noreply,
     socket
     |> assign(wallet_status: :wrong_chain)
     |> assign(wallet_account: Map.get(params, "account"))
     |> assign(wallet_chain_id: chain_id)
     |> assign(wallet_error_message: nil)}
  end

  def handle_event("wallet_connect:cancelled", _params, socket) do
    {:noreply,
     socket
     |> assign(wallet_status: :not_connected)
     |> assign(wallet_account: nil)
     |> assign(wallet_chain_id: nil)
     |> assign(wallet_error_message: nil)}
  end

  def handle_event("wallet_connect:disconnected", _params, socket) do
    {:noreply,
     socket
     |> assign(wallet_status: :not_connected)
     |> assign(wallet_account: nil)
     |> assign(wallet_chain_id: nil)
     |> assign(wallet_error_message: nil)}
  end

  def handle_event("wallet_connect:disconnect", _params, socket) do
    {:noreply,
     socket
     |> assign(wallet_status: :not_connected)
     |> assign(wallet_account: nil)
     |> assign(wallet_chain_id: nil)
     |> assign(wallet_error_message: nil)}
  end

  def handle_event("wallet_connect:error", params, socket) do
    {:noreply,
     socket
     |> assign(wallet_status: :error)
     |> assign(wallet_error_message: Map.get(params, "message", "Unknown wallet error"))}
  end

  # --- PubSub handlers ----------------------------------------------------

  @impl true
  def handle_info(%{topic: :security_events}, socket) do
    {:noreply, load_state(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State loading -------------------------------------------------------

  defp load_state(socket) do
    workspace_id = socket.assigns.current_scope.workspace.id
    delegations = Delegations.list_active(workspace_id: workspace_id)
    paused? = Security.paused?(:global)

    current = Map.get(socket.assigns, :selected_smart_account_id)
    ids = Enum.map(delegations, & &1.smart_account_id)

    selected_id =
      cond do
        current != nil and current in ids -> current
        delegations != [] -> hd(delegations).smart_account_id
        true -> nil
      end

    socket
    |> assign(:delegations, delegations)
    |> assign(:selected_smart_account_id, selected_id)
    |> assign(:paused, paused?)
    |> refresh_selected()
  end

  defp refresh_selected(socket) do
    selected =
      Enum.find(
        socket.assigns.delegations,
        &(&1.smart_account_id == socket.assigns.selected_smart_account_id)
      )

    execution_ready? =
      case selected do
        %{smart_account_id: sa_id, state: :active} -> Delegations.executable?(sa_id)
        _ -> false
      end

    socket
    |> assign(:selected_delegation, selected)
    |> assign(:execution_ready, execution_ready?)
  end

  # --- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:connection}>
      <%!-- System status bar --%>
      <.system_status_bar paused={@paused} execution_ready={@execution_ready} />

      <%!-- Page header --%>
      <div class="mt-6 mb-8">
        <h1 id="page-title" class="text-2xl font-bold tracking-tight">Connection</h1>
        <p class="mt-1 text-sm text-base-content/60">
          Smart-account delegation and execution readiness
        </p>
      </div>

      <%!-- Account selector --%>
      <.account_selector
        :if={length(@delegations) > 1}
        delegations={@delegations}
        selected={@selected_smart_account_id}
      />

      <%!-- Main grid --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Left column: delegation card (spans 2) --%>
        <div class="lg:col-span-2 space-y-6">
          <.delegation_card delegation={@selected_delegation} paused={@paused} />
        </div>

        <%!-- Right column: status + actions --%>
        <div class="space-y-6">
          <.wallet_status_card
            status={@wallet_status}
            account={@wallet_account}
            chain_id={@wallet_chain_id}
            error_message={@wallet_error_message}
          />
          <.next_steps_card
            delegation={@selected_delegation}
            paused={@paused}
            execution_ready={@execution_ready}
          />
          <.runtime_card paused={@paused} />
        </div>
      </div>

      <%!-- Architecture callout --%>
      <div id="architecture-info" class="mt-10 rounded-xl border border-base-300 bg-base-200/30 p-6">
        <h3 class="text-sm font-semibold text-base-content/80 mb-3">
          <.icon name="hero-shield-check" class="size-4 inline-block mr-1.5 -mt-0.5" />
          Non-custodial architecture
        </h3>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 text-xs text-base-content/60 leading-relaxed">
          <div>
            <span class="font-medium text-base-content/70">Control plane</span>
            <p class="mt-1">
              Phoenix is the decision authority. It evaluates policy, manages approvals,
              and orchestrates execution. It never holds private keys.
            </p>
          </div>
          <div>
            <span class="font-medium text-base-content/70">Chain adapter</span>
            <p class="mt-1">
              A separate TypeScript service handles signing, broadcasting, and
              confirmation polling on Base. It reports outcomes back as callbacks.
            </p>
          </div>
          <div>
            <span class="font-medium text-base-content/70">On-chain guardrails</span>
            <p class="mt-1">
              Smart-account permission modules enforce spend limits, target restrictions,
              and revocable delegations — even if upstream systems fail.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Component: system status bar ----------------------------------------

  attr :paused, :boolean, required: true
  attr :execution_ready, :boolean, required: true

  defp system_status_bar(assigns) do
    ~H"""
    <div id="system-status-bar" class="flex flex-wrap items-center gap-2">
      <div
        :if={@paused}
        id="pause-indicator"
        class="badge badge-warning gap-1.5 font-medium"
      >
        <.icon name="hero-pause-circle-solid" class="size-3.5" /> Runtime paused
      </div>
      <div
        :if={@execution_ready}
        id="execution-ready-indicator"
        class="badge badge-success gap-1.5 font-medium"
      >
        <.icon name="hero-check-circle-solid" class="size-3.5" /> Execution ready
      </div>
      <div
        :if={!@execution_ready && !@paused}
        id="execution-blocked-indicator"
        class="badge badge-ghost gap-1.5 font-medium"
      >
        <.icon name="hero-minus-circle-solid" class="size-3.5" /> Execution blocked
      </div>
    </div>
    """
  end

  # --- Component: account selector -----------------------------------------

  attr :delegations, :list, required: true
  attr :selected, :string, required: true

  defp account_selector(assigns) do
    ~H"""
    <div
      id="account-selector"
      class="mt-4 flex flex-wrap items-center gap-2 rounded-xl border border-base-300 bg-base-200/40 p-3"
    >
      <span class="text-xs uppercase tracking-wider text-base-content/50 mr-1">Account</span>
      <button
        :for={delegation <- @delegations}
        type="button"
        id={"account-tab-" <> delegation.smart_account_id}
        phx-click="select_account"
        phx-value-smart-account-id={delegation.smart_account_id}
        class={[
          "btn btn-xs gap-1.5 font-mono",
          if(delegation.smart_account_id == @selected,
            do: "btn-primary",
            else: "btn-ghost border border-base-300"
          )
        ]}
      >
        {short_id(delegation.smart_account_id)}
        <span class={["badge badge-xs", delegation_badge_class(delegation.state)]}>
          {delegation_label(delegation.state)}
        </span>
      </button>
    </div>
    """
  end

  # --- Component: delegation card ------------------------------------------

  attr :delegation, :map, required: true
  attr :paused, :boolean, required: true

  defp delegation_card(%{delegation: nil} = assigns) do
    ~H"""
    <div
      id="delegation-card"
      class="rounded-xl border-2 border-dashed border-base-300 bg-base-200/20 p-8"
    >
      <div class="flex flex-col items-center text-center">
        <div class="w-14 h-14 rounded-full bg-base-300/50 flex items-center justify-center mb-4">
          <.icon name="hero-link-slash" class="size-7 text-base-content/30" />
        </div>
        <h2 class="text-lg font-semibold text-base-content/70">No delegation connected</h2>
        <p class="mt-2 text-sm text-base-content/50 max-w-md">
          No smart account has an active delegation with this control plane.
          The adapter establishes delegations through the callback flow — this
          UI will reflect the state automatically once a delegation is granted.
        </p>
        <div class="mt-6">
          <.button phx-click="refresh" class="btn btn-primary btn-soft btn-sm gap-1.5">
            <.icon name="hero-arrow-path" class="size-3.5" /> Refresh status
          </.button>
        </div>
      </div>
    </div>
    """
  end

  defp delegation_card(assigns) do
    ~H"""
    <div id="delegation-card" class="rounded-xl border border-base-300 bg-base-100 shadow-sm">
      <%!-- Header --%>
      <div class="flex items-center justify-between px-6 py-4 border-b border-base-300">
        <div class="flex items-center gap-3">
          <div class={[
            "w-10 h-10 rounded-lg flex items-center justify-center",
            delegation_icon_bg(@delegation.state)
          ]}>
            <.icon name={delegation_icon(@delegation.state)} class="size-5" />
          </div>
          <div>
            <h2 class="font-semibold">Smart Account Delegation</h2>
            <p class="text-xs text-base-content/50 font-mono">
              {short_id(@delegation.smart_account_id)}
            </p>
          </div>
        </div>
        <.delegation_badge state={@delegation.state} />
      </div>

      <%!-- Details --%>
      <div class="px-6 py-5 space-y-4">
        <div class="grid grid-cols-2 gap-4">
          <.detail_item label="Chain" value="Base" />
          <.detail_item label="Asset" value="USDC" />
          <.detail_item label="Delegation ID" value={short_id(@delegation.delegation_id)} mono />
          <.detail_item
            label="Granted"
            value={format_datetime(@delegation.granted_at)}
          />
          <.detail_item
            :if={@delegation.expires_at}
            label="Expires"
            value={format_datetime(@delegation.expires_at)}
          />
          <.detail_item
            :if={@delegation.revoke_requested_at}
            label="Revoke requested"
            value={format_datetime(@delegation.revoke_requested_at)}
          />
          <.detail_item
            :if={@delegation.last_tx_hash}
            label="Tx hash"
            value={short_hash(@delegation.last_tx_hash)}
            mono
          />
          <.detail_item
            :if={@delegation.scope != %{}}
            label="Scope"
            value={inspect(@delegation.scope)}
          />
        </div>
      </div>

      <%!-- Actions --%>
      <div class="flex items-center gap-3 px-6 py-4 border-t border-base-300 bg-base-200/20 rounded-b-xl">
        <.button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </.button>
        <.button
          :if={@delegation.state in [:active, :pending]}
          id="revoke-btn"
          phx-click="revoke_delegation"
          phx-value-smart-account-id={@delegation.smart_account_id}
          data-confirm="Revoke this delegation? Execution will stop immediately. This cannot be undone from the API."
          class="btn btn-error btn-soft btn-sm gap-1.5"
        >
          <.icon name="hero-shield-exclamation" class="size-3.5" /> Revoke delegation
        </.button>
        <.button
          :if={@delegation.state == :revoke_failed}
          id="revoke-retry-btn"
          phx-click="revoke_delegation"
          phx-value-smart-account-id={@delegation.smart_account_id}
          data-confirm="Retry the revoke? The previous attempt failed on-chain and this delegation is still live."
          class="btn btn-error btn-soft btn-sm gap-1.5"
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> Retry revoke
        </.button>
      </div>
    </div>
    """
  end

  # --- Component: detail item -----------------------------------------------

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp detail_item(assigns) do
    ~H"""
    <div>
      <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">{@label}</dt>
      <dd class={["text-sm", @mono && "font-mono text-base-content/80"]}>{@value}</dd>
    </div>
    """
  end

  # --- Component: delegation badge -----------------------------------------

  attr :state, :atom, required: true

  defp delegation_badge(assigns) do
    ~H"""
    <span
      id="delegation-state-badge"
      class={["badge font-medium", delegation_badge_class(@state)]}
    >
      {delegation_label(@state)}
    </span>
    """
  end

  # --- Component: next steps card ------------------------------------------

  attr :delegation, :map, required: true
  attr :paused, :boolean, required: true
  attr :execution_ready, :boolean, required: true

  defp next_steps_card(assigns) do
    ~H"""
    <div id="next-steps-card" class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5">
      <h3 class="text-sm font-semibold mb-3 flex items-center gap-1.5">
        <.icon name="hero-light-bulb" class="size-4 text-warning" /> Next steps
      </h3>
      <ul class="space-y-2.5 text-sm text-base-content/70">
        <.step_item
          :if={is_nil(@delegation)}
          status={:action}
          text="Establish a delegation through the adapter callback flow"
        />
        <.step_item
          :if={@delegation && @delegation.state == :pending}
          status={:waiting}
          text="Delegation is pending — waiting for adapter confirmation"
        />
        <.step_item
          :if={@delegation && @delegation.state == :active && @paused}
          status={:action}
          text="Resume the runtime to enable execution"
        />
        <.step_item
          :if={@execution_ready}
          status={:done}
          text="Delegation active and execution ready"
        />
        <.step_item
          :if={@delegation && @delegation.state == :revoking}
          status={:waiting}
          text="Revocation in flight — awaiting on-chain confirmation"
        />
        <.step_item
          :if={@delegation && @delegation.state == :revoke_failed}
          status={:action}
          text="Previous revoke attempt failed on-chain — operator must retry to disable this delegation"
        />
        <.step_item
          :if={@execution_ready}
          status={:info}
          text="Intents submitted by agents will be evaluated and routed"
        />
      </ul>
    </div>
    """
  end

  attr :status, :atom, required: true
  attr :text, :string, required: true

  defp step_item(assigns) do
    ~H"""
    <li class="flex items-start gap-2">
      <.icon
        :if={@status == :action}
        name="hero-arrow-right-circle"
        class="size-4 mt-0.5 text-primary shrink-0"
      />
      <.icon
        :if={@status == :waiting}
        name="hero-clock"
        class="size-4 mt-0.5 text-warning shrink-0"
      />
      <.icon
        :if={@status == :done}
        name="hero-check-circle-solid"
        class="size-4 mt-0.5 text-success shrink-0"
      />
      <.icon
        :if={@status == :info}
        name="hero-information-circle"
        class="size-4 mt-0.5 text-base-content/40 shrink-0"
      />
      <span>{@text}</span>
    </li>
    """
  end

  # --- Component: wallet status card ---------------------------------------

  attr :status, :atom, required: true
  attr :account, :string, default: nil
  attr :chain_id, :integer, default: nil
  attr :error_message, :string, default: nil

  defp wallet_status_card(assigns) do
    ~H"""
    <div
      id="wallet-status-card"
      phx-hook="WalletConnect"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5"
    >
      <h3 class="text-sm font-semibold mb-3 flex items-center gap-1.5">
        <.icon name="hero-wallet" class="size-4" /> Browser wallet
      </h3>

      <div id="wallet-status" class="space-y-3">
        <div
          :if={@status == :not_installed}
          id="wallet-status-not-installed"
          class="flex items-start gap-2 text-sm text-base-content/70"
        >
          <.icon name="hero-exclamation-triangle" class="size-4 mt-0.5 text-warning shrink-0" />
          <p>
            No browser wallet detected. Install MetaMask (or another EIP-1193 wallet) and reload this page.
          </p>
        </div>

        <div
          :if={@status == :connecting}
          id="wallet-status-connecting"
          class="flex items-center gap-2 text-sm text-base-content/70"
        >
          <.icon name="hero-arrow-path" class="size-4 animate-spin text-base-content/50" />
          <p>Connecting — confirm the prompt in your wallet…</p>
        </div>

        <div
          :if={@status == :connected}
          id="wallet-status-connected"
          class="space-y-2 text-sm"
        >
          <div class="flex items-center gap-2">
            <.icon name="hero-check-circle-solid" class="size-4 text-success" />
            <span class="text-base-content/70">Connected</span>
          </div>
          <div>
            <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
              Address
            </dt>
            <dd id="wallet-status-address" class="font-mono text-sm text-base-content/80 break-all">
              {@account}
            </dd>
          </div>
          <div>
            <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
              Chain
            </dt>
            <dd id="wallet-status-chain" class="text-sm text-base-content/80">
              {chain_label(@chain_id)}
            </dd>
          </div>
          <button
            id="wallet-disconnect-btn"
            type="button"
            phx-click="wallet_connect:disconnect"
            class="btn btn-ghost btn-xs gap-1.5"
          >
            <.icon name="hero-link-slash" class="size-3.5" /> Disconnect
          </button>
        </div>

        <div
          :if={@status == :wrong_chain}
          id="wallet-status-wrong-chain"
          class="space-y-2 text-sm"
        >
          <div class="flex items-start gap-2 text-warning">
            <.icon name="hero-exclamation-triangle" class="size-4 mt-0.5 shrink-0" />
            <p class="text-base-content/80">
              Wallet is on chain id <span id="wallet-status-wrong-chain-id">{@chain_id}</span>. Switch to Base (8453) or Base Sepolia (84532) to continue.
            </p>
          </div>
          <p :if={@account} class="text-xs text-base-content/50 font-mono break-all">
            {@account}
          </p>
          <button
            id="wallet-disconnect-btn"
            type="button"
            phx-click="wallet_connect:disconnect"
            class="btn btn-ghost btn-xs gap-1.5"
          >
            <.icon name="hero-link-slash" class="size-3.5" /> Disconnect
          </button>
        </div>

        <div
          :if={@status == :error}
          id="wallet-status-error"
          class="space-y-2 text-sm"
        >
          <div class="flex items-start gap-2 text-error">
            <.icon name="hero-exclamation-circle" class="size-4 mt-0.5 shrink-0" />
            <p id="wallet-status-error-message" class="text-base-content/80">{@error_message}</p>
          </div>
          <button
            id="wallet-connect-btn"
            type="button"
            class="btn btn-xs btn-outline"
          >
            Try again
          </button>
        </div>

        <div
          :if={@status == :not_connected}
          id="wallet-status-disconnected"
          class="space-y-2 text-sm"
        >
          <p class="text-base-content/70">
            Connect a browser wallet to view your public address. Base Sepolia (84532) is the supported chain.
          </p>
          <button
            id="wallet-connect-btn"
            type="button"
            class="btn btn-primary btn-sm gap-1.5"
          >
            <.icon name="hero-wallet" class="size-3.5" /> Connect wallet
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Component: runtime card ---------------------------------------------

  attr :paused, :boolean, required: true

  defp runtime_card(assigns) do
    ~H"""
    <div id="runtime-card" class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5">
      <h3 class="text-sm font-semibold mb-3 flex items-center gap-1.5">
        <.icon name="hero-cog-6-tooth" class="size-4" /> Runtime
      </h3>
      <div class="flex items-center justify-between mb-4">
        <span class="text-sm text-base-content/60">Global status</span>
        <span :if={@paused} class="badge badge-warning badge-sm">Paused</span>
        <span :if={!@paused} class="badge badge-success badge-sm">Running</span>
      </div>
      <div class="flex gap-2">
        <.button
          :if={!@paused}
          id="pause-btn"
          phx-click="pause_runtime"
          data-confirm="Pause the runtime? New executions will be halted."
          class="btn btn-warning btn-soft btn-sm flex-1 gap-1.5"
        >
          <.icon name="hero-pause" class="size-3.5" /> Pause
        </.button>
        <.button
          :if={@paused}
          id="resume-btn"
          phx-click="resume_runtime"
          class="btn btn-success btn-soft btn-sm flex-1 gap-1.5"
        >
          <.icon name="hero-play" class="size-3.5" /> Resume
        </.button>
      </div>
    </div>
    """
  end

  # --- View helpers ---------------------------------------------------------

  defp delegation_badge_class(:active), do: "badge-success"
  defp delegation_badge_class(:pending), do: "badge-warning"
  defp delegation_badge_class(:revoking), do: "badge-error"
  defp delegation_badge_class(:revoke_failed), do: "badge-error"
  defp delegation_badge_class(_), do: "badge-ghost"

  defp delegation_label(:active), do: "Active"
  defp delegation_label(:pending), do: "Pending"
  defp delegation_label(:revoking), do: "Revoking"
  defp delegation_label(:revoke_failed), do: "Revoke failed"
  defp delegation_label(:revoked), do: "Revoked"
  defp delegation_label(:expired), do: "Expired"
  defp delegation_label(_), do: "Unknown"

  defp delegation_icon(:active), do: "hero-link-solid"
  defp delegation_icon(:pending), do: "hero-clock"
  defp delegation_icon(:revoking), do: "hero-shield-exclamation"
  defp delegation_icon(:revoke_failed), do: "hero-exclamation-triangle"
  defp delegation_icon(_), do: "hero-link-slash"

  defp delegation_icon_bg(:active), do: "bg-success/15 text-success"
  defp delegation_icon_bg(:pending), do: "bg-warning/15 text-warning"
  defp delegation_icon_bg(:revoking), do: "bg-error/15 text-error"
  defp delegation_icon_bg(:revoke_failed), do: "bg-error/15 text-error"
  defp delegation_icon_bg(_), do: "bg-base-300/50 text-base-content/40"

  defp short_id(nil), do: "-"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "..."
  defp short_id(id), do: id

  defp chain_label(8453), do: "Base (8453)"
  defp chain_label(84_532), do: "Base Sepolia (84532)"
  defp chain_label(nil), do: "-"
  defp chain_label(id) when is_integer(id), do: "Chain #{id}"

  defp short_hash(nil), do: "-"
  defp short_hash(hash) when byte_size(hash) > 14, do: String.slice(hash, 0, 10) <> "..."
  defp short_hash(hash), do: hash

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
