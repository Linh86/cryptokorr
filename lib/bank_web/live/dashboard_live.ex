defmodule BankWeb.DashboardLive do
  @moduledoc """
  Operator dashboard — high-signal overview of the runtime state.

  Shows:

    * Runtime status (paused / running)
    * Delegation and execution readiness
    * Pending approvals count
    * Active (in-flight) executions count
    * Recent decisions
    * A "needs attention" summary that aggregates actionable items

  All cards pull real backend data and update in real-time via PubSub
  subscriptions to `security:events`, `approval:queue`,
  `dashboard:runtime_status`, and `audit:stream`.
  """

  use BankWeb, :live_view

  alias Bank.Decisions
  alias Bank.Delegations
  alias Bank.Security
  alias Bank.Workspaces
  alias Bank.Workspaces.Workspace

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.security_events())
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.approval_queue())
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.dashboard_runtime_status())
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())
    end

    socket =
      socket
      |> assign(page_title: "Dashboard")
      |> load_state()

    {:ok, socket}
  end

  # --- Events ---------------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_state() |> put_flash(:info, "Dashboard refreshed")}
  end

  # --- PubSub handlers ------------------------------------------------------

  @impl true
  def handle_info(%{topic: topic}, socket)
      when topic in [
             :security_events,
             :approval_queue,
             :dashboard_runtime_status,
             :audit_stream
           ] do
    {:noreply, load_state(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State loading --------------------------------------------------------

  defp load_state(socket) do
    workspace_id = socket.assigns.current_scope.workspace.id
    scope_opts = [workspace_id: workspace_id]

    # Re-fetch the workspace fresh so that an `agent_keys.paused`
    # event from another tab is reflected on the next PubSub tick;
    # `current_scope.workspace` is mount-time only. Mirrors the
    # SecurityLive pattern.
    workspace =
      Workspaces.get_workspace(workspace_id) ||
        socket.assigns.current_scope.workspace

    agent_keys_paused? = Workspace.agent_keys_paused?(workspace)

    delegations = Delegations.list_active(scope_opts)
    paused? = Security.paused?(:global)

    executable_count =
      Enum.count(delegations, fn
        %{state: :active, smart_account_id: sa_id} -> Delegations.executable?(sa_id)
        _ -> false
      end)

    execution_ready? = executable_count > 0

    pending_approvals = Decisions.count_pending_approvals(scope_opts)
    active_executions = Decisions.count_active_executions(scope_opts)
    recent_decisions = Decisions.list_recent_decisions(8, scope_opts)

    # Stuck-plan count (#229 dashboard surfacing). Workspace-scoped via
    # `Health.stuck_plan_details/1`'s `:workspace_id` option (added in
    # PR #308); the per-status DB query applies the workspace filter
    # before its `LIMIT`, so sibling-tenant rows cannot starve the
    # current workspace's slot. `:limit: 25` caps the read while still
    # being enough to count comfortably above the SecurityLive card's
    # `limit: 10` display window.
    stuck_plan_count =
      Bank.Ops.Health.stuck_plan_details(workspace_id: workspace_id, limit: 25)
      |> length()

    attention_items =
      build_attention_items(
        paused?,
        agent_keys_paused?,
        delegations,
        pending_approvals,
        active_executions,
        stuck_plan_count
      )

    socket
    |> assign(:paused, paused?)
    |> assign(:agent_keys_paused, agent_keys_paused?)
    |> assign(:delegations, delegations)
    |> assign(:executable_count, executable_count)
    |> assign(:execution_ready, execution_ready?)
    |> assign(:pending_approvals, pending_approvals)
    |> assign(:active_executions, active_executions)
    |> assign(:stuck_plan_count, stuck_plan_count)
    |> assign(:recent_decisions, recent_decisions)
    |> assign(:attention_items, attention_items)
  end

  defp build_attention_items(
         paused?,
         agent_keys_paused?,
         delegations,
         pending_approvals,
         active_executions,
         stuck_plan_count
       ) do
    items = []

    items =
      if paused?,
        do: [
          %{
            id: "attention-runtime-paused",
            severity: :warning,
            text: "Runtime is paused — no new executions will proceed",
            link: "/security#runtime-card"
          }
          | items
        ],
        else: items

    # Workspace-level kill-switch (#229 dashboard surfacing). Distinct
    # from runtime pause: workspace agent-key pause refuses /v1 traffic
    # for this workspace's API keys only. Linked to the destination
    # card that owns the resume action.
    items =
      if agent_keys_paused?,
        do: [
          %{
            id: "attention-agent-keys-paused",
            severity: :warning,
            text: "Workspace API keys paused — all /v1 traffic is refused",
            link: "/security#agent-keys-pause-panel"
          }
          | items
        ],
        else: items

    items =
      if delegations == [],
        do: [
          %{severity: :error, text: "No delegation connected — execution is impossible"} | items
        ],
        else: items

    revoking_count = Enum.count(delegations, &(&1.state == :revoking))

    items =
      cond do
        revoking_count == 1 ->
          [
            %{
              id: "attention-delegation-revoking",
              severity: :warning,
              text: "Delegation revocation in flight",
              link: "/security#delegations-card"
            }
            | items
          ]

        revoking_count > 1 ->
          [
            %{
              id: "attention-delegation-revoking",
              severity: :warning,
              text: "Delegation revocations in flight (#{revoking_count})",
              link: "/security#delegations-card"
            }
            | items
          ]

        true ->
          items
      end

    revoke_failed_count = Enum.count(delegations, &(&1.state == :revoke_failed))

    items =
      cond do
        revoke_failed_count == 1 ->
          [
            %{
              id: "attention-delegation-revoke-failed",
              severity: :error,
              text: "Delegation revoke failed on-chain — operator retry required",
              link: "/security#delegations-card"
            }
            | items
          ]

        revoke_failed_count > 1 ->
          [
            %{
              id: "attention-delegation-revoke-failed",
              severity: :error,
              text:
                "#{revoke_failed_count} delegations in revoke_failed — operator retry required",
              link: "/security#delegations-card"
            }
            | items
          ]

        true ->
          items
      end

    items =
      if pending_approvals > 0,
        do: [
          %{
            id: "attention-pending-approvals",
            severity: :info,
            text: "#{pending_approvals} decision(s) awaiting approval",
            link: "/queue#pending-approvals-section"
          }
          | items
        ],
        else: items

    items =
      if active_executions > 0,
        do: [
          %{
            id: "attention-active-executions",
            severity: :info,
            text: "#{active_executions} execution(s) in flight",
            link: "/queue#active-executions-section"
          }
          | items
        ],
        else: items

    items =
      cond do
        stuck_plan_count == 1 ->
          [
            %{
              id: "attention-stuck-plans",
              severity: :warning,
              text: "1 execution plan stuck past threshold",
              link: "/security#stuck-plans-card"
            }
            | items
          ]

        stuck_plan_count > 1 ->
          [
            %{
              id: "attention-stuck-plans",
              severity: :warning,
              text: "#{stuck_plan_count} execution plans stuck past threshold",
              link: "/security#stuck-plans-card"
            }
            | items
          ]

        true ->
          items
      end

    Enum.reverse(items)
  end

  # --- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:dashboard}>
      <%!-- Page header --%>
      <div class="flex items-center justify-between mb-8">
        <div>
          <h1 id="page-title" class="text-2xl font-bold tracking-tight">Dashboard</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Runtime overview and operational summary
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <%!-- Attention banner --%>
      <.attention_banner :if={@attention_items != []} items={@attention_items} />

      <%!-- Stat cards --%>
      <div id="stat-cards" class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <.stat_card
          id="runtime-status-card"
          label="Runtime"
          value={if @paused, do: "Paused", else: "Running"}
          icon="hero-cog-6-tooth"
          color={if @paused, do: "warning", else: "success"}
        />
        <.stat_card
          id="delegation-status-card"
          label={delegation_stat_label(@delegations)}
          value={delegation_stat_value(@delegations, @executable_count)}
          icon="hero-signal"
          color={delegation_stat_color(@delegations, @executable_count)}
        />
        <.stat_card
          id="pending-approvals-card"
          label="Pending approvals"
          value={@pending_approvals}
          icon="hero-clock"
          color={if @pending_approvals > 0, do: "info", else: "ghost"}
        />
        <.stat_card
          id="active-executions-card"
          label="Active executions"
          value={@active_executions}
          icon="hero-bolt"
          color={if @active_executions > 0, do: "info", else: "ghost"}
        />
      </div>

      <%!-- Main grid --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Left column: recent decisions (spans 2) --%>
        <div class="lg:col-span-2">
          <.recent_decisions_card decisions={@recent_decisions} />
        </div>

        <%!-- Right column: execution readiness --%>
        <div class="space-y-6">
          <.readiness_card
            paused={@paused}
            delegations={@delegations}
            executable_count={@executable_count}
            execution_ready={@execution_ready}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Component: attention banner -------------------------------------------

  attr :items, :list, required: true

  defp attention_banner(assigns) do
    ~H"""
    <div id="attention-banner" class="mb-6 rounded-xl border border-warning/30 bg-warning/5 p-4">
      <h3 class="text-sm font-semibold mb-2 flex items-center gap-1.5">
        <.icon name="hero-exclamation-triangle" class="size-4 text-warning" /> Needs attention
      </h3>
      <ul class="space-y-1.5">
        <li
          :for={item <- @items}
          id={item[:id]}
          class="flex items-center gap-2 text-sm"
        >
          <span class={["badge badge-xs", attention_badge_class(item.severity)]} />
          <span class="text-base-content/80">{item.text}</span>
          <.link
            :if={item[:link]}
            navigate={item.link}
            class="ml-1 link link-primary text-xs"
            data-role="attention-link"
          >
            Review
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  # --- Component: stat card --------------------------------------------------

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :color, :string, default: "ghost"

  defp stat_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-4">
      <div class="flex items-center gap-2 mb-2">
        <div class={["w-8 h-8 rounded-lg flex items-center justify-center", stat_icon_bg(@color)]}>
          <.icon name={@icon} class="size-4" />
        </div>
        <span class="text-xs text-base-content/50 uppercase tracking-wider">{@label}</span>
      </div>
      <p class={["text-xl font-bold", stat_value_class(@color)]}>{@value}</p>
    </div>
    """
  end

  # --- Component: recent decisions card --------------------------------------

  attr :decisions, :list, required: true

  defp recent_decisions_card(assigns) do
    ~H"""
    <div id="recent-decisions-card" class="rounded-xl border border-base-300 bg-base-100 shadow-sm">
      <div class="px-6 py-4 border-b border-base-300">
        <h3 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-scale" class="size-4" /> Recent decisions
        </h3>
      </div>
      <div :if={@decisions == []} class="px-6 py-10 text-center">
        <p class="text-sm text-base-content/40">No decisions yet</p>
        <p class="text-xs text-base-content/30 mt-1">
          Decisions appear here as intents are evaluated by the trust engine
        </p>
      </div>
      <div :if={@decisions != []} class="divide-y divide-base-300">
        <div
          :for={decision <- @decisions}
          class="flex items-center justify-between px-6 py-3"
        >
          <div class="flex items-center gap-3 min-w-0">
            <div class={[
              "w-7 h-7 rounded-md flex items-center justify-center shrink-0",
              outcome_icon_bg(decision.outcome)
            ]}>
              <.icon name={outcome_icon(decision.outcome)} class="size-3.5" />
            </div>
            <div class="min-w-0">
              <p class="text-sm font-medium truncate">
                {outcome_label(decision.outcome)}
                <span class="text-base-content/40 font-normal">
                  &middot; {risk_label(decision.risk_tier)}
                </span>
              </p>
              <p class="text-xs text-base-content/40 font-mono truncate">
                {short_id(decision.id)}
                {if decision.intent, do: " &middot; #{intent_summary(decision.intent)}", else: ""}
              </p>
            </div>
          </div>
          <div class="shrink-0 ml-3">
            <span class={["badge badge-sm", outcome_badge_class(decision.outcome)]}>
              {decision.outcome}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Component: readiness card ---------------------------------------------

  attr :paused, :boolean, required: true
  attr :delegations, :list, required: true
  attr :executable_count, :integer, required: true
  attr :execution_ready, :boolean, required: true

  defp readiness_card(assigns) do
    ~H"""
    <div id="readiness-card" class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5">
      <h3 class="text-sm font-semibold mb-4 flex items-center gap-1.5">
        <.icon name="hero-check-badge" class="size-4" /> Execution readiness
      </h3>
      <ul class="space-y-3">
        <.readiness_item
          label="Runtime"
          ok={!@paused}
          detail={if @paused, do: "Paused", else: "Running"}
        />
        <.readiness_item
          label="Delegations"
          ok={@executable_count > 0}
          detail={delegations_detail(@delegations, @executable_count)}
        />
        <.readiness_item
          label="Execution"
          ok={@execution_ready}
          detail={if @execution_ready, do: "Ready", else: "Blocked"}
        />
      </ul>
      <div :if={@execution_ready} class="mt-4 p-3 rounded-lg bg-success/10">
        <p class="text-xs text-success font-medium flex items-center gap-1.5">
          <.icon name="hero-check-circle-solid" class="size-3.5" /> System is ready to process intents
        </p>
      </div>
      <div :if={!@execution_ready} class="mt-4 p-3 rounded-lg bg-base-200/50">
        <p class="text-xs text-base-content/50 flex items-center gap-1.5">
          <.icon name="hero-minus-circle-solid" class="size-3.5" />
          Resolve above issues to enable execution
        </p>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :ok, :boolean, required: true
  attr :detail, :string, required: true

  defp readiness_item(assigns) do
    ~H"""
    <li class="flex items-center justify-between">
      <div class="flex items-center gap-2">
        <.icon
          :if={@ok}
          name="hero-check-circle-solid"
          class="size-4 text-success"
        />
        <.icon
          :if={!@ok}
          name="hero-x-circle-solid"
          class="size-4 text-error"
        />
        <span class="text-sm">{@label}</span>
      </div>
      <span class={["text-xs", if(@ok, do: "text-success", else: "text-base-content/50")]}>
        {@detail}
      </span>
    </li>
    """
  end

  # --- View helpers -----------------------------------------------------------

  defp delegation_stat_label([]), do: "Delegations"
  defp delegation_stat_label([_]), do: "Delegation"
  defp delegation_stat_label(_), do: "Delegations"

  defp delegation_stat_value([], _), do: "Not connected"
  defp delegation_stat_value([%{state: state}], _), do: state_word(state)

  defp delegation_stat_value(delegations, executable_count) do
    "#{executable_count}/#{length(delegations)} active"
  end

  defp delegation_stat_color([], _), do: "error"
  defp delegation_stat_color([%{state: :active}], _), do: "success"
  defp delegation_stat_color([%{state: :pending}], _), do: "warning"
  defp delegation_stat_color([%{state: :revoking}], _), do: "error"
  defp delegation_stat_color([%{state: :revoke_failed}], _), do: "error"
  defp delegation_stat_color(_, 0), do: "warning"
  defp delegation_stat_color(_, _), do: "success"

  defp state_word(:active), do: "Active"
  defp state_word(:pending), do: "Pending"
  defp state_word(:revoking), do: "Revoking"
  defp state_word(:revoke_failed), do: "Revoke failed"
  defp state_word(state), do: state |> to_string() |> String.capitalize()

  defp delegations_detail([], _), do: "None"
  defp delegations_detail([%{state: state}], _), do: state_word(state)

  defp delegations_detail(delegations, executable_count) do
    "#{executable_count}/#{length(delegations)} executable"
  end

  defp outcome_label(:auto_exec), do: "Auto-execute"
  defp outcome_label(:hold), do: "Hold"
  defp outcome_label(:approval_required), do: "Approval required"
  defp outcome_label(:block), do: "Blocked"
  defp outcome_label(_), do: "Unknown"

  defp outcome_icon(:auto_exec), do: "hero-bolt-solid"
  defp outcome_icon(:hold), do: "hero-pause-solid"
  defp outcome_icon(:approval_required), do: "hero-clock-solid"
  defp outcome_icon(:block), do: "hero-x-mark-solid"
  defp outcome_icon(_), do: "hero-question-mark-circle"

  defp outcome_icon_bg(:auto_exec), do: "bg-success/15 text-success"
  defp outcome_icon_bg(:hold), do: "bg-warning/15 text-warning"
  defp outcome_icon_bg(:approval_required), do: "bg-info/15 text-info"
  defp outcome_icon_bg(:block), do: "bg-error/15 text-error"
  defp outcome_icon_bg(_), do: "bg-base-300/50 text-base-content/40"

  defp outcome_badge_class(:auto_exec), do: "badge-success"
  defp outcome_badge_class(:hold), do: "badge-warning"
  defp outcome_badge_class(:approval_required), do: "badge-info"
  defp outcome_badge_class(:block), do: "badge-error"
  defp outcome_badge_class(_), do: "badge-ghost"

  defp risk_label(:low), do: "Low risk"
  defp risk_label(:moderate), do: "Moderate risk"
  defp risk_label(:elevated), do: "Elevated risk"
  defp risk_label(:severe), do: "Severe risk"
  defp risk_label(_), do: "Unknown risk"

  defp stat_icon_bg("success"), do: "bg-success/15 text-success"
  defp stat_icon_bg("warning"), do: "bg-warning/15 text-warning"
  defp stat_icon_bg("error"), do: "bg-error/15 text-error"
  defp stat_icon_bg("info"), do: "bg-info/15 text-info"
  defp stat_icon_bg(_), do: "bg-base-300/50 text-base-content/40"

  defp stat_value_class("success"), do: "text-success"
  defp stat_value_class("warning"), do: "text-warning"
  defp stat_value_class("error"), do: "text-error"
  defp stat_value_class("info"), do: "text-info"
  defp stat_value_class(_), do: ""

  defp attention_badge_class(:error), do: "badge-error"
  defp attention_badge_class(:warning), do: "badge-warning"
  defp attention_badge_class(:info), do: "badge-info"
  defp attention_badge_class(_), do: "badge-ghost"

  defp intent_summary(%{kind: kind, asset: asset, amount: amount}) do
    "#{kind} #{amount} #{asset}"
  end

  defp intent_summary(_), do: ""

  defp short_id(nil), do: "-"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "..."
  defp short_id(id), do: id
end
