# Production observability — operator triage runbook

This runbook is the **fast-path triage card** for an on-call operator
when something on the runtime starts behaving badly. It maps each
scope item from issue #257 to (a) the health surface that detects
it, (b) the dashboard panel that visualises it, and (c) the deeper
procedure in [`docs/incident-runbook.md`](../incident-runbook.md)
that actually fixes it.

> **Audience.** On-call operators answering "is anything obviously
> broken?". For deep recovery procedures (bulk-abort, callback secret
> rotation, chain refusal cascades, emergency pause) follow the
> linked sections in `incident-runbook.md`.
>
> **Sibling docs.**
> - [`docs/monitoring.md`](../monitoring.md) — endpoints, telemetry
>   metrics, alert thresholds, dashboard plans.
> - [`docs/incident-runbook.md`](../incident-runbook.md) — full
>   recovery playbooks per failure mode.
>
> This document **summarises and routes**; it does not duplicate the
> recovery steps in those docs.

## 30-second triage

When a pager fires, walk this list top-to-bottom and stop at the
first match:

| Step | Probe | Pass | Fail → see |
| --- | --- | --- | --- |
| 1 | `curl /health` (load-balancer probe) | 200 = the web process is up | "Phoenix down" — restart / check deploy |
| 2 | `curl /v1/health` | 200 = Postgres reachable | DB triage (below) |
| 3 | `curl /v1/health/deep` | 200 + `status: "ok"` = every dependency healthy | the per-dependency triage cards below — the JSON body's `checks.*.detail` names the failing dependency |
| 4 | Open `/ops` in the operator console | All cards green = no actionable signal in app state | the dashboard card that's red |

The per-check `detail` field on `/v1/health/deep` is drawn from a
**fixed allowlist** (`http_5xx`, `transport_error`,
`adapter_base_url_not_configured`, `database_unreachable`, …) — it
will never carry an exception message, an RPC URL, or a host header
that could leak in a paging UI.

## Health endpoints

| Endpoint | Auth | What it probes | Failure mode |
| --- | --- | --- | --- |
| `GET /health` | none | Web process liveness — no DB, no adapter | 5xx ⇒ Phoenix down |
| `GET /v1/health` | none | Postgres `SELECT 1` (1s timeout) | 503 + `database: "error"` ⇒ DB down |
| `GET /v1/health/deep` | none | `Bank.Ops.Health.snapshot/0`: DB + adapter `/healthz` (2s timeout) + stuck-plan count | 503 + `status: "degraded"` ⇒ at least one check ≠ `ok` |

Top-level `status` collapses the per-check statuses with these rules
(see `Bank.Ops.Health.snapshot/0` moduledoc):

- `ok` — every check is `ok` **or** `not_configured`. A
  `not_configured` adapter (e.g. local/dev that has not wired up a
  chain adapter) is **not** treated as degraded.
- `degraded` — at least one check is `degraded`, `down`, or
  `unknown`. **`unknown` is never treated as `ok`** — an
  unknown-status dependency cannot be reported healthy.

### Deep health response shape

```json
{
  "status": "degraded",
  "service": "bank",
  "version": "0.1.0",
  "checks": {
    "database":    { "status": "ok",       "detail": null },
    "adapter":     { "status": "degraded", "detail": "http_5xx" },
    "stuck_plans": { "status": "ok",       "count": 0, "threshold_minutes": 15 }
  }
}
```

Point a load balancer at `/health`; point a synthetic monitor at
`/v1/health/deep` (run every 30 s — the adapter ping budget is 2 s
so don't probe per-second).

## Ops dashboard (`/ops`)

The operator console renders an at-a-glance dashboard at `/ops`
backed by [`BankWeb.OpsDashboardLive`](../../lib/bank_web/live/ops_dashboard_live.ex).

- **Auth.** Workspace membership at role `:operator` or above.
  Browser-session only (no API key surface).
- **Refresh.** Manual via the **Refresh** button. The page does
  **not** auto-poll the chain adapter — adapter health is read from
  the `Bank.Ops.AdapterHealthSnapshot` ETS cache so a slow adapter
  cannot stall the dashboard.

### Dashboard sections

| Section | What it shows | Source | Triage card |
| --- | --- | --- | --- |
| Adapter health | Cached adapter `/healthz` status, last probe time | `Bank.Ops.AdapterHealthSnapshot` | Adapter / RPC / bundler triage |
| Quote providers | Per-provider freshness, last-success timestamp, mode | `Bank.Quotes.ProviderHealth` | Quote provider degraded mode |
| Queue depth | Oban backlog by queue + retrying jobs | `Bank.Ops.Jobs` | Queue failure triage |
| Stuck plans | Execution plans non-terminal past threshold | `Bank.Ops.Health.stuck_plan_details/1` | Stuck execution recovery |
| Failed jobs | Discarded / cancelled Oban jobs (sanitized) | `Bank.Ops.Jobs.list_problem_jobs/1` | Queue failure triage |
| Callback failures | Recent `adapter.callback.*` audit events | `Bank.Audit` | Callback failure triage |
| Recent incidents | Recent `security.*` pause/resume audit events | `Bank.Audit` | `incident-runbook.md` § Emergency pause |

Every card renders only **fixed-shape fields** (id, status,
timestamps, kind) — never raw `args`, `errors`, `meta`, `tags`,
`before_ref`, or `after_ref`. So a stack trace or RPC URL cannot
leak through the dashboard.

## Triage cards

Each card is **what to look at first**. The deep recovery procedure
lives in `incident-runbook.md` — the link in each card is the
authoritative source.

### Adapter / RPC / bundler triage

**Detect.**
- `/v1/health/deep` → `adapter.status = degraded` (`http_5xx`) or
  `down` (`transport_error`).
- Telemetry: `bank.ops.health.adapter_up = 0` for ≥ 5 min.
- `/ops` → "Adapter health" card red.
- Notification: `ops.adapter_down` (or `:rpc_down` / `:bundler_down`)
  in the operator inbox, deduped per workspace.

**First checks.**
1. Adapter logs / process — is the adapter reachable from the
   Phoenix host at all? Transport-error vs 5xx tells you which.
2. `bank.adapter.dispatch.*` telemetry — is the adapter accepting
   dispatch requests but rejecting them, or is it timing out?
3. Bundler reachability separately (a 5xx to the adapter can come
   from a bundler outage one hop downstream).

**Recovery.** [`incident-runbook.md` § Adapter outage](../incident-runbook.md#adapter-outage).

### Quote provider degraded mode

**Detect.**
- `/ops` → "Quote providers" card red or yellow per provider.
- Telemetry: `bank.quotes.preview.count{result="error"}` rate up.
- Notification: `ops.quote_provider_down` per provider, deduped per
  workspace.

**Behaviour.** A degraded quote provider does **not** stop the
runtime — preview/quote requests fall through to the next
allowlisted provider. Decisions that would otherwise need a fresh
preview are conservatively held (`:hold` decision outcome with
`reason: "no_fresh_quote_available"`); they are **not** auto-blocked.

**First checks.**
1. Provider's status page (Tenderly / 0x / etc.) for a known
   incident — quote degradation is usually upstream.
2. Recent `bank.quotes.preview.count{result="error"}` per
   `provider` tag to see whether the failure is provider-specific
   or fan-wide.
3. The local fallback chain — degraded does not mean the runtime
   stopped; held decisions surface in `/queue` for an operator to
   approve manually if the provider stays out.

**Recovery.** When the provider recovers, the next preview tick
auto-clears the `ops.quote_provider_down.resolved` notification.
Held decisions remain held until an operator approves them or the
relevant intent expires; held intents are **not** retroactively
auto-executed when the provider returns.

### Queue failure triage

**Detect.**
- `/ops` → "Failed jobs" / "Retrying jobs" cards have non-zero
  counts; "Queue depth" card high.
- Telemetry: `oban.job.stop.duration` p95 > 30 s for any queue.
- Notification: `ops.queue_depth_high` or `ops.job_failures_high`,
  deduped per workspace.

**First checks.**
1. The "Failed jobs" card shows sanitized job rows — `id`, `worker`,
   `attempt`, `state`, `discarded_at`. The `args` and `errors`
   fields are **deliberately not rendered** (they can carry
   payload bodies). For full args/errors, query `oban_jobs` from
   IEx with the operator's read-only credentials.
2. Worker tag — most regressions cluster around one worker module
   (`Bank.Runtime.Workers.RunExecution`,
   `Bank.Runtime.Workers.ConfirmExecution`, etc.).
3. `bank.ops.health.database_up` and queue depth at the same time
   — backlog with green DB usually means a downstream (adapter,
   RPC, callback) is the real bottleneck.

**Recovery.** [`incident-runbook.md` § Stuck executions](../incident-runbook.md#stuck-executions)
covers the most common cause (callbacks broken). Other queue
backlogs are diagnosed by the failing worker's moduledoc — every
worker module documents its retry budget and idempotency story.

### Callback failure triage

**Detect.**
- `/ops` → "Callback failures" card has recent rows.
- Telemetry: 401/4xx rate on `/internal/adapter/callback` > 1 / min.
- Notification: `ops.callback_latency_high` (latency, not rejection
  — auth rejections do not have a dedicated alert kind in the Phase
  1 allowlist; they surface as audit-event activity instead).

**First checks.**
1. Callback shape — was the request rejected at auth (`401`,
   `adapter.callback.unauthorized` audit events) or at validation
   (`422`, `adapter.callback.invalid_payload`)?
2. Shared-secret rotation — a sudden burst of 401s right after a
   deploy almost always means the `ADAPTER_CALLBACK_SECRET` env
   diverged between Phoenix and the adapter.
3. Latency vs rejection — high latency without rejections is
   usually queue-bound, not auth-bound.

**Recovery.** [`incident-runbook.md` § Callback auth mismatch](../incident-runbook.md#callback-auth-mismatch).

### Stuck execution recovery

**Detect.**
- `/v1/health/deep` → `stuck_plans.status = degraded`,
  `stuck_plans.count > 0`.
- Telemetry: `bank.ops.health.stuck_plans > 0` for ≥ 5 min.
- `/ops` → "Stuck plans" card has rows.
- Notification: `ops.stuck_plan` per plan, with a 5-min dedup
  window so a single stuck plan generates one alert per 5 min, not
  one per scan tick.

**First checks.**
1. Per-status threshold — `Bank.Ops.Health` uses different stuck
   thresholds per `execution_status` (`:prepared` 600 s,
   `:signing` 300 s, `:broadcasting` 600 s,
   `:pending_confirmation` 1800 s). A plan listed in the stuck
   card is past its specific threshold, not a global timer.
2. Audit trail for the plan's `correlation_id` — was a
   `adapter.dispatch.*` event written? Was a callback received?
3. `tx_refs` — if the plan has a tx ref but is still
   `:pending_confirmation`, the callback path failed even though
   the chain may have confirmed.

**Recovery.** [`incident-runbook.md` § Missing confirmation](../incident-runbook.md#missing-confirmation)
covers the most common case (callback path lost). For plans with
no `tx_refs` after threshold, the abort path in
[`incident-runbook.md` § Stuck executions](../incident-runbook.md#stuck-executions)
applies.

### Database triage

**Detect.**
- `/v1/health` → 503 with `database: "error"`.
- `/v1/health/deep` → `database.status = down`,
  `detail = database_unreachable`.
- Telemetry: `bank.ops.health.database_up = 0`.

**First checks.**
1. Postgres process / network — the readiness probe runs `SELECT
   1` with a 1 s timeout, so any 503 here means the pool cannot
   reach the DB within a second.
2. Pool exhaustion vs DB-down — `bank.repo.query.queue_time`
   surfaces the difference. A long queue-time with the DB up
   means the pool is too small or a slow query is monopolising
   it.
3. Migration / DDL window — if the 503 coincides with a deploy,
   the migration may be holding a lock.

**Recovery.** Short-term: scale Phoenix down to one instance to
relieve pool pressure. Medium-term: investigate slow queries via
`pg_stat_activity`. There is no single recovery card in
`incident-runbook.md` because the resolution depends on the
specific Postgres failure mode; treat the DB as outside the
runtime's recovery domain.

## Operational alerts (`Bank.Ops.Alerts`)

The runtime emits **typed operational alerts** through
[`Bank.Ops.Alerts`](../../lib/bank/ops/alerts.ex). Each alert
becomes a workspace-scoped row in `Bank.Notifications`, **deduped**
on `(workspace_id, dedupe_key)`. Repeated `emit/1` for the same
`(kind, subject)` collapses to one row until a paired `resolve/1`
fires.

### Phase 1 allowlist (#256)

Only these eight kinds are allowed today:

```
stuck_plan, adapter_down, rpc_down, bundler_down,
quote_provider_down, callback_latency_high,
queue_depth_high, job_failures_high
```

An unknown kind returns `{:error, :unknown_kind}` rather than
silently widening the surface. New kinds need an explicit
allowlist update.

### Read-only / no chain side effects

Alert emission **never** calls the chain adapter, signs anything,
broadcasts, or enqueues a dispatch worker. It only inserts inbox
rows. So an alert flood cannot accidentally trigger on-chain
behaviour.

### Workspace boundary

Every alert is scoped to a single `workspace_id`. Sibling
workspaces cannot observe each other's alerts. Callers that detect
a global ops signal (e.g. adapter down affects every tenant) are
responsible for fanning the emit out per workspace — there is no
shared "global" alert surface.

### Secret hygiene

The `Bank.Notifications.Notification` changeset rejects
secret-shaped strings (Authorization headers, Bearer tokens,
`sk_live_` / `sk_test_` markers, PEM blocks, tokenized
`https://user:pass@host` URLs) at the `:unsafe_text` gate. A
caller that accidentally pastes a secret into `:summary` or
`:details` surfaces as `{:error, %Ecto.Changeset{}}`, never as a
leaked notification row.

## Local / dev vs staging / mainnet

| Concern | Local / dev | Staging / mainnet |
| --- | --- | --- |
| Adapter `base_url` | Often unset — `/v1/health/deep` reports `adapter.status = not_configured` and the overall status stays `ok` | Required — an unset adapter would be treated as `not_configured` even on prod, which is **wrong**; staging health checks rely on the adapter being explicitly configured |
| Telemetry poller | Disabled in `:test` (so no background HTTP), enabled at 10 s in `:dev` and `:prod` | 10 s poller |
| LiveDashboard | Wired at `/dev/dashboard` | **Not exposed publicly** — add a Prometheus reporter (`TelemetryMetricsPrometheus`) when a Prom server exists. See `monitoring.md` |
| Alert delivery | Inbox rows only — no Slack / paging webhook is wired in CI | A Slack channel (`#bank-alerts`) and an Alertmanager → Slack webhook are the alpha targets. Paging integration (PagerDuty / OpsGenie) is deferred until a formal on-call rotation exists. See `monitoring.md` |
| Stuck-plan thresholds | Same defaults as staging (`:prepared` 600 s, `:signing` 300 s, `:broadcasting` 600 s, `:pending_confirmation` 1800 s); tunable per-env via `config :bank, Bank.Ops.Health, stuck_plan_thresholds: [...]` | Same defaults; tune up if a bundler legitimately takes longer |
| Chain broadcast | Never in CI | Real chain. Pause/revoke gates apply |
| Mainnet eligibility (#178) | `mainnet_enabled` defaults `false` on every fresh workspace; the seeded `sandbox-demo` workspace and the `register_and_log_in_user` test fixture flip it to `true` for ergonomics | Defaults `false` in production. An admin must explicitly call `Bank.Workspaces.set_mainnet_enabled/2` to opt a workspace into Base mainnet (chain `"base"`). Testnet (`"base-sepolia"`) is unaffected by the flag |

## Base mainnet feature gate (#178)

The runtime ships an explicit, fail-closed gate against accidental
Base mainnet operation. The gate is anchored on a single workspace
boolean — `Bank.Workspaces.Workspace.mainnet_enabled` — and
consulted from every chain-touching boundary in the request /
worker pipeline.

### Classification

`Bank.Chains` is the single source of truth for which chain
strings are mainnet-class:

- `mainnet_chains/0` → `["base", "ethereum"]`
- `testnet_chains/0` → `["base-sepolia", "sepolia", "goerli"]`
- `classify/1` returns `:mainnet | :testnet | :unknown`
- `mainnet_allowed_for?(chain, workspace_id)` is the canonical
  predicate every gate calls; testnet and unknown chains pass
  through, mainnet chains require `mainnet_enabled: true`.

### Where the gate fires

The gate is layered defensively. Any single layer is sufficient to
fail closed; together they ensure no mainnet broadcast can leak
through a code path that bypasses the others.

| Layer | Boundary | Failure shape |
| --- | --- | --- |
| `Bank.Intents.submit/2` | Intent submission (controller calls in) | `{:error, :mainnet_disabled}` — controller renders 422 with code `mainnet_disabled` (no DB row written) |
| `Bank.Decisions.create_execution_plan/3` | Decision pipeline (auto / manual execute) | `{:error, :mainnet_disabled}` propagated by `request_manual_execution/3` and `dispatch_auto_exec/3`; held-reason atom surfaces as `dispatch held (mainnet_disabled)` in the queue (no execution plan row written) |
| `Bank.Runtime.Workers.RunExecution` | Dispatch worker — defense in depth before adapter call | `{:cancel, :mainnet_disabled}` — plan moves to `:aborted` with `final_reason: "mainnet_disabled"`; adapter is never called |
| `Bank.Security.revoke_delegation/2` | Synchronous revoke entrypoint | `{:error, :mainnet_disabled}` returned to controller; renders 422 with code `mainnet_disabled` |
| `Bank.Runtime.Workers.RevokeDelegation` | Revoke worker — defense in depth | `{:cancel, :mainnet_disabled}` — adapter is never called; the projection write that already landed in `Security.revoke_delegation/2` stands |
| `BankWeb.API.V1.ConnectController.request/2` | Browser smart-account connect (`chain_id == 8453`) | 422 with code `mainnet_disabled`; no audit row, no grant worker enqueued |
| `BankWeb.API.V1.DecisionController.execute/2` | Manual execute endpoint | 422 with code `mainnet_disabled` |

A `nil` workspace_id is treated as a legacy unscoped path and
passes through every gate — mirrors the precedent set by
`Bank.Decisions.validate_not_paused/2`. Every production
chain-touching boundary carries a workspace_id, so this fallback
exists only for transitional and admin-bootstrap callers.

### Operator visibility

The `/ops` operator dashboard renders a per-workspace mainnet
eligibility badge (`#ops-mainnet-eligibility`) with a
`data-mainnet-enabled="true|false"` attribute. The badge is
green when the flag is **disabled** (the safe default) and amber
when it has been flipped on, so a paged operator can confirm
the gate posture in one glance. A workspace operator with
membership at role `:operator`+ can read the status; flipping
the flag is admin-only and goes through
`Bank.Workspaces.set_mainnet_enabled/2`.

### Held-reason vocabulary

`:mainnet_disabled` joins the existing decision-pipeline held
reasons (`:no_executable_account`, `:ambiguous_executable_account`,
`:runtime_paused`, `:active_plan_exists`, `:delegation_not_active`,
`:stablecoin_adapter_not_wired`, `:chain_paused`). Operator UI
surfaces it generically via the queue page's
`Approval recorded; dispatch held (mainnet_disabled)` flash and the
controllers' explicit `mainnet_disabled` error code.

### What the gate does NOT do

- It does **not** restrict chain identifiers beyond Base mainnet
  vs Base Sepolia. A future "Ethereum mainnet" addition needs to
  appear in `Bank.Chains.mainnet_chains/0` and may also need
  product-level review.
- It does **not** enforce the on-chain `chain_id`
  (8453 vs 84532) — that's the adapter's responsibility, gated
  separately in `Bank.Delegations.Provisioning`.
- It does **not** retroactively re-evaluate already-broadcast
  plans. A plan that successfully dispatched on a workspace with
  `mainnet_enabled: true` continues to live-cycle through
  callbacks even if the flag is later flipped off.

## Local smoke

The Mix smoke task is the **dependency-free** verification path:
it runs the full health-snapshot pipeline against the local
database with the adapter stubbed via `Req.Test`, so a fresh
reviewer can confirm the observability surface compiles and
behaves correctly without any live chain dependency.

```sh
mix bank.observability.smoke
# → prints one PASS line per check, exits non-zero on failure.
#   Includes a deliberately-stubbed degraded-adapter case so the
#   degraded path is exercised on every run.
```

What it verifies (see the task's `@moduledoc` for the
authoritative list):

- `Bank.Ops.Health.database/0` returns `:ok` against the local
  Repo;
- `Bank.Ops.Health.adapter/0` cleanly classifies a stubbed 5xx as
  `:degraded` and a stubbed transport error as `:down`;
- `Bank.Ops.Health.stuck_plans/1` returns a well-formed shape;
- `Bank.Ops.Health.snapshot/0` collapses per-check statuses
  correctly (degraded adapter ⇒ overall degraded);
- the `/v1/health` and `/v1/health/deep` HTTP routes round-trip
  through `BankWeb.Endpoint` and return well-formed JSON;
- `Bank.Ops.Alerts.emit/1` accepts a synthetic alert, dedupes on
  repeat, and rejects an unknown kind;
- the smoke output and the rendered health JSON are free of
  secret-shaped markers (Authorization, `sk_live_` / `sk_test_`,
  PEM, tokenized URLs).

It does **not** call `Bank.AdapterClient` over real HTTP, does
**not** read `.env`, does **not** broadcast, and does **not** sign
anything.

## Caveats

- This document is **runtime triage**, not a SOC dashboard. It
  describes the surface the codebase ships, not a Prometheus or
  Grafana wiring (those need a chosen provider — see
  `monitoring.md`).
- Phase 1 alert kinds are a hard allowlist (#256); new alert
  signals need a code change, not a doc-only addition.
- The `/ops` dashboard renders **per-workspace** state. There is
  no global cross-workspace ops view today; an operator with
  membership in multiple workspaces switches workspaces to see
  another tenant's signals.

## Related

- [`docs/monitoring.md`](../monitoring.md)
- [`docs/incident-runbook.md`](../incident-runbook.md)
- `Bank.Ops.Health` / `Bank.Ops.AdapterHealthSnapshot` /
  `Bank.Ops.Alerts` / `Bank.Ops.Jobs` moduledocs
- `BankWeb.OpsDashboardLive` moduledoc
- `BankWeb.HealthController` moduledoc
