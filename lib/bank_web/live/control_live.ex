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

  **No browser wallet integration in v0.1.** The repo does not yet
  include a client-side wallet SDK (WalletConnect, wagmi, etc.).
  Delegation is established through the adapter callback flow, not
  through a browser-native sign-in. The UI makes this limitation
  explicit and shows the delegation state the backend already
  tracks.

  **Single smart account focus.** The MVP flow assumes one primary
  smart account. The UI shows the first non-terminal delegation
  if one exists, or a clear "not connected" state if none does.
  Multi-account management is a follow-up.
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
      |> load_state()

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_state() |> put_flash(:info, "Status refreshed")}
  end

  def handle_event("revoke_delegation", %{"smart-account-id" => sa_id}, socket) do
    case Security.revoke_delegation(sa_id, reason: :operator_requested, actor: :user) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> load_state()
         |> put_flash(:info, "Delegation revoke submitted. Awaiting on-chain confirmation.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Revoke failed: #{inspect(reason)}")}
    end
  end

  def handle_event("pause_runtime", _params, socket) do
    case Security.pause(:global, reason: :operator_requested, actor: :user) do
      {:ok, _} ->
        {:noreply, socket |> load_state() |> put_flash(:info, "Runtime paused")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Pause failed: #{inspect(reason)}")}
    end
  end

  def handle_event("resume_runtime", _params, socket) do
    case Security.resume(:global, actor: :user) do
      {:ok, _} ->
        {:noreply, socket |> load_state() |> put_flash(:info, "Runtime resumed")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Resume failed: #{inspect(reason)}")}
    end
  end

  # --- PubSub handlers ----------------------------------------------------

  @impl true
  def handle_info(%{topic: :security_events}, socket) do
    {:noreply, load_state(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State loading -------------------------------------------------------

  defp load_state(socket) do
    delegations = Delegations.list_active()
    paused? = Security.paused?(:global)
    primary = List.first(delegations)

    execution_ready? =
      case primary do
        %{smart_account_id: sa_id, state: :active} -> Delegations.executable?(sa_id)
        _ -> false
      end

    socket
    |> assign(:delegations, delegations)
    |> assign(:primary_delegation, primary)
    |> assign(:paused, paused?)
    |> assign(:execution_ready, execution_ready?)
  end

  # --- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_page={:connection}>
      <%!-- System status bar --%>
      <.system_status_bar paused={@paused} execution_ready={@execution_ready} />

      <%!-- Page header --%>
      <div class="mt-6 mb-8">
        <h1 id="page-title" class="text-2xl font-bold tracking-tight">Connection</h1>
        <p class="mt-1 text-sm text-base-content/60">
          Smart-account delegation and execution readiness
        </p>
      </div>

      <%!-- Main grid --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Left column: delegation card (spans 2) --%>
        <div class="lg:col-span-2 space-y-6">
          <.delegation_card delegation={@primary_delegation} paused={@paused} />
        </div>

        <%!-- Right column: status + actions --%>
        <div class="space-y-6">
          <.next_steps_card
            delegation={@primary_delegation}
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
          :if={@execution_ready}
          status={:info}
          text="Intents submitted by agents will be evaluated and routed"
        />
        <.step_item
          :if={is_nil(@delegation)}
          status={:info}
          text="Browser wallet connection is not yet available in v0.1"
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
  defp delegation_badge_class(_), do: "badge-ghost"

  defp delegation_label(:active), do: "Active"
  defp delegation_label(:pending), do: "Pending"
  defp delegation_label(:revoking), do: "Revoking"
  defp delegation_label(:revoked), do: "Revoked"
  defp delegation_label(:expired), do: "Expired"
  defp delegation_label(_), do: "Unknown"

  defp delegation_icon(:active), do: "hero-link-solid"
  defp delegation_icon(:pending), do: "hero-clock"
  defp delegation_icon(:revoking), do: "hero-shield-exclamation"
  defp delegation_icon(_), do: "hero-link-slash"

  defp delegation_icon_bg(:active), do: "bg-success/15 text-success"
  defp delegation_icon_bg(:pending), do: "bg-warning/15 text-warning"
  defp delegation_icon_bg(:revoking), do: "bg-error/15 text-error"
  defp delegation_icon_bg(_), do: "bg-base-300/50 text-base-content/40"

  defp short_id(nil), do: "-"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "..."
  defp short_id(id), do: id

  defp short_hash(nil), do: "-"
  defp short_hash(hash) when byte_size(hash) > 14, do: String.slice(hash, 0, 10) <> "..."
  defp short_hash(hash), do: hash

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
