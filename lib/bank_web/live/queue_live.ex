defmodule BankWeb.QueueLive do
  @moduledoc """
  Action queue — decisions awaiting operator action.

  Shows three sections:

    * **Pending approvals** — decisions with outcome `:approval_required`
      whose approval window has not expired. Approve/reject buttons are
      rendered but disabled because the approval backend endpoints are
      not yet implemented (stubs return 501).

    * **Held actions** — decisions with outcome `:hold` that the trust
      engine held for manual review.

    * **Blocked actions** — decisions with outcome `:block`. Read-only
      for audit; the operator can investigate but not override.

  All sections use real backend data from `Bank.Decisions` and update
  live via PubSub on `approval:queue`, `security:events`, and
  `audit:stream`.
  """

  use BankWeb, :live_view

  alias Bank.Decisions

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.approval_queue())
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.security_events())
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())
    end

    socket =
      socket
      |> assign(page_title: "Action Queue")
      |> load_state()

    {:ok, socket}
  end

  # --- Events ---------------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_state() |> put_flash(:info, "Queue refreshed")}
  end

  # --- PubSub handlers ------------------------------------------------------

  @impl true
  def handle_info(%{topic: topic}, socket)
      when topic in [:approval_queue, :security_events, :audit_stream] do
    {:noreply, load_state(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State loading --------------------------------------------------------

  defp load_state(socket) do
    pending_approvals = Decisions.list_pending_approvals()
    held = Decisions.list_held_decisions()
    blocked = Decisions.list_blocked_decisions()
    active_executions = Decisions.list_active_executions()

    socket
    |> assign(:pending_approvals, pending_approvals)
    |> assign(:held_decisions, held)
    |> assign(:blocked_decisions, blocked)
    |> assign(:active_executions, active_executions)
    |> assign(:total_items, length(pending_approvals) + length(held) + length(blocked))
  end

  # --- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_page={:queue}>
      <%!-- Page header --%>
      <div class="flex items-center justify-between mb-8">
        <div>
          <h1 id="page-title" class="text-2xl font-bold tracking-tight">Action Queue</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Decisions and executions requiring attention
            <span :if={@total_items > 0} class="badge badge-sm badge-primary ml-1.5">
              {@total_items}
            </span>
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <%!-- Empty state --%>
      <div
        :if={@total_items == 0 && @active_executions == []}
        id="empty-queue"
        class="rounded-xl border-2 border-dashed border-base-300 bg-base-200/20 p-12 text-center"
      >
        <div class="w-14 h-14 rounded-full bg-base-300/50 flex items-center justify-center mx-auto mb-4">
          <.icon name="hero-inbox" class="size-7 text-base-content/30" />
        </div>
        <h2 class="text-lg font-semibold text-base-content/70">Queue is clear</h2>
        <p class="mt-2 text-sm text-base-content/50 max-w-md mx-auto">
          No decisions need attention right now. Items appear here when the
          trust engine holds, blocks, or requires approval for an intent.
        </p>
      </div>

      <%!-- Pending approvals section --%>
      <.queue_section
        :if={@pending_approvals != []}
        id="pending-approvals-section"
        title="Pending approvals"
        icon="hero-clock"
        count={length(@pending_approvals)}
        badge_class="badge-info"
      >
        <div class="divide-y divide-base-300">
          <.approval_row :for={decision <- @pending_approvals} decision={decision} />
        </div>
      </.queue_section>

      <%!-- Active executions section --%>
      <.queue_section
        :if={@active_executions != []}
        id="active-executions-section"
        title="Active executions"
        icon="hero-bolt"
        count={length(@active_executions)}
        badge_class="badge-success"
      >
        <div class="divide-y divide-base-300">
          <.execution_row :for={plan <- @active_executions} plan={plan} />
        </div>
      </.queue_section>

      <%!-- Held actions section --%>
      <.queue_section
        :if={@held_decisions != []}
        id="held-actions-section"
        title="Held actions"
        icon="hero-pause"
        count={length(@held_decisions)}
        badge_class="badge-warning"
      >
        <div class="divide-y divide-base-300">
          <.decision_row :for={decision <- @held_decisions} decision={decision} outcome={:hold} />
        </div>
      </.queue_section>

      <%!-- Blocked actions section --%>
      <.queue_section
        :if={@blocked_decisions != []}
        id="blocked-actions-section"
        title="Blocked actions"
        icon="hero-x-mark"
        count={length(@blocked_decisions)}
        badge_class="badge-error"
      >
        <div class="divide-y divide-base-300">
          <.decision_row
            :for={decision <- @blocked_decisions}
            decision={decision}
            outcome={:block}
          />
        </div>
      </.queue_section>
    </Layouts.app>
    """
  end

  # --- Component: queue section wrapper --------------------------------------

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :count, :integer, required: true
  attr :badge_class, :string, default: "badge-ghost"

  slot :inner_block, required: true

  defp queue_section(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-base-300 bg-base-100 shadow-sm mb-6">
      <div class="flex items-center justify-between px-6 py-4 border-b border-base-300">
        <h3 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name={@icon} class="size-4" /> {@title}
        </h3>
        <span class={["badge badge-sm", @badge_class]}>{@count}</span>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # --- Component: approval row -----------------------------------------------

  attr :decision, :map, required: true

  defp approval_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-6 py-4">
      <div class="flex items-center gap-3 min-w-0">
        <div class="w-8 h-8 rounded-md bg-info/15 text-info flex items-center justify-center shrink-0">
          <.icon name="hero-clock-solid" class="size-4" />
        </div>
        <div class="min-w-0">
          <p class="text-sm font-medium truncate">
            Approval required
            <span class="text-base-content/40 font-normal">
              &middot; {risk_label(@decision.risk_tier)}
            </span>
          </p>
          <p class="text-xs text-base-content/40 font-mono truncate">
            {short_id(@decision.id)}
            {if @decision.intent, do: " &middot; #{intent_summary(@decision.intent)}", else: ""}
          </p>
          <p :if={@decision.approval_expires_at} class="text-xs text-base-content/40 mt-0.5">
            Expires: {format_datetime(@decision.approval_expires_at)}
          </p>
        </div>
      </div>
      <div class="flex items-center gap-2 shrink-0 ml-3">
        <button
          class="btn btn-success btn-soft btn-xs gap-1 opacity-50 cursor-not-allowed"
          disabled
          title="Approval backend not yet implemented"
        >
          <.icon name="hero-check" class="size-3" /> Approve
        </button>
        <button
          class="btn btn-error btn-soft btn-xs gap-1 opacity-50 cursor-not-allowed"
          disabled
          title="Approval backend not yet implemented"
        >
          <.icon name="hero-x-mark" class="size-3" /> Reject
        </button>
      </div>
    </div>
    """
  end

  # --- Component: execution row ----------------------------------------------

  attr :plan, :map, required: true

  defp execution_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-6 py-4">
      <div class="flex items-center gap-3 min-w-0">
        <div class="w-8 h-8 rounded-md bg-success/15 text-success flex items-center justify-center shrink-0">
          <.icon name="hero-bolt-solid" class="size-4" />
        </div>
        <div class="min-w-0">
          <p class="text-sm font-medium truncate">
            Execution: {execution_status_label(@plan.execution_status)}
          </p>
          <p class="text-xs text-base-content/40 font-mono truncate">
            {short_id(@plan.id)}
            {if @plan.intent, do: " &middot; #{intent_summary(@plan.intent)}", else: ""}
          </p>
        </div>
      </div>
      <span class={["badge badge-sm", execution_badge_class(@plan.execution_status)]}>
        {@plan.execution_status}
      </span>
    </div>
    """
  end

  # --- Component: generic decision row ---------------------------------------

  attr :decision, :map, required: true
  attr :outcome, :atom, required: true

  defp decision_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-6 py-4">
      <div class="flex items-center gap-3 min-w-0">
        <div class={[
          "w-8 h-8 rounded-md flex items-center justify-center shrink-0",
          outcome_icon_bg(@outcome)
        ]}>
          <.icon name={outcome_icon(@outcome)} class="size-4" />
        </div>
        <div class="min-w-0">
          <p class="text-sm font-medium truncate">
            {outcome_label(@outcome)}
            <span class="text-base-content/40 font-normal">
              &middot; {risk_label(@decision.risk_tier)}
            </span>
          </p>
          <p class="text-xs text-base-content/40 font-mono truncate">
            {short_id(@decision.id)}
            {if @decision.intent, do: " &middot; #{intent_summary(@decision.intent)}", else: ""}
          </p>
        </div>
      </div>
      <span class={["badge badge-sm", outcome_badge_class(@outcome)]}>
        {@outcome}
      </span>
    </div>
    """
  end

  # --- View helpers -----------------------------------------------------------

  defp outcome_label(:hold), do: "Held"
  defp outcome_label(:block), do: "Blocked"
  defp outcome_label(:approval_required), do: "Approval required"
  defp outcome_label(:auto_exec), do: "Auto-execute"
  defp outcome_label(_), do: "Unknown"

  defp outcome_icon(:hold), do: "hero-pause-solid"
  defp outcome_icon(:block), do: "hero-x-mark-solid"
  defp outcome_icon(:approval_required), do: "hero-clock-solid"
  defp outcome_icon(:auto_exec), do: "hero-bolt-solid"
  defp outcome_icon(_), do: "hero-question-mark-circle"

  defp outcome_icon_bg(:hold), do: "bg-warning/15 text-warning"
  defp outcome_icon_bg(:block), do: "bg-error/15 text-error"
  defp outcome_icon_bg(:approval_required), do: "bg-info/15 text-info"
  defp outcome_icon_bg(:auto_exec), do: "bg-success/15 text-success"
  defp outcome_icon_bg(_), do: "bg-base-300/50 text-base-content/40"

  defp outcome_badge_class(:hold), do: "badge-warning"
  defp outcome_badge_class(:block), do: "badge-error"
  defp outcome_badge_class(:approval_required), do: "badge-info"
  defp outcome_badge_class(:auto_exec), do: "badge-success"
  defp outcome_badge_class(_), do: "badge-ghost"

  defp risk_label(:low), do: "Low risk"
  defp risk_label(:moderate), do: "Moderate"
  defp risk_label(:elevated), do: "Elevated"
  defp risk_label(:severe), do: "Severe"
  defp risk_label(_), do: "Unknown"

  defp execution_status_label(:prepared), do: "Prepared"
  defp execution_status_label(:signing), do: "Signing"
  defp execution_status_label(:broadcasting), do: "Broadcasting"
  defp execution_status_label(:pending_confirmation), do: "Confirming"
  defp execution_status_label(status), do: to_string(status)

  defp execution_badge_class(:prepared), do: "badge-ghost"
  defp execution_badge_class(:signing), do: "badge-warning"
  defp execution_badge_class(:broadcasting), do: "badge-info"
  defp execution_badge_class(:pending_confirmation), do: "badge-info"
  defp execution_badge_class(_), do: "badge-ghost"

  defp intent_summary(%{kind: kind, asset: asset, amount: amount}) do
    "#{kind} #{amount} #{asset}"
  end

  defp intent_summary(_), do: ""

  defp short_id(nil), do: "-"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "..."
  defp short_id(id), do: id

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
