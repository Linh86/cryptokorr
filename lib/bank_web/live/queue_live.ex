defmodule BankWeb.QueueLive do
  @moduledoc """
  Action queue — decisions awaiting operator action.

  Shows three sections:

    * **Pending approvals** — decisions with outcome `:approval_required`
      whose approval window has not expired. Approve/reject buttons
      call `Bank.Decisions.approve/2` and `reject/2` directly; the
      successor envelope, intent pointer, audit events, and downstream
      execution enqueue all commit in a single transaction.

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
      |> assign(:expanded_decisions, MapSet.new())
      |> assign(:operator_id, "console")
      |> load_state()

    {:ok, socket}
  end

  # --- Events ---------------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_state() |> put_flash(:info, "Queue refreshed")}
  end

  def handle_event("approve_decision", %{"decision-id" => id} = params, socket) do
    opts = approval_opts(socket, params)

    case Decisions.approve(id, opts) do
      {:ok, _successor, {:dispatched, plan}} ->
        {:noreply,
         socket
         |> load_state()
         |> put_flash(
           :info,
           "Approval recorded and dispatched (plan #{short_id(plan.id)}, " <>
             "smart_account=#{plan.smart_account_id})."
         )}

      {:ok, _successor, {:held, reason}} ->
        {:noreply,
         socket
         |> load_state()
         |> put_flash(
           :info,
           "Approval recorded; dispatch held (#{reason}). " <>
             "Resolve the gate and execute manually from the decision page."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, approval_error_message("Approve", reason))}
    end
  end

  def handle_event("reject_decision", %{"decision-id" => id} = params, socket) do
    opts = approval_opts(socket, params)

    case Decisions.reject(id, opts) do
      {:ok, _successor, :no_dispatch} ->
        {:noreply,
         socket
         |> load_state()
         |> put_flash(:info, "Decision rejected. Intent blocked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, approval_error_message("Reject", reason))}
    end
  end

  def handle_event("toggle_details", %{"decision-id" => id}, socket) do
    open = socket.assigns.expanded_decisions

    open =
      if MapSet.member?(open, id),
        do: MapSet.delete(open, id),
        else: MapSet.put(open, id)

    {:noreply, assign(socket, :expanded_decisions, open)}
  end

  defp approval_opts(socket, params) do
    actor_id =
      Map.get(params, "actor_id") ||
        Map.get(socket.assigns, :operator_id) ||
        "console"

    [actor_id: actor_id, reason: Map.get(params, "reason")]
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
  end

  defp approval_error_message(action, :not_found),
    do: "#{action} failed: decision not found"

  defp approval_error_message(action, :already_superseded),
    do: "#{action} failed: decision is no longer current"

  defp approval_error_message(action, {:wrong_outcome, outcome}),
    do: "#{action} failed: wrong outcome (#{outcome})"

  defp approval_error_message(action, reason),
    do: "#{action} failed: #{inspect(reason)}"

  # --- PubSub handlers ------------------------------------------------------

  @impl true
  def handle_info(%{topic: topic}, socket)
      when topic in [:approval_queue, :security_events, :audit_stream] do
    {:noreply, load_state(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State loading --------------------------------------------------------

  defp load_state(socket) do
    workspace_id = socket.assigns.current_scope.workspace.id
    scope_opts = [workspace_id: workspace_id]

    pending_approvals = Decisions.list_pending_approvals(scope_opts)
    held = Decisions.list_held_decisions(scope_opts)
    blocked = Decisions.list_blocked_decisions(20, scope_opts)
    active_executions = Decisions.list_active_executions(scope_opts)

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
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:queue}>
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
          <.approval_row
            :for={decision <- @pending_approvals}
            decision={decision}
            expanded={MapSet.member?(@expanded_decisions, decision.id)}
          />
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
  attr :expanded, :boolean, default: false

  defp approval_row(assigns) do
    ~H"""
    <div id={"approval-row-" <> @decision.id} class="px-6 py-4">
      <div class="flex items-start justify-between gap-3">
        <div class="flex items-start gap-3 min-w-0">
          <div class="w-8 h-8 rounded-md bg-info/15 text-info flex items-center justify-center shrink-0">
            <.icon name="hero-clock-solid" class="size-4" />
          </div>
          <div class="min-w-0">
            <p class="text-sm font-medium truncate flex items-center gap-2 flex-wrap">
              <span>Approval required</span>
              <span
                :if={@decision.intent && @decision.intent.kind == :swap}
                id={"approval-kind-badge-" <> @decision.id}
                class="badge badge-xs badge-accent"
              >
                swap
              </span>
              <span
                :if={@decision.intent && @decision.intent.kind == :defi_yield_deposit}
                id={"approval-morpho-badge-" <> @decision.id}
                class="badge badge-xs badge-accent"
              >
                morpho deposit
              </span>
              <span class="text-base-content/40 font-normal">
                &middot; {risk_label(@decision.risk_tier)}
              </span>
            </p>
            <p class="text-xs text-base-content/40 font-mono truncate">
              {short_id(@decision.id)}
              <span :if={@decision.intent}>
                &middot; {intent_summary(@decision.intent)}
              </span>
            </p>
            <p :if={@decision.approval_expires_at} class="text-xs text-base-content/40 mt-0.5">
              {approval_expiry_label(@decision.approval_expires_at)}
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2 shrink-0">
          <button
            type="button"
            id={"details-btn-" <> @decision.id}
            phx-click="toggle_details"
            phx-value-decision-id={@decision.id}
            class="btn btn-ghost btn-xs gap-1"
          >
            <.icon
              name={if @expanded, do: "hero-chevron-up", else: "hero-chevron-down"}
              class="size-3"
            />
            {if @expanded, do: "Hide", else: "Details"}
          </button>
          <button
            type="button"
            id={"approve-btn-" <> @decision.id}
            phx-click="approve_decision"
            phx-value-decision-id={@decision.id}
            data-confirm="Approve this decision? Execution will be enqueued immediately."
            class="btn btn-success btn-soft btn-xs gap-1"
          >
            <.icon name="hero-check" class="size-3" /> Approve
          </button>
          <button
            type="button"
            id={"reject-btn-" <> @decision.id}
            phx-click="reject_decision"
            phx-value-decision-id={@decision.id}
            data-confirm="Reject this decision? The intent will be blocked."
            class="btn btn-error btn-soft btn-xs gap-1"
          >
            <.icon name="hero-x-mark" class="size-3" /> Reject
          </button>
        </div>
      </div>

      <div
        :if={@expanded}
        id={"approval-details-" <> @decision.id}
        class="mt-4 ml-11 rounded-lg bg-base-200/40 border border-base-300 p-4 text-xs space-y-3"
      >
        <.approval_intent_facts :if={@decision.intent} intent={@decision.intent} />
        <.approval_morpho_details
          :if={morpho_decision?(@decision)}
          decision={@decision}
        />
        <.approval_reasons reasons={@decision.reasons} />
        <.approval_policy_snapshot decision={@decision} />
      </div>
    </div>
    """
  end

  attr :intent, :map, required: true

  defp approval_intent_facts(assigns) do
    ~H"""
    <div>
      <h4 class="text-[0.65rem] uppercase tracking-wider text-base-content/50 mb-1">Intent</h4>
      <dl class="grid grid-cols-2 gap-x-4 gap-y-1">
        <div>
          <dt class="text-base-content/40">Agent</dt>
          <dd class="font-mono">{@intent.agent_id}</dd>
        </div>
        <div>
          <dt class="text-base-content/40">Kind</dt>
          <dd>{@intent.kind}</dd>
        </div>
        <div>
          <dt class="text-base-content/40">Amount</dt>
          <dd>{@intent.amount} {@intent.asset}</dd>
        </div>
        <div :if={Map.get(@intent, :target_raw_address)}>
          <dt class="text-base-content/40">Target</dt>
          <dd class="font-mono">{short_hash(@intent.target_raw_address)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  attr :reasons, :map, required: true

  defp approval_reasons(assigns) do
    items = reason_items(assigns.reasons)
    assigns = assign(assigns, :items, items)

    ~H"""
    <div :if={@items != []}>
      <h4 class="text-[0.65rem] uppercase tracking-wider text-base-content/50 mb-1">
        Why approval?
      </h4>
      <ul class="space-y-0.5">
        <li :for={r <- @items} class="flex items-start gap-1.5">
          <span class="font-mono text-base-content/40">{r["code"] || "reason"}:</span>
          <span class="text-base-content/70">{r["message"] || ""}</span>
        </li>
      </ul>
    </div>
    """
  end

  # #204 — Morpho deposit risk explanation panel. Renders the
  # subset of `morpho_risk_explanation` that lets an operator
  # decide approve/reject without reading raw JSON: vault
  # identity, decision/risk_tier, summary, and the primary
  # reasons/checks. Never renders raw provider payloads,
  # snapshot warnings array, market_allocations, or any
  # 0x-prefixed calldata-shaped strings.
  attr :decision, :map, required: true

  defp approval_morpho_details(assigns) do
    explanation = morpho_explanation(assigns.decision.reasons)

    assigns =
      assigns
      |> assign(:explanation, explanation)
      |> assign(:primary_reasons, primary_reasons(explanation))
      |> assign(:checks, morpho_checks(explanation))

    ~H"""
    <div
      :if={@explanation}
      id={"approval-morpho-details-" <> @decision.id}
      class="space-y-2 border-t border-base-300/60 pt-2"
    >
      <h4 class="text-[0.65rem] uppercase tracking-wider text-base-content/50">
        Morpho risk explanation
      </h4>
      <dl class="grid grid-cols-2 gap-x-4 gap-y-1">
        <div>
          <dt class="text-base-content/40">Decision</dt>
          <dd>{@explanation["decision"]}</dd>
        </div>
        <div>
          <dt class="text-base-content/40">Risk tier</dt>
          <dd>{@explanation["risk_tier"]}</dd>
        </div>
        <div :if={@explanation["vault_address"]} class="col-span-2">
          <dt class="text-base-content/40">Vault</dt>
          <dd class="font-mono break-all">
            <span :if={@explanation["vault_name"]}>{@explanation["vault_name"]}  &middot; </span>
            {@explanation["vault_address"]}
          </dd>
        </div>
        <div :if={@explanation["chain_id"]}>
          <dt class="text-base-content/40">Chain</dt>
          <dd class="font-mono">{@explanation["chain_id"]}</dd>
        </div>
        <div :if={@explanation["loan_asset"]}>
          <dt class="text-base-content/40">Loan asset</dt>
          <dd>{@explanation["loan_asset"]}</dd>
        </div>
      </dl>
      <p
        :if={@explanation["summary"]}
        id={"approval-morpho-summary-" <> @decision.id}
        class="text-base-content/70"
      >
        {@explanation["summary"]}
      </p>
      <ul
        :if={@primary_reasons != []}
        id={"approval-morpho-reasons-" <> @decision.id}
        class="space-y-0.5"
      >
        <li :for={r <- @primary_reasons} class="flex items-start gap-1.5">
          <span class={["badge badge-xs", morpho_severity_class(r["severity"])]}>
            {r["severity"]}
          </span>
          <span class="font-mono text-base-content/40">{r["code"]}:</span>
          <span class="text-base-content/70">{r["message"]}</span>
        </li>
      </ul>
      <ul
        :if={@checks != []}
        id={"approval-morpho-checks-" <> @decision.id}
        class="grid grid-cols-1 gap-0.5 text-[0.7rem] sm:grid-cols-2"
      >
        <li :for={c <- @checks} class="flex items-center gap-1.5">
          <.icon name={check_icon(c["status"])} class={["size-3", check_status_class(c["status"])]} />
          <span class="font-mono text-base-content/40">{c["code"]}</span>
          <span class="text-base-content/60">&middot; {c["label"]}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :decision, :map, required: true

  defp approval_policy_snapshot(assigns) do
    rule_count = rule_count(assigns.decision.policy_snapshot_ref)
    assigns = assign(assigns, :rule_count, rule_count)

    ~H"""
    <div>
      <h4 class="text-[0.65rem] uppercase tracking-wider text-base-content/50 mb-1">Context</h4>
      <dl class="grid grid-cols-2 gap-x-4 gap-y-1">
        <div>
          <dt class="text-base-content/40">Decided at</dt>
          <dd class="font-mono">{format_datetime(@decision.decided_at)}</dd>
        </div>
        <div>
          <dt class="text-base-content/40">Policy rules</dt>
          <dd class="font-mono">{@rule_count} referenced</dd>
        </div>
        <div class="col-span-2">
          <dt class="text-base-content/40">Intent replay</dt>
          <dd class="flex flex-wrap items-center gap-x-4 gap-y-1">
            <.link
              :if={@decision.intent_id}
              navigate={~p"/audit/replay/#{@decision.intent_id}"}
              class="link link-primary"
            >
              Open timeline
            </.link>
            <.link
              :if={@decision.intent_id}
              id={"decision-report-link-#{@decision.id}"}
              href={~p"/audit/replay/#{@decision.intent_id}/report"}
              target="_blank"
              rel="noopener"
              class="link"
            >
              Download report
            </.link>
          </dd>
        </div>
      </dl>
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
          <p class="text-sm font-medium truncate flex items-center gap-2 flex-wrap">
            <span>Execution: {execution_status_label(@plan.execution_status)}</span>
            <span
              :if={swap_plan?(@plan)}
              id={"execution-kind-badge-" <> @plan.id}
              class="badge badge-xs badge-accent"
            >
              swap
            </span>
          </p>
          <p class="text-xs text-base-content/40 font-mono truncate">
            {short_id(@plan.id)}
            {if @plan.intent, do: " &middot; #{intent_summary(@plan.intent)}", else: ""}
          </p>
          <p
            :if={swap_plan?(@plan) && swap_route_summary(@plan)}
            id={"execution-swap-summary-" <> @plan.id}
            class="text-xs text-base-content/50 mt-0.5"
          >
            {swap_route_summary(@plan)}
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
          <p class="text-sm font-medium truncate flex items-center gap-2 flex-wrap">
            <span>{outcome_label(@outcome)}</span>
            <span
              :if={@decision.intent && @decision.intent.kind == :swap}
              id={"decision-kind-badge-" <> @decision.id}
              class="badge badge-xs badge-accent"
            >
              swap
            </span>
            <span
              :if={@decision.intent && @decision.intent.kind == :defi_yield_deposit}
              id={"decision-morpho-badge-" <> @decision.id}
              class="badge badge-xs badge-accent"
            >
              morpho deposit
            </span>
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

  # #195 swap helpers — operate on the persisted #190 :steps shape.
  defp swap_plan?(%{steps: %{"kind" => "swap"}}), do: true
  defp swap_plan?(_), do: false

  # Compact one-liner for the active-execution row. Mentions the
  # source/destination asset pair and the route_provider when both
  # are present; otherwise nil so the row falls back to the generic
  # intent summary line above. Never renders raw addresses, calldata,
  # or any 0x hex blob.
  defp swap_route_summary(%{steps: %{"kind" => "swap"} = steps}) do
    src = steps["source_asset"]
    dst = steps["destination_asset"]
    provider = steps["route_provider"]

    cond do
      is_binary(src) and is_binary(dst) and is_binary(provider) ->
        "#{src} → #{dst} via #{provider}"

      is_binary(src) and is_binary(dst) ->
        "#{src} → #{dst}"

      true ->
        nil
    end
  end

  defp swap_route_summary(_), do: nil

  # #204 — Morpho-deposit decision discriminator. Hooked off the
  # parent intent's :defi_yield_deposit kind, which the
  # MorphoEvaluator is the only producer for in v0.1.
  defp morpho_decision?(%{intent: %{kind: :defi_yield_deposit}}), do: true
  defp morpho_decision?(_), do: false

  # Pull the embedded `morpho_risk_explanation` out of the decision's
  # reasons map. The MorphoEvaluator stamps it under
  # `reasons.items[0].details.morpho_risk_explanation` (see
  # `Bank.Decisions.MorphoEvaluator.build_envelope_attrs/7`); legacy /
  # mock decisions that don't carry the embed return nil so the
  # approval card silently skips the Morpho block.
  defp morpho_explanation(%{"items" => items}) when is_list(items) do
    Enum.find_value(items, fn item ->
      case item do
        %{"details" => %{"morpho_risk_explanation" => exp}} when is_map(exp) -> exp
        _ -> nil
      end
    end)
  end

  defp morpho_explanation(_), do: nil

  defp primary_reasons(%{"primary_reasons" => list}) when is_list(list), do: list
  defp primary_reasons(_), do: []

  defp morpho_checks(%{"checks" => list}) when is_list(list), do: list
  defp morpho_checks(_), do: []

  defp morpho_severity_class("block"), do: "badge-error"
  defp morpho_severity_class("hold"), do: "badge-warning"
  defp morpho_severity_class("approval"), do: "badge-info"
  defp morpho_severity_class("warn"), do: "badge-warning"
  defp morpho_severity_class("info"), do: "badge-ghost"
  defp morpho_severity_class(_), do: "badge-ghost"

  defp check_icon("pass"), do: "hero-check-circle"
  defp check_icon("warn"), do: "hero-exclamation-triangle"
  defp check_icon("fail"), do: "hero-x-circle"
  defp check_icon("missing"), do: "hero-question-mark-circle"
  defp check_icon(_), do: "hero-question-mark-circle"

  defp check_status_class("pass"), do: "text-success"
  defp check_status_class("warn"), do: "text-warning"
  defp check_status_class("fail"), do: "text-error"
  defp check_status_class("missing"), do: "text-base-content/40"
  defp check_status_class(_), do: "text-base-content/40"

  defp short_id(nil), do: "-"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "..."
  defp short_id(id), do: id

  defp short_hash(nil), do: "-"
  defp short_hash(hash) when byte_size(hash) > 14, do: String.slice(hash, 0, 10) <> "..."
  defp short_hash(hash), do: hash

  defp reason_items(%{"items" => items}) when is_list(items), do: items
  defp reason_items(_), do: []

  defp rule_count(%{"rule_ids" => ids}) when is_list(ids), do: length(ids)
  defp rule_count(_), do: 0

  defp approval_expiry_label(%DateTime{} = expires_at) do
    now = DateTime.utc_now()

    case DateTime.diff(expires_at, now, :second) do
      s when s <= 0 ->
        "Expired · #{format_datetime(expires_at)}"

      s when s < 3600 ->
        "Expires in #{div(s, 60)}m · #{format_datetime(expires_at)}"

      s when s < 86_400 ->
        "Expires in #{div(s, 3600)}h · #{format_datetime(expires_at)}"

      s ->
        "Expires in #{div(s, 86_400)}d · #{format_datetime(expires_at)}"
    end
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
