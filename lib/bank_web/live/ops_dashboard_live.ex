defmodule BankWeb.OpsDashboardLive do
  @moduledoc """
  Production operations dashboard (#254).

  Operator-facing read-only surface that consolidates the runtime
  health signals an on-call engineer needs to triage an incident:

    * Adapter / RPC / bundler health (cached snapshot from
      `Bank.Ops.AdapterHealthSnapshot`).
    * Quote provider health (per-provider state from
      `Bank.Stablecoins.ProviderHealth`).
    * Oban queue depth — non-terminal job counts per queue
      (sanitized via `Bank.Ops.Jobs.list_problem_jobs/1` and a
      lightweight `Oban.Job` count query for available + scheduled
      + executing).
    * Failed / retrying jobs — sanitized rows from
      `Bank.Ops.Jobs.list_problem_jobs/1`.
    * Stuck execution plans — workspace-scoped detail from
      `Bank.Ops.Health.stuck_plan_details/1`.
    * Recent callback failures — workspace-scoped audit slice on
      `adapter.callback.*` event types.
    * Recent incidents / pauses — workspace-scoped audit slice on
      `security.*paused`/`security.*resumed` event types plus the
      currently active scope pauses from `Bank.Security.Pauses`.

  ## Auth / role

  Mounted under `live_session :workspace_operator` with
  `on_mount: {BankWeb.LiveAuth, {:require_role, :operator}}` —
  the same gate `SecurityLive` uses. Viewer-tier users get the
  standard `LiveAuth` redirect; admin users have full read access
  here. Read-only surface — no `handle_event` mutates anything.

  ## Secret hygiene

  Every section renders only fixed-shape, code-controlled fields:

    * `Bank.Ops.Jobs.list_problem_jobs/1` returns a sanitized row
      shape that excludes `args` / `errors` / `meta` / `tags`.
    * Quote provider rows render only the provider id, fixed
      status enum, and integer counters; `last_failure_reason`
      is never rendered (it can carry a raw exception).
    * Stuck-plan rows render plan id, status atom, and elapsed
      seconds — no plan body / decision payload / tx_refs.
    * Callback / incident audit rows render only `event_type`,
      `actor`, `subject_id`, and `inserted_at`. The audit
      `before_ref` / `after_ref` JSON blobs are NOT rendered.

  No external HTTP / RPC call is made from this LiveView; every
  signal is a cached or DB read. The "no chain side effects"
  invariant therefore holds without further checks.
  """

  use BankWeb, :live_view

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Ops.AdapterHealthSnapshot
  alias Bank.Ops.Health
  alias Bank.Ops.Jobs
  alias Bank.Repo
  alias Bank.Security.Pauses
  alias Bank.Stablecoins.ProviderHealth
  alias Oban.Job

  # Audit event types we surface in the "recent callback failures"
  # section. Hard-allowlisted — anything outside this set is
  # ignored so an unrelated audit row cannot widen the surface.
  @callback_failure_event_types [
    "adapter.callback.error",
    "adapter.callback.invalid_signature",
    "adapter.callback.unauthorized",
    "adapter.callback.malformed"
  ]

  # Audit event types we surface in the "recent incidents /
  # pauses" section.
  @incident_event_types [
    "security.paused",
    "security.resumed",
    "security.scope_paused",
    "security.scope_resumed",
    "security.scope_expired",
    "agent_keys.paused",
    "agent_keys.resumed"
  ]

  @impl true
  def mount(_params, _session, socket) do
    workspace_id = current_workspace_id(socket)

    socket =
      socket
      |> assign(:page_title, "Operations")
      |> assign(:active_page, :ops)
      |> assign(:workspace_id, workspace_id)
      |> load_dashboard()

    {:ok, socket}
  end

  defp load_dashboard(socket) do
    workspace_id = socket.assigns.workspace_id

    socket
    |> assign(:adapter_health, AdapterHealthSnapshot.snapshot())
    |> assign(:queue_depth, queue_depth_summary())
    |> assign(:problem_jobs, Jobs.list_problem_jobs(limit: 25))
    |> assign(:problem_job_summary, Jobs.problem_job_summary(limit: 25))
    |> assign(:stuck_plans, Health.stuck_plan_details(limit: 25, workspace_id: workspace_id))
    |> assign(:provider_health, ProviderHealth.all())
    |> assign(:active_pauses, Pauses.list_active(workspace_id))
    |> assign(
      :callback_failures,
      recent_audit_events(workspace_id, @callback_failure_event_types)
    )
    |> assign(:recent_incidents, recent_audit_events(workspace_id, @incident_event_types))
    |> assign(:mainnet_enabled?, Bank.Workspaces.mainnet_enabled?(workspace_id))
  end

  defp current_workspace_id(socket) do
    case socket.assigns[:current_scope] do
      %{workspace: %{id: id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  # Lightweight per-queue depth summary (non-terminal states):
  # available + scheduled + executing + retryable. Sanitized at
  # the SQL level — only counts and queue names leave the DB.
  defp queue_depth_summary do
    rows =
      Repo.all(
        from(j in Job,
          where: j.state in ["available", "scheduled", "executing", "retryable"],
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id)}
        )
      )

    rows
    |> Enum.group_by(fn {queue, _state, _count} -> queue end)
    |> Enum.map(fn {queue, items} ->
      counts =
        Map.new(items, fn {_queue, state, count} -> {state, count} end)

      %{
        queue: queue,
        available: Map.get(counts, "available", 0),
        scheduled: Map.get(counts, "scheduled", 0),
        executing: Map.get(counts, "executing", 0),
        retryable: Map.get(counts, "retryable", 0),
        total:
          Map.get(counts, "available", 0) +
            Map.get(counts, "scheduled", 0) +
            Map.get(counts, "executing", 0) +
            Map.get(counts, "retryable", 0)
      }
    end)
    |> Enum.sort_by(& &1.queue)
  end

  defp recent_audit_events(nil, _types), do: []

  defp recent_audit_events(workspace_id, event_types)
       when is_binary(workspace_id) and is_list(event_types) do
    Repo.all(
      from(e in AuditEvent,
        where: e.workspace_id == ^workspace_id and e.event_type in ^event_types,
        order_by: [desc: e.ts, desc: e.id],
        limit: 15
      )
    )
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_dashboard(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:ops}>
      <div id="ops-dashboard" class="space-y-6">
        <header class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Operations</h1>
            <p class="text-sm text-base-content/60">
              Runtime health, queues, stuck executions, and recent incidents.
            </p>
          </div>
          <button
            id="ops-refresh"
            type="button"
            phx-click="refresh"
            class="btn btn-sm btn-ghost"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </button>
        </header>

        <section class="grid gap-4 md:grid-cols-3">
          <.adapter_card id="ops-health-adapter" health={@adapter_health} />
          <.adapter_card
            id="ops-health-rpc"
            health={@adapter_health}
            label="RPC / bundler"
            note="Reported via the chain adapter."
          />
          <.quote_provider_card id="ops-health-quotes" providers={@provider_health} />
        </section>

        <section
          id="ops-mainnet-eligibility"
          data-mainnet-enabled={to_string(@mainnet_enabled?)}
          class="rounded-lg border border-base-300 bg-base-100 p-4"
        >
          <h2 class="text-sm font-semibold mb-1">Base mainnet eligibility</h2>
          <p class="text-xs text-base-content/60 mb-2">
            Workspace-level gate (#178). When disabled, intents on a mainnet chain
            (<code>base</code>, <code>ethereum</code>) are rejected before any
            execution plan or adapter dispatch is created.
          </p>
          <p
            :if={@mainnet_enabled?}
            id="ops-mainnet-eligibility-status"
            class="badge badge-warning badge-sm font-mono"
          >
            Mainnet enabled
          </p>
          <p
            :if={not @mainnet_enabled?}
            id="ops-mainnet-eligibility-status"
            class="badge badge-success badge-sm font-mono"
          >
            Mainnet disabled
          </p>
        </section>

        <section class="grid gap-4 lg:grid-cols-2">
          <.queue_depth_card id="ops-queue-depth" rows={@queue_depth} />
          <.stuck_plans_card id="ops-stuck-plans" plans={@stuck_plans} />
        </section>

        <section class="grid gap-4 lg:grid-cols-2">
          <.problem_jobs_card
            id="ops-failed-jobs"
            title="Failed jobs"
            jobs={Enum.filter(@problem_jobs, &(&1.state == "discarded"))}
            empty="No discarded jobs."
          />
          <.problem_jobs_card
            id="ops-retrying-jobs"
            title="Retrying jobs"
            jobs={Enum.filter(@problem_jobs, &(&1.state == "retryable"))}
            empty="No retrying jobs."
          />
        </section>

        <section class="grid gap-4 lg:grid-cols-2">
          <.callback_failures_card id="ops-callback-failures" events={@callback_failures} />
          <.incidents_card
            id="ops-incidents"
            events={@recent_incidents}
            active_pauses={@active_pauses}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end

  # --- cards -----------------------------------------------------------

  attr :id, :string, required: true
  attr :health, :map, required: true
  attr :label, :string, default: "Chain adapter"
  attr :note, :string, default: nil

  defp adapter_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300 bg-base-100 p-4">
      <div class="flex items-center justify-between mb-2">
        <h2 class="text-sm font-semibold">{@label}</h2>
        <span
          class={["badge badge-sm", health_badge_class(@health.status)]}
          data-status={@health.status}
        >
          {@health.status}
        </span>
      </div>
      <dl class="text-xs text-base-content/70 space-y-1">
        <div class="flex justify-between">
          <dt>Detail</dt>
          <dd class="font-mono">{@health.detail}</dd>
        </div>
        <div :if={@health.checked_at} class="flex justify-between">
          <dt>Last check</dt>
          <dd>{Calendar.strftime(@health.checked_at, "%Y-%m-%d %H:%M:%S")}</dd>
        </div>
      </dl>
      <p :if={@note} class="mt-2 text-[0.65rem] text-base-content/50">{@note}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :providers, :list, required: true

  defp quote_provider_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300 bg-base-100 p-4">
      <h2 class="text-sm font-semibold mb-2">Quote providers</h2>
      <div :if={@providers == []} class="text-xs text-base-content/60">
        No quote provider observations yet.
      </div>
      <ul :if={@providers != []} class="space-y-2">
        <li
          :for={provider <- @providers}
          data-provider={provider.provider}
          data-status={provider.status}
          class="flex items-center justify-between text-xs"
        >
          <span class="font-mono">{provider.provider}</span>
          <span class={["badge badge-sm", provider_badge_class(provider.status)]}>
            {provider.status}
          </span>
          <span class="text-base-content/60">
            ok={provider.success_count} fail={provider.failure_count}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true

  defp queue_depth_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300 bg-base-100 p-4">
      <h2 class="text-sm font-semibold mb-2">Oban queue depth</h2>
      <div :if={@rows == []} class="text-xs text-base-content/60">
        All queues are idle.
      </div>
      <table :if={@rows != []} class="w-full text-xs">
        <thead class="text-base-content/60">
          <tr>
            <th class="text-left">Queue</th>
            <th class="text-right">avail</th>
            <th class="text-right">sched</th>
            <th class="text-right">exec</th>
            <th class="text-right">retry</th>
            <th class="text-right">total</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} data-queue={row.queue}>
            <td class="font-mono py-0.5">{row.queue}</td>
            <td class="text-right">{row.available}</td>
            <td class="text-right">{row.scheduled}</td>
            <td class="text-right">{row.executing}</td>
            <td class="text-right">{row.retryable}</td>
            <td class="text-right font-semibold">{row.total}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :plans, :list, required: true

  defp stuck_plans_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300 bg-base-100 p-4">
      <h2 class="text-sm font-semibold mb-2">Stuck execution plans</h2>
      <div :if={@plans == []} class="text-xs text-base-content/60">
        No plans past their per-status threshold.
      </div>
      <ul :if={@plans != []} class="space-y-1.5 text-xs">
        <li :for={plan <- @plans} data-plan-id={plan.id} class="flex justify-between gap-2">
          <span class="font-mono truncate">{plan.id}</span>
          <span class="badge badge-xs badge-warning" data-status={plan.execution_status}>
            {plan.execution_status}
          </span>
          <span class="text-base-content/60">
            stuck {plan.stuck_for_seconds}s (>{plan.threshold_seconds}s)
          </span>
          <.link navigate={"/queue?plan=#{plan.id}"} class="text-primary hover:underline">
            queue
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :jobs, :list, required: true
  attr :empty, :string, required: true

  defp problem_jobs_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300 bg-base-100 p-4">
      <h2 class="text-sm font-semibold mb-2">{@title}</h2>
      <div :if={@jobs == []} class="text-xs text-base-content/60">{@empty}</div>
      <ul :if={@jobs != []} class="space-y-1.5 text-xs">
        <li :for={job <- @jobs} data-job-id={job.id} class="flex flex-wrap justify-between gap-2">
          <span class="font-mono truncate">{job.worker}</span>
          <span class="badge badge-xs" data-state={job.state}>{job.state}</span>
          <span class="text-base-content/60">
            queue={job.queue} attempt={job.attempt}/{job.max_attempts}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :events, :list, required: true

  defp callback_failures_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300 bg-base-100 p-4">
      <h2 class="text-sm font-semibold mb-2">Recent callback failures</h2>
      <div :if={@events == []} class="text-xs text-base-content/60">
        No callback failures recorded.
      </div>
      <ul :if={@events != []} class="space-y-1 text-xs">
        <li
          :for={event <- @events}
          data-event-id={event.id}
          data-event-type={event.event_type}
          class="flex justify-between"
        >
          <span class="font-mono">{event.event_type}</span>
          <span class="text-base-content/60">
            actor={event.actor} subject={truncate_id(event.subject_id)}
          </span>
          <time>{Calendar.strftime(event.ts, "%H:%M:%S")}</time>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :events, :list, required: true
  attr :active_pauses, :list, required: true

  defp incidents_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300 bg-base-100 p-4">
      <h2 class="text-sm font-semibold mb-2">Recent incidents / pauses</h2>
      <div :if={@active_pauses != []} class="mb-2 text-xs">
        <p class="text-warning font-semibold mb-1">Active pauses</p>
        <ul class="space-y-0.5 text-base-content/70">
          <li :for={pause <- @active_pauses} data-pause-id={pause.id} class="font-mono truncate">
            {pause.scope_type}:{safe_scope_value(pause.scope_value)}
          </li>
        </ul>
      </div>
      <div :if={@events == []} class="text-xs text-base-content/60">
        No recent incidents.
      </div>
      <ul :if={@events != []} class="space-y-1 text-xs">
        <li
          :for={event <- @events}
          data-event-id={event.id}
          data-event-type={event.event_type}
          class="flex justify-between"
        >
          <span class="font-mono">{event.event_type}</span>
          <.link navigate="/security" class="text-primary hover:underline">
            security
          </.link>
          <time>{Calendar.strftime(event.ts, "%Y-%m-%d %H:%M")}</time>
        </li>
      </ul>
    </div>
    """
  end

  # --- formatting helpers -------------------------------------------

  defp health_badge_class(:ok), do: "badge-success"
  defp health_badge_class(:degraded), do: "badge-error"
  defp health_badge_class(:unknown), do: "badge-ghost"
  defp health_badge_class(_), do: "badge-ghost"

  defp provider_badge_class(:healthy), do: "badge-success"
  defp provider_badge_class(:degraded), do: "badge-warning"
  defp provider_badge_class(:failing), do: "badge-error"
  defp provider_badge_class(:unknown), do: "badge-ghost"
  defp provider_badge_class(_), do: "badge-ghost"

  defp truncate_id(nil), do: "—"

  defp truncate_id(id) when is_binary(id) do
    if String.length(id) > 12, do: String.slice(id, 0, 8) <> "…", else: id
  end

  defp truncate_id(other), do: to_string(other)

  # `Bank.Security.Pauses.create_pause/4` only validates
  # `scope_value` as non-empty / <=64 chars at the changeset level
  # (#254 P2). A secret-looking value the operator typed by mistake
  # — `Bearer sk_live_…`, `https://u:p@rpc.test`, a PEM marker —
  # would otherwise leak through this LiveView.
  #
  # Phase 1's `:chain` scope only ever expects a kebab-case chain
  # id (`base-sepolia`, `base`, `ethereum-sepolia`, …). We therefore
  # render the value verbatim only when it matches that strict
  # shape: lowercase alphanumerics + dashes, no slashes / colons /
  # `@` / whitespace. Anything outside the shape collapses to a
  # fixed `"[redacted]"` label so a token / URL / header value
  # cannot reach the rendered HTML.
  @safe_scope_value_re ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  defp safe_scope_value(value) when is_binary(value) do
    cond do
      String.length(value) == 0 -> "[redacted]"
      String.length(value) > 32 -> "[redacted]"
      Regex.match?(@safe_scope_value_re, value) -> value
      true -> "[redacted]"
    end
  end

  defp safe_scope_value(_), do: "[redacted]"
end
