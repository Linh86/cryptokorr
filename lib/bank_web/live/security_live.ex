defmodule BankWeb.SecurityLive do
  @moduledoc """
  Security console — runtime safety posture and emergency controls.

  This is the operator's "is the runtime safe right now?" page. It
  consolidates the three safety levers in one place:

    * **Runtime pause / resume** — halts new `executing` transitions.
    * **Delegation status** — current grants and revoke action.
    * **Recent safety events** — pause/resume/revoke audit slice.

  ## Design decisions

  **One page, all controls.** The `Connection` page exposes the same
  pause/revoke for the primary delegation as a side-panel. This page
  is the canonical surface — it shows every active delegation (not
  just the primary), every safety-relevant event in one panel, and is
  reachable from the sidebar without navigating into Connection first.

  **Failure-safe posture.** All confirmations are inline `data-confirm`
  prompts, not separate flows. The runtime never auto-unpauses. A
  revoke is treated as authoritative the moment the API call accepts
  it — the UI shows `:revoking` immediately so an operator can't
  double-tap and create two revoke jobs.

  **Real-time.** Subscribes to `security:events` and `audit:stream` so
  pause/resume/revoke changes from any source (this UI, the API,
  another operator) are reflected immediately.
  """

  use BankWeb, :live_view

  alias Bank.Audit
  alias Bank.Delegations
  alias Bank.Security

  # Audit event types that belong on the safety timeline.
  @safety_event_types [
    "security.paused",
    "security.resumed",
    "delegation.revoke_requested",
    "delegation.revoked",
    "delegation.state_changed"
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.security_events())
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())
    end

    socket =
      socket
      |> assign(page_title: "Security")
      |> load_state()

    {:ok, socket}
  end

  # --- Events ---------------------------------------------------------------

  @impl true
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

  def handle_event("revoke_delegation", %{"smart-account-id" => sa_id}, socket) do
    case Security.revoke_delegation(sa_id, reason: :operator_requested, actor: :user) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> load_state()
         |> put_flash(:info, "Delegation revoke submitted. Awaiting on-chain confirmation.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Revoke failed: #{inspect(reason)}")}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_state() |> put_flash(:info, "Console refreshed")}
  end

  # --- PubSub handlers ------------------------------------------------------

  @impl true
  def handle_info(%{topic: topic}, socket) when topic in [:security_events, :audit_stream] do
    {:noreply, load_state(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State loading --------------------------------------------------------

  defp load_state(socket) do
    delegations = Delegations.list_active()
    paused? = Security.paused?(:global)
    pause_snapshot = Security.snapshot()

    primary = List.first(delegations)

    execution_ready? =
      case primary do
        %{smart_account_id: sa_id, state: :active} -> Delegations.executable?(sa_id)
        _ -> false
      end

    safety_events = load_safety_events()

    socket
    |> assign(:paused, paused?)
    |> assign(:pause_snapshot, pause_snapshot)
    |> assign(:delegations, delegations)
    |> assign(:execution_ready, execution_ready?)
    |> assign(:safety_events, safety_events)
  end

  # Pulls the most recent safety events. We pass each safety event_type
  # individually because `Bank.Audit.list_events/2` does exact match;
  # then we union and sort. Capped small — this is a "is the runtime
  # safe right now?" view, not a forensic timeline.
  defp load_safety_events do
    @safety_event_types
    |> Enum.flat_map(fn type ->
      %{events: events} = Audit.list_events(%{event_type: type}, limit: 10, order: :desc)
      events
    end)
    |> Enum.sort_by(& &1.ts, {:desc, DateTime})
    |> Enum.take(15)
  end

  # --- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_page={:security}>
      <%!-- Page header --%>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 id="page-title" class="text-2xl font-bold tracking-tight">Security console</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Runtime safety posture and emergency controls
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <%!-- Posture banner --%>
      <.posture_banner
        paused={@paused}
        execution_ready={@execution_ready}
        delegation_count={length(@delegations)}
      />

      <%!-- Main grid --%>
      <div class="mt-6 grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Left column: runtime + delegations --%>
        <div class="lg:col-span-2 space-y-6">
          <.runtime_card paused={@paused} pause_snapshot={@pause_snapshot} />
          <.delegations_card delegations={@delegations} />
        </div>

        <%!-- Right column: safety events --%>
        <div>
          <.safety_events_card events={@safety_events} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Component: posture banner -------------------------------------------

  attr :paused, :boolean, required: true
  attr :execution_ready, :boolean, required: true
  attr :delegation_count, :integer, required: true

  defp posture_banner(%{paused: true} = assigns) do
    ~H"""
    <div
      id="posture-banner"
      data-posture="paused"
      class="rounded-xl border border-warning/30 bg-warning/10 p-5 flex items-start gap-3"
    >
      <.icon name="hero-pause-circle-solid" class="size-6 text-warning shrink-0" />
      <div>
        <h2 class="text-sm font-semibold text-warning">Runtime is paused</h2>
        <p class="mt-1 text-xs text-base-content/70">
          New executions are halted. Decisions and intents may still be written;
          nothing enters <code>:executing</code> until the runtime is resumed.
        </p>
      </div>
    </div>
    """
  end

  defp posture_banner(%{delegation_count: 0} = assigns) do
    ~H"""
    <div
      id="posture-banner"
      data-posture="no-delegation"
      class="rounded-xl border border-base-300 bg-base-200/40 p-5 flex items-start gap-3"
    >
      <.icon name="hero-link-slash" class="size-6 text-base-content/40 shrink-0" />
      <div>
        <h2 class="text-sm font-semibold text-base-content/70">No active delegation</h2>
        <p class="mt-1 text-xs text-base-content/60">
          No smart account has an active delegation. Execution is impossible
          until a delegation is established through the adapter callback flow.
        </p>
      </div>
    </div>
    """
  end

  defp posture_banner(%{execution_ready: true} = assigns) do
    ~H"""
    <div
      id="posture-banner"
      data-posture="ready"
      class="rounded-xl border border-success/30 bg-success/10 p-5 flex items-start gap-3"
    >
      <.icon name="hero-shield-check" class="size-6 text-success shrink-0" />
      <div>
        <h2 class="text-sm font-semibold text-success">Runtime is safe and execution-ready</h2>
        <p class="mt-1 text-xs text-base-content/70">
          The primary delegation is active and the runtime is running. Auto-execute
          decisions will proceed; held and approval-required ones still need operator review.
        </p>
      </div>
    </div>
    """
  end

  defp posture_banner(assigns) do
    ~H"""
    <div
      id="posture-banner"
      data-posture="blocked"
      class="rounded-xl border border-base-300 bg-base-200/40 p-5 flex items-start gap-3"
    >
      <.icon name="hero-shield-exclamation" class="size-6 text-base-content/60 shrink-0" />
      <div>
        <h2 class="text-sm font-semibold text-base-content/80">Execution blocked</h2>
        <p class="mt-1 text-xs text-base-content/60">
          A delegation exists but is not in the active state. Check the delegation
          panel below for the current state.
        </p>
      </div>
    </div>
    """
  end

  # --- Component: runtime card ---------------------------------------------

  attr :paused, :boolean, required: true
  attr :pause_snapshot, :map, required: true

  defp runtime_card(assigns) do
    ~H"""
    <section
      id="runtime-card"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-cog-6-tooth" class="size-4" /> Runtime
        </h2>
        <span :if={@paused} class="badge badge-warning badge-sm">Paused</span>
        <span :if={!@paused} class="badge badge-success badge-sm">Running</span>
      </header>
      <div class="px-6 py-5">
        <p :if={!@paused} class="text-sm text-base-content/70">
          The runtime is processing decisions and execution transitions normally.
          Pausing halts new <code>:executing</code> transitions but does not drop
          inbound intents or suppress decision writing.
        </p>
        <div :if={@paused} class="space-y-3">
          <p class="text-sm text-base-content/70">
            Pause is in effect. Existing decisions are still written; nothing
            enters <code>:executing</code> until resumed.
          </p>
          <dl :if={@pause_snapshot.global} class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Paused at
              </dt>
              <dd class="font-mono text-base-content/80">
                {format_datetime(@pause_snapshot.global.paused_at)}
              </dd>
            </div>
            <div>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Reason
              </dt>
              <dd class="font-mono text-base-content/80">
                {@pause_snapshot.global.reason}
              </dd>
            </div>
            <div>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Actor
              </dt>
              <dd class="font-mono text-base-content/80">
                {@pause_snapshot.global.actor}
              </dd>
            </div>
            <div :if={@pause_snapshot.global.actor_id}>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Actor id
              </dt>
              <dd class="font-mono text-base-content/80">
                {@pause_snapshot.global.actor_id}
              </dd>
            </div>
          </dl>
        </div>
      </div>
      <footer class="flex items-center gap-2 px-6 py-4 border-t border-base-300 bg-base-200/20">
        <.button
          :if={!@paused}
          id="pause-btn"
          phx-click="pause_runtime"
          data-confirm="Pause the runtime? New executions will be halted. The runtime never auto-unpauses."
          class="btn btn-warning btn-soft btn-sm gap-1.5"
        >
          <.icon name="hero-pause" class="size-3.5" /> Pause runtime
        </.button>
        <.button
          :if={@paused}
          id="resume-btn"
          phx-click="resume_runtime"
          class="btn btn-success btn-soft btn-sm gap-1.5"
        >
          <.icon name="hero-play" class="size-3.5" /> Resume runtime
        </.button>
      </footer>
    </section>
    """
  end

  # --- Component: delegations card -----------------------------------------

  attr :delegations, :list, required: true

  defp delegations_card(assigns) do
    ~H"""
    <section
      id="delegations-card"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-link" class="size-4" /> Delegations
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@delegations)}</span>
      </header>
      <div :if={@delegations == []} class="px-6 py-8 text-center text-sm text-base-content/50">
        No active delegations. Establish one through the adapter callback flow.
      </div>
      <ul :if={@delegations != []} class="divide-y divide-base-300">
        <li :for={delegation <- @delegations} class="px-6 py-4">
          <.delegation_row delegation={delegation} />
        </li>
      </ul>
    </section>
    """
  end

  attr :delegation, :map, required: true

  defp delegation_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-sm font-mono">{short_id(@delegation.smart_account_id)}</span>
          <span class={["badge badge-sm", delegation_badge_class(@delegation.state)]}>
            {@delegation.state}
          </span>
        </div>
        <div class="mt-1 text-xs text-base-content/50 flex items-center gap-3 flex-wrap">
          <span>chain: {@delegation.chain || "—"}</span>
          <span>delegation: {short_id(@delegation.delegation_id)}</span>
          <span :if={@delegation.granted_at}>
            granted: {format_datetime(@delegation.granted_at)}
          </span>
          <span :if={@delegation.revoke_requested_at}>
            revoke requested: {format_datetime(@delegation.revoke_requested_at)}
          </span>
        </div>
      </div>
      <.button
        :if={@delegation.state in [:active, :pending]}
        id={"revoke-btn-#{@delegation.smart_account_id}"}
        phx-click="revoke_delegation"
        phx-value-smart-account-id={@delegation.smart_account_id}
        data-confirm="Revoke this delegation? Execution will stop immediately. This cannot be undone from the API."
        class="btn btn-error btn-soft btn-xs gap-1.5"
      >
        <.icon name="hero-shield-exclamation" class="size-3" /> Revoke
      </.button>
    </div>
    """
  end

  # --- Component: safety events card ---------------------------------------

  attr :events, :list, required: true

  defp safety_events_card(assigns) do
    ~H"""
    <section
      id="safety-events-card"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-bell-alert" class="size-4" /> Recent safety events
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@events)}</span>
      </header>
      <div :if={@events == []} class="px-6 py-8 text-center text-sm text-base-content/50">
        No safety events recorded yet.
      </div>
      <ol :if={@events != []} class="divide-y divide-base-300">
        <li :for={event <- @events} class="px-6 py-3">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <span class={[
                  "badge badge-sm font-mono",
                  event_type_badge_class(event.event_type)
                ]}>
                  {event.event_type}
                </span>
                <span class="badge badge-sm badge-ghost gap-1">
                  <.icon name={actor_icon(event.actor)} class="size-3" />
                  {event.actor}
                </span>
              </div>
              <div class="mt-1 text-[0.7rem] text-base-content/50 font-mono">
                {event.subject_type} &middot; {short_id(event.subject_id)}
              </div>
            </div>
            <span class="text-[0.7rem] text-base-content/40 font-mono shrink-0">
              {format_datetime(event.ts)}
            </span>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  # --- View helpers ---------------------------------------------------------

  defp delegation_badge_class(:active), do: "badge-success"
  defp delegation_badge_class(:pending), do: "badge-warning"
  defp delegation_badge_class(:revoking), do: "badge-error"
  defp delegation_badge_class(:revoked), do: "badge-ghost"
  defp delegation_badge_class(:expired), do: "badge-ghost"
  defp delegation_badge_class(_), do: "badge-ghost"

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
