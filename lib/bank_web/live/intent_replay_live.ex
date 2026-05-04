defmodule BankWeb.IntentReplayLive do
  @moduledoc """
  Per-intent replay — the deterministic bundle that explains how an
  intent was decided and (if relevant) executed.

  The bundle is read straight from `Bank.Audit.replay/1`, which assembles
  child rows in domain-timestamp order. No business logic is re-run;
  the page is a pure projection of persisted history.

  ## Layout

  Six stacked sections, in operator-reading order:

    1. **Intent summary** — the original submission
    2. **Audit timeline** — the full event sequence (correlation slice)
    3. **Trust assessment history** — every claim, oldest first
    4. **Simulation history** — every simulation report, oldest first
    5. **Decision history** — every decision envelope, oldest first
    6. **Execution plan history** — every plan attached to a decision
    7. **Policy snapshot** — the union of rule uuids captured across
       every decision, resolved to full rule rows

  Empty bundles render a "nothing to show yet" stub so an in-flight
  intent with no decision yet still loads gracefully instead of
  crashing.
  """

  use BankWeb, :live_view

  alias Bank.{Audit, Intents}
  alias Bank.Decisions.Report

  @impl true
  def mount(%{"intent_id" => intent_id}, _session, socket) do
    workspace_id = socket.assigns.current_scope.workspace.id

    # Workspace-scope guard. Without this, any viewer+ in any
    # workspace could navigate to `/audit/replay/<intent_id>` and
    # render a sibling workspace's full intent bundle (intent,
    # decisions, plans, audit, screening evidence) — `Audit.replay/1`
    # itself does an unscoped `Repo.get(AgentIntent, intent_id)`. The
    # API counterpart at `IntentController.replay/2` already gates
    # via `Intents.get_in_workspace/2`; mirror that here so cross-
    # workspace ids resolve to `:not_found` instead of leaking.
    with {:ok, uuid} <- Ecto.UUID.cast(intent_id),
         %_{} <- Intents.get_in_workspace(uuid, workspace_id),
         {:ok, bundle} <- Audit.replay(uuid) do
      if connected?(socket) do
        Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())
        Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.intent(uuid))
      end

      socket =
        socket
        |> assign(page_title: "Replay")
        |> assign(:intent_id, uuid)
        |> assign(:bundle, bundle)
        |> assign(:report, Report.from_bundle(bundle))

      {:ok, socket}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Intent #{short_id(intent_id)} not found")
         |> push_navigate(to: ~p"/audit")}
    end
  end

  # --- Events ---------------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket) do
    case Audit.replay(socket.assigns.intent_id) do
      {:ok, bundle} ->
        {:noreply,
         socket
         |> assign(:bundle, bundle)
         |> assign(:report, Report.from_bundle(bundle))
         |> put_flash(:info, "Replay refreshed")}

      {:error, :not_found} ->
        {:noreply, push_navigate(socket, to: ~p"/audit")}
    end
  end

  # --- PubSub handlers ------------------------------------------------------

  @impl true
  def handle_info(%{topic: topic}, socket) when topic in [:audit_stream, :intent_lifecycle] do
    case Audit.replay(socket.assigns.intent_id) do
      {:ok, bundle} ->
        {:noreply,
         socket
         |> assign(:bundle, bundle)
         |> assign(:report, Report.from_bundle(bundle))}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:audit}>
      <%!-- Page header --%>
      <div class="flex items-center justify-between mb-6">
        <div class="min-w-0">
          <div class="flex items-center gap-2 text-xs text-base-content/50 mb-1">
            <.link navigate={~p"/audit"} class="link link-hover">Audit</.link>
            <.icon name="hero-chevron-right-micro" class="size-3" />
            <span>Replay</span>
          </div>
          <h1 id="page-title" class="text-2xl font-bold tracking-tight">
            Intent replay
          </h1>
          <p class="mt-1 text-sm text-base-content/60 font-mono break-all">
            {@intent_id}
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <%!-- Sections in operator-reading order --%>
      <div class="space-y-6">
        <.intent_card intent={@bundle.intent} />
        <.decision_report_card intent_id={@intent_id} report={@report} />
        <.audit_timeline_card events={@bundle.audit} />
        <.stablecoin_route_card routes={@bundle[:stablecoin_route_evidence] || []} />
        <.trust_history_card trust_assessments={@bundle.trust_assessments} />
        <.simulation_history_card simulations={@bundle.simulations} />
        <.decision_history_card decisions={@bundle.decisions} />
        <.plan_history_card plans={@bundle.plans} />
        <.policy_snapshot_card rules={@bundle.policy_snapshot} />
      </div>
    </Layouts.app>
    """
  end

  # --- Section: intent summary ---------------------------------------------

  attr :intent, :map, required: true

  defp intent_card(assigns) do
    ~H"""
    <section
      id="replay-intent"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-document-text" class="size-4" /> Intent
        </h2>
        <span class={["badge badge-sm", intent_state_badge_class(@intent.state)]}>
          {@intent.state}
        </span>
      </header>
      <div class="px-6 py-5 grid grid-cols-2 sm:grid-cols-3 gap-4">
        <.detail_item label="Kind" value={to_string(@intent.kind)} />
        <.detail_item label="Asset" value={@intent.asset} />
        <.detail_item label="Chain" value={@intent.chain} />
        <.detail_item label="Amount" value={Decimal.to_string(@intent.amount)} />
        <.detail_item label="Source" value={to_string(@intent.source)} />
        <.detail_item label="Agent" value={@intent.agent_id} mono />
        <.detail_item
          :if={@intent.target_counterparty_id}
          label="Counterparty id"
          value={short_id(@intent.target_counterparty_id)}
          mono
        />
        <.detail_item
          :if={@intent.target_address_label_id}
          label="Address label id"
          value={short_id(@intent.target_address_label_id)}
          mono
        />
        <.detail_item
          :if={@intent.target_raw_address}
          label="Raw address"
          value={short_hash(@intent.target_raw_address)}
          mono
        />
        <.detail_item label="Submitted" value={format_datetime(@intent.submitted_at)} />
        <.detail_item label="Idempotency key" value={@intent.idempotency_key} mono />
      </div>
    </section>
    """
  end

  # --- Section: decision report (#251) -------------------------------------
  #
  # Renders the deterministic Report.flags_section/2 (mainnet/testnet
  # + live/stub) plus a download link to the existing #250 endpoint
  # `GET /v1/intents/:id/report`. Read-only: no mutating events on
  # the surface, no chain calls. The download link reuses the
  # API-side workspace gate, so cross-workspace ids resolve to 404.

  attr :intent_id, :string, required: true
  attr :report, :map, required: true

  defp decision_report_card(assigns) do
    ~H"""
    <section
      id="decision-report-panel"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-document-arrow-down" class="size-4" /> Decision report
        </h2>
        <.link
          id="decision-report-download"
          href={~p"/v1/intents/#{@intent_id}/report"}
          target="_blank"
          rel="noopener"
          class="btn btn-sm btn-primary gap-1.5"
        >
          <.icon name="hero-arrow-down-tray" class="size-3.5" /> Download Markdown
        </.link>
      </header>
      <div class="px-6 py-5 space-y-3">
        <div id="decision-report-flags" class="flex flex-wrap items-center gap-2 text-xs">
          <span class="text-base-content/40">Chain</span>
          <span
            id="decision-report-chain"
            class="badge badge-sm badge-ghost font-mono"
            data-chain={@report.flags.chain || ""}
          >
            {@report.flags.chain || "—"}
          </span>

          <span
            id="decision-report-network"
            class={[
              "badge badge-sm",
              cond do
                @report.flags.mainnet? -> "badge-error"
                @report.flags.testnet? -> "badge-warning"
                true -> "badge-ghost"
              end
            ]}
            data-network={
              cond do
                @report.flags.mainnet? -> "mainnet"
                @report.flags.testnet? -> "testnet"
                true -> "unknown"
              end
            }
          >
            {cond do
              @report.flags.mainnet? -> "Mainnet"
              @report.flags.testnet? -> "Testnet"
              true -> "Network: unknown"
            end}
          </span>

          <span
            id="decision-report-broadcast"
            class={["badge badge-sm", if(@report.flags.live?, do: "badge-error", else: "badge-info")]}
            data-broadcast={if @report.flags.live?, do: "live", else: "stub"}
          >
            {if @report.flags.live?, do: "Live broadcast", else: "Stub / no broadcast"}
          </span>
        </div>

        <p class="text-xs text-base-content/60">
          The report is a deterministic Markdown projection of the
          replay bundle (no secrets, no signing material). Same
          intent → same body, byte-stable. Workspace-scoped: a
          sibling workspace's intent id resolves to 404.
        </p>
      </div>
    </section>
    """
  end

  # --- Section: audit timeline ---------------------------------------------

  attr :events, :list, required: true

  defp audit_timeline_card(assigns) do
    ~H"""
    <section
      id="replay-audit"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-clock" class="size-4" /> Audit timeline
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@events)}</span>
      </header>
      <div :if={@events == []} class="px-6 py-6 text-sm text-base-content/50 text-center">
        No audit events yet.
      </div>
      <ol :if={@events != []} class="divide-y divide-base-300">
        <li :for={{event, idx} <- Enum.with_index(@events, 1)} class="px-6 py-3">
          <div class="flex items-start gap-3">
            <span class="text-[0.65rem] text-base-content/30 font-mono pt-0.5 shrink-0 w-6 text-right">
              {idx}
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2 flex-wrap">
                <span class={["badge badge-sm font-mono", event_type_badge_class(event.event_type)]}>
                  {event.event_type}
                </span>
                <span class="badge badge-sm badge-ghost gap-1">
                  <.icon name={actor_icon(event.actor)} class="size-3" />
                  {event.actor}
                </span>
              </div>
              <div class="mt-1 text-xs text-base-content/50 font-mono">
                {event.subject_type} &middot; {short_id(event.subject_id)}
              </div>
            </div>
            <span class="text-xs text-base-content/40 font-mono shrink-0">
              {format_datetime(event.ts)}
            </span>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  # --- Section: stablecoin route evidence ----------------------------------

  attr :routes, :list, required: true

  defp stablecoin_route_card(assigns) do
    ~H"""
    <section
      id="replay-stablecoin-routes"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-arrows-right-left" class="size-4" /> Stablecoin routes
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@routes)}</span>
      </header>
      <div :if={@routes == []} class="px-6 py-6 text-sm text-base-content/50 text-center">
        No stablecoin route evaluations captured.
      </div>
      <ol :if={@routes != []} class="divide-y divide-base-300">
        <li :for={{route, idx} <- Enum.with_index(@routes, 1)} class="px-6 py-4">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <span class="text-[0.65rem] text-base-content/30 font-mono">v{idx}</span>
                <span class={[
                  "badge badge-sm",
                  stablecoin_decision_class(route_value(route, "decision"))
                ]}>
                  {route_value(route, "decision")}
                </span>
                <span class="badge badge-sm badge-outline">
                  {route_value(route, "route_kind")}
                </span>
                <span class="badge badge-sm badge-ghost">
                  provider: {route_value(route, "provider")}
                </span>
              </div>
              <div class="mt-1 text-xs text-base-content/50 flex items-center gap-3 flex-wrap">
                <span>policy: {route_value(route, "policy_decision")}</span>
                <span>state: {route_value(route, "execution_state")}</span>
                <span>score: {route_value(route, "score")}</span>
                <span :if={route_value(route, "input_amount")}>
                  in: {route_value(route, "input_amount")}
                </span>
                <span :if={route_value(route, "output_amount")}>
                  out: {route_value(route, "output_amount")}
                </span>
              </div>
              <div :if={route_value(route, "reason")} class="mt-1 text-xs text-base-content/50 italic">
                {route_value(route, "reason")}
              </div>
            </div>
            <span class="text-xs text-base-content/40 font-mono shrink-0">
              {route_value(route, "evaluated_at")}
            </span>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  # --- Section: trust history ----------------------------------------------

  attr :trust_assessments, :list, required: true

  defp trust_history_card(assigns) do
    ~H"""
    <section
      id="replay-trust"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-shield-check" class="size-4" /> Trust assessments
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@trust_assessments)}</span>
      </header>
      <div
        :if={@trust_assessments == []}
        class="px-6 py-6 text-sm text-base-content/50 text-center"
      >
        No trust assessments produced yet.
      </div>
      <ol :if={@trust_assessments != []} class="divide-y divide-base-300">
        <li :for={{claim, idx} <- Enum.with_index(@trust_assessments, 1)} class="px-6 py-4">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <span class="text-[0.65rem] text-base-content/30 font-mono">v{idx}</span>
                <span class={["badge badge-sm", trust_level_class(claim.derived_trust)]}>
                  {claim.derived_trust}
                </span>
                <span class="badge badge-sm badge-outline">
                  confidence: {claim.confidence}
                </span>
                <span :if={claim.current} class="badge badge-sm badge-success">current</span>
              </div>
              <div class="mt-1 text-xs text-base-content/50">
                {length(claim.supporting_assertion_ids)} assertion(s), {length(
                  claim.supporting_evidence_ids
                )} evidence,
                generated by {claim.generated_by}
              </div>
            </div>
            <span class="text-xs text-base-content/40 font-mono shrink-0">
              {format_datetime(claim.generated_at)}
            </span>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  # --- Section: simulation history -----------------------------------------

  attr :simulations, :list, required: true

  defp simulation_history_card(assigns) do
    ~H"""
    <section
      id="replay-simulations"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-beaker" class="size-4" /> Simulations
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@simulations)}</span>
      </header>
      <div :if={@simulations == []} class="px-6 py-6 text-sm text-base-content/50 text-center">
        No simulation reports.
      </div>
      <ol :if={@simulations != []} class="divide-y divide-base-300">
        <li :for={{sim, idx} <- Enum.with_index(@simulations, 1)} class="px-6 py-4">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <span class="text-[0.65rem] text-base-content/30 font-mono">v{idx}</span>
                <span class={["badge badge-sm", simulation_status_class(sim.status)]}>
                  {sim.status}
                </span>
                <span class="badge badge-sm badge-outline">{sim.provider}</span>
                <span :if={sim.current} class="badge badge-sm badge-success">current</span>
              </div>
              <div class="mt-1 text-xs text-base-content/50 flex items-center gap-3 flex-wrap">
                <span :if={sim.estimated_gas}>gas: {sim.estimated_gas}</span>
                <span :if={sim.expected_output}>
                  expected: {Decimal.to_string(sim.expected_output)}
                </span>
                <span :if={sim.slippage_exposure}>
                  slippage: {Decimal.to_string(sim.slippage_exposure)}
                </span>
                <span class="font-mono text-base-content/40">
                  ttl: {sim.freshness_ttl_seconds}s
                </span>
              </div>
            </div>
            <span class="text-xs text-base-content/40 font-mono shrink-0">
              {format_datetime(sim.generated_at)}
            </span>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  # --- Section: decision history -------------------------------------------

  attr :decisions, :list, required: true

  defp decision_history_card(assigns) do
    ~H"""
    <section
      id="replay-decisions"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-scale" class="size-4" /> Decisions
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@decisions)}</span>
      </header>
      <div :if={@decisions == []} class="px-6 py-6 text-sm text-base-content/50 text-center">
        No decision envelopes written yet.
      </div>
      <ol :if={@decisions != []} class="divide-y divide-base-300">
        <li :for={{decision, idx} <- Enum.with_index(@decisions, 1)} class="px-6 py-4">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <span class="text-[0.65rem] text-base-content/30 font-mono">v{idx}</span>
                <span class={["badge badge-sm", outcome_badge_class(decision.outcome)]}>
                  {decision.outcome}
                </span>
                <span class="badge badge-sm badge-outline">
                  risk: {decision.risk_tier}
                </span>
                <span :if={decision.current} class="badge badge-sm badge-success">current</span>
              </div>
              <div class="mt-1 text-xs text-base-content/50">
                state: {decision.state} &middot; decided by {decision.decided_by}
                <span :if={decision.approval_expires_at}>
                  &middot; approval expires {format_datetime(decision.approval_expires_at)}
                </span>
              </div>
              <ul
                :if={decision_reasons(decision) != []}
                class="mt-2 text-xs text-base-content/60 list-disc list-inside space-y-0.5"
              >
                <li :for={reason <- decision_reasons(decision)}>{reason}</li>
              </ul>
            </div>
            <span class="text-xs text-base-content/40 font-mono shrink-0">
              {format_datetime(decision.decided_at)}
            </span>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  # --- Section: execution plans --------------------------------------------

  attr :plans, :list, required: true

  defp plan_history_card(assigns) do
    ~H"""
    <section
      id="replay-plans"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-bolt" class="size-4" /> Execution plans
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@plans)}</span>
      </header>
      <div :if={@plans == []} class="px-6 py-6 text-sm text-base-content/50 text-center">
        No execution plans.
      </div>
      <ol :if={@plans != []} class="divide-y divide-base-300">
        <li :for={{plan, idx} <- Enum.with_index(@plans, 1)} class="px-6 py-4">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <span class="text-[0.65rem] text-base-content/30 font-mono">v{idx}</span>
                <span class={["badge badge-sm", execution_status_class(plan.execution_status)]}>
                  {plan.execution_status}
                </span>
                <span
                  :if={plan.final_outcome}
                  class={["badge badge-sm", final_outcome_class(plan.final_outcome)]}
                >
                  final: {plan.final_outcome}
                </span>
                <span :if={plan.active} class="badge badge-sm badge-success">active</span>
              </div>
              <div class="mt-1 text-xs text-base-content/50">
                {plan.chain} &middot; {plan.asset}
                <span :if={plan.smart_account_id}>
                  &middot; sa: {short_id(plan.smart_account_id)}
                </span>
                <span :if={plan.adapter_ref}>
                  &middot; adapter: {short_id(plan.adapter_ref)}
                </span>
              </div>
              <div
                :if={plan.tx_refs != []}
                class="mt-1.5 flex items-center gap-2 flex-wrap text-xs text-base-content/60"
              >
                <span class="text-base-content/40">tx:</span>
                <span :for={ref <- plan.tx_refs} class="font-mono">{short_hash(ref)}</span>
              </div>
              <div :if={plan.final_reason} class="mt-1 text-xs text-base-content/50 italic">
                {plan.final_reason}
              </div>
            </div>
            <span class="text-xs text-base-content/40 font-mono shrink-0">
              {format_datetime(plan.inserted_at)}
            </span>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  # --- Section: policy snapshot --------------------------------------------

  attr :rules, :list, required: true

  defp policy_snapshot_card(assigns) do
    ~H"""
    <section
      id="replay-policy"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-document-check" class="size-4" /> Policy snapshot
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@rules)}</span>
      </header>
      <div :if={@rules == []} class="px-6 py-6 text-sm text-base-content/50 text-center">
        No policy rules captured (intent never reached the decision stage).
      </div>
      <ol :if={@rules != []} class="divide-y divide-base-300">
        <li :for={rule <- @rules} class="px-6 py-3">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0 flex items-center gap-2 flex-wrap">
              <span class="badge badge-sm badge-outline font-mono">
                {rule.rule_type}
              </span>
              <span class="text-[0.65rem] text-base-content/40 font-mono">
                v{rule.version}
              </span>
              <span class={["badge badge-sm", policy_state_class(rule.state)]}>
                {rule.state}
              </span>
              <span class="text-xs text-base-content/50 font-mono">
                {short_id(rule.id)}
              </span>
            </div>
            <span class="text-xs text-base-content/40">priority: {rule.priority}</span>
          </div>
        </li>
      </ol>
    </section>
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
      <dd class={["text-sm break-all", @mono && "font-mono text-base-content/80"]}>
        {@value}
      </dd>
    </div>
    """
  end

  # --- Helpers --------------------------------------------------------------

  defp decision_reasons(%{reasons: %{"items" => items}}) when is_list(items) do
    Enum.map(items, fn
      %{"text" => text} -> text
      %{"reason" => text} -> text
      text when is_binary(text) -> text
      other -> inspect(other)
    end)
  end

  defp decision_reasons(_), do: []

  defp intent_state_badge_class(:submitted), do: "badge-ghost"
  defp intent_state_badge_class(:evaluating), do: "badge-info"
  defp intent_state_badge_class(:decided), do: "badge-primary"
  defp intent_state_badge_class(:executing), do: "badge-warning"
  defp intent_state_badge_class(:executed), do: "badge-success"
  defp intent_state_badge_class(:blocked), do: "badge-error"
  defp intent_state_badge_class(:cancelled), do: "badge-ghost"
  defp intent_state_badge_class(:expired), do: "badge-ghost"
  defp intent_state_badge_class(_), do: "badge-ghost"

  defp trust_level_class(:trusted), do: "badge-success"
  defp trust_level_class(:sensitive), do: "badge-warning"
  defp trust_level_class(:unknown), do: "badge-ghost"
  defp trust_level_class(:conflicted), do: "badge-error"
  defp trust_level_class(_), do: "badge-ghost"

  defp simulation_status_class(:completed), do: "badge-success"
  defp simulation_status_class(:pending), do: "badge-info"
  defp simulation_status_class(:failed), do: "badge-error"
  defp simulation_status_class(:stale), do: "badge-warning"
  defp simulation_status_class(_), do: "badge-ghost"

  defp outcome_badge_class(:auto_exec), do: "badge-success"
  defp outcome_badge_class(:hold), do: "badge-warning"
  defp outcome_badge_class(:approval_required), do: "badge-info"
  defp outcome_badge_class(:block), do: "badge-error"
  defp outcome_badge_class(_), do: "badge-ghost"

  defp execution_status_class(:prepared), do: "badge-ghost"
  defp execution_status_class(:signing), do: "badge-warning"
  defp execution_status_class(:broadcasting), do: "badge-info"
  defp execution_status_class(:pending_confirmation), do: "badge-info"
  defp execution_status_class(:confirmed), do: "badge-success"
  defp execution_status_class(:reverted), do: "badge-error"
  defp execution_status_class(:aborted), do: "badge-error"
  defp execution_status_class(_), do: "badge-ghost"

  defp final_outcome_class(:confirmed), do: "badge-success"
  defp final_outcome_class(:reverted), do: "badge-error"
  defp final_outcome_class(:aborted), do: "badge-error"
  defp final_outcome_class(_), do: "badge-ghost"

  defp stablecoin_decision_class("auto_exec"), do: "badge-success"
  defp stablecoin_decision_class("approval_required"), do: "badge-info"
  defp stablecoin_decision_class("block"), do: "badge-error"
  defp stablecoin_decision_class(_), do: "badge-ghost"

  defp policy_state_class(:active), do: "badge-success"
  defp policy_state_class(:draft), do: "badge-warning"
  defp policy_state_class(:superseded), do: "badge-ghost"
  defp policy_state_class(:archived), do: "badge-ghost"
  defp policy_state_class(_), do: "badge-ghost"

  defp event_type_badge_class("intent." <> _), do: "badge-info"
  defp event_type_badge_class("decision." <> _), do: "badge-primary"
  defp event_type_badge_class("trust." <> _), do: "badge-secondary"
  defp event_type_badge_class("simulation." <> _), do: "badge-accent"
  defp event_type_badge_class("approval." <> _), do: "badge-warning"
  defp event_type_badge_class("execution." <> _), do: "badge-success"
  defp event_type_badge_class("security." <> _), do: "badge-error"
  defp event_type_badge_class("delegation." <> _), do: "badge-error"
  defp event_type_badge_class(_), do: "badge-ghost"

  defp actor_icon(:user), do: "hero-user"
  defp actor_icon(:agent), do: "hero-cpu-chip"
  defp actor_icon(:runtime), do: "hero-cog-6-tooth"
  defp actor_icon(:adapter), do: "hero-link"
  defp actor_icon(_), do: "hero-question-mark-circle"

  defp route_value(route, key) do
    value = route[key] || route[route_atom_key(key)]

    case value do
      nil -> nil
      atom when is_atom(atom) -> Atom.to_string(atom)
      other -> other
    end
  end

  defp route_atom_key("decision"), do: :decision
  defp route_atom_key("route_kind"), do: :route_kind
  defp route_atom_key("provider"), do: :provider
  defp route_atom_key("policy_decision"), do: :policy_decision
  defp route_atom_key("execution_state"), do: :execution_state
  defp route_atom_key("score"), do: :score
  defp route_atom_key("input_amount"), do: :input_amount
  defp route_atom_key("output_amount"), do: :output_amount
  defp route_atom_key("reason"), do: :reason
  defp route_atom_key("evaluated_at"), do: :evaluated_at
  defp route_atom_key(_), do: :unknown

  defp short_id(nil), do: "-"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "..."
  defp short_id(id), do: id

  defp short_hash(nil), do: "-"
  defp short_hash(hash) when byte_size(hash) > 14, do: String.slice(hash, 0, 10) <> "..."
  defp short_hash(hash), do: hash

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_datetime(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
end
