# Production observability runbook (#257)

Operator playbook for diagnosing the runtime when something feels
off: queues, jobs, adapter / RPC / bundler health, quote providers,
callback failures, stuck executions, and recent incidents.

This runbook ties together the surfaces shipped under epic
[#217](https://github.com/Linh86/cryptobank/issues/217):

| Surface | What it answers | Where it lives |
|---|---|---|
| `GET /health` | Is Phoenix alive? | `BankWeb.HealthController.liveness` |
| `GET /v1/health` | Is Phoenix + DB ready? | `BankWeb.HealthController.readiness` |
| `GET /v1/health/deep` | Are adapter, queues, stuck plans, callback failures OK? | `BankWeb.HealthController.deep` |
| `/ops` | Live operator dashboard for all of the above | `BankWeb.OpsDashboardLive` |
| `/security` | Pause/resume + delegation safety controls | `BankWeb.SecurityLive` |
| Notifications inbox | Operational alerts and recoveries | `Bank.Notifications` |

---

## Environment matrix

The same status enums surface across local/dev, staging, and
mainnet — the **operational meaning** changes with the environment.

| Status (any health surface) | local / dev | staging / testnet | mainnet |
|---|---|---|---|
| `:ok` | green | green | green |
| `:degraded` | upstream may be flaky; usually benign | investigate within the hour | **P1**: page on-call |
| `:down` | rare; usually means probe error | within-hour | **P1** |
| `:not_configured` | adapter base_url is unset → benign default | misconfiguration; fix env | misconfiguration; fix env |
| `:unknown` | snapshot not yet warmed | snapshot stale → check probe | snapshot stale → check probe |

**Rules of thumb**

- `:not_configured` is **only acceptable in local/dev**. Staging
  and mainnet must show `:ok` or be paged.
- `:degraded` from a cached snapshot may lag the real recovery by
  the snapshot TTL (see `Bank.Ops.AdapterHealthSnapshot`). If
  `/v1/health/deep` reports `:degraded` but `/security` shows the
  runtime as Running and recent intents are confirming, the
  snapshot is stale — refresh it from `/ops` (Refresh button) or
  wait for the next probe.
- `:unknown` after a fresh boot is normal for the first
  `AdapterHealthSnapshot` tick. If it persists past two minutes,
  the probe job is stuck — check `/ops > Failed jobs` for
  `Bank.Ops.AdapterHealthSnapshot` retries.

---

## Surfaces at a glance

### Health endpoints

- `GET /health` → 200 unconditionally as long as Phoenix is
  serving. No DB touch. Suitable for k8s liveness.
- `GET /v1/health` → 200 only if DB is reachable. Suitable for
  k8s readiness.
- `GET /v1/health/deep` → JSON snapshot with the same fields the
  Ops dashboard renders. Each section carries a `status` enum
  and a sanitized `detail` string. Operators can curl this from a
  bastion to triage without opening the LiveView.

The `detail` field NEVER contains:

- raw RPC URLs (tokenized or otherwise)
- `Authorization` headers, `Bearer` tokens, `sk_live_…`
- PEM private-key blocks
- raw exception structs (only sanitized status enums)

If you ever see one of those in `/v1/health/deep` output, treat
it as a P0 secret-hygiene incident and file an issue against
`Bank.Ops.Health`.

### Ops dashboard (`/ops`)

Operator+ tier (same `LiveAuth.{:require_role, :operator}` gate as
`/security`). Sections, each with a stable DOM id:

| id | Source | Notes |
|---|---|---|
| `#ops-health-adapter` | `Bank.Ops.AdapterHealthSnapshot.snapshot/0` | cached |
| `#ops-health-rpc` | same snapshot, labelled "RPC / bundler" | reuses adapter probe in Phase 1 |
| `#ops-health-quotes` | `Bank.Stablecoins.ProviderHealth.all/0` | per-provider counters |
| `#ops-queue-depth` | Oban job count grouped by queue/state | |
| `#ops-failed-jobs` | `Bank.Ops.Jobs.list_problem_jobs/1` (`discarded`) | |
| `#ops-retrying-jobs` | same (`retryable`) | |
| `#ops-stuck-plans` | `Bank.Ops.Health.stuck_plan_details/1` | links to `/queue?plan=…` |
| `#ops-callback-failures` | audit slice on `adapter.callback.*` | |
| `#ops-incidents` | audit slice on `security.*paused/resumed` + active pauses | links to `/security` |

Refresh button reloads every section in place. Read-only — no
mutations. Active pause `scope_value` is rendered only when it
matches the kebab-case chain-id shape; anything else collapses to
`[redacted]` (see `BankWeb.OpsDashboardLive.safe_scope_value/1`).

---

## Triage by symptom

### Queue depth high

1. Open `/ops` → `#ops-queue-depth`. Identify the queue.
2. If `executing` is high but `available` is low, work is in
   flight — check whether a downstream provider is slow
   (`#ops-health-quotes`, `#ops-health-adapter`).
3. If `retryable` is high, open `#ops-retrying-jobs` and look at
   `worker` + `attempt`. `Bank.Ops.Jobs.list_problem_jobs/1`
   strips `args` / `errors` / `meta` — to debug a specific job
   safely, attach to a console and load it via `Oban.Repo.get!`
   (operator-only environment).
4. If `available` is climbing past expected (e.g. > 1k), check
   that the worker is actually running. `iex -S mix phx.server`
   then `Oban.config(:bank).queues` shows configured concurrency.

### Failed / retrying jobs

- Discarded = past `max_attempts`. Operator must intervene
  (manual retry, fix upstream, or accept the failure).
- Retryable = will run again automatically. No action unless the
  same job has been retrying for hours — that usually means the
  upstream dependency hasn't recovered.

The on-call should NEVER paste raw `errors` from `oban_jobs`
into Slack / a ticket — they can carry tokenized URLs. Use the
sanitized rows from `/ops > Failed jobs` as the public record;
debug the raw row only inside an authorized console.

### Adapter / RPC / bundler down

- `Bank.Ops.AdapterHealthSnapshot.snapshot/0` is the cached truth.
  The cache refreshes every minute; the snapshot's `checked_at`
  field tells you how stale the data is.
- A `:degraded` adapter does NOT pause the runtime. Pausing
  is an explicit operator action (`/security > Pause runtime`).
- The runtime **DOES** refuse to dispatch when the adapter
  responds non-2xx — `Bank.AdapterClient` returns
  `{:error, :rpc_error_5xx | :timeout | …}` and `RunExecution`
  retries via Oban. You'll see the retries on
  `/ops > Retrying jobs`.
- If the adapter is hard down for > 5 minutes, page the chain-
  adapter on-call and consider pausing the chain scope at
  `/security > Pause chain scope` so new dispatches don't pile
  up against an unresponsive backend.

### Quote provider down / stale

- `Bank.Stablecoins.ProviderHealth.all/0` is per-provider state
  derived from `RouteSelector` outcomes. `:degraded` means
  ≥ 1 failure but success rate ≥ 80% (still usable).
  `:failing` means success rate < 80% — route selection will
  prefer healthier providers if any are available.
- `last_failure_reason` is **not** rendered in `/ops` — it can
  carry raw exception text. Inspect it via console only.
- When ALL providers are `:failing` or `:unknown`, no quotes
  will land. Operators should pause the affected scope and wait
  for at least one provider to recover. Provider state is
  node-local and volatile (ETS) — a deploy resets the counters
  to `:unknown`.

### Callback latency / failures

- `/ops > #ops-callback-failures` lists the recent
  `adapter.callback.*` audit events for the workspace. Each row
  shows `event_type`, `actor`, truncated `subject_id`, and `ts`.
  The audit `before_ref` / `after_ref` JSON is NOT rendered here.
- For deeper triage, query `Bank.Audit.list_events/2` from a
  console scoped to the workspace_id — the after_ref is the
  sanitized envelope (no raw provider headers).
- If callback latency is consistently high, the adapter may be
  retrying webhook deliveries; check the adapter's own logs.

### Stuck execution recovery

- `Bank.Runtime.Workers.ScanStuckPlans` runs every 2 minutes and
  emits an `ops.stuck_plan_detected` audit row PLUS an
  `ops.stuck_plan` notification (operator inbox + `/ops`) for any
  plan past its per-status threshold.
- A previously-alerted plan that is no longer past its threshold
  triggers an `ops.stuck_plan.resolved` notification on the next
  scan tick. Recovery is decided by an uncapped, subject-targeted
  DB re-check (`Bank.Ops.Health.plans_currently_stuck/2`) — NOT
  by membership in the capped scan batch — so a still-stuck plan
  outside the top-50 window is never falsely resolved.
- To unstick a plan manually: open the plan from
  `/ops > #ops-stuck-plans → queue` link, abort it (`/queue`
  admin action) or fix the upstream condition. The next scan
  tick will resolve the alert automatically.

### Recent incidents / pauses

- `/ops > #ops-incidents` lists the workspace's recent
  pause/resume audit events plus currently active scope pauses.
- Each event row links back to `/security` for full context.
- Active pauses render as `chain:<value>` only when `<value>` is
  a kebab-case chain id; anything else renders as
  `chain:[redacted]` to defend against an operator typo
  containing a token or URL.

---

## Operational alerts (`Bank.Ops.Alerts`)

Production detectors emit alerts via `Bank.Ops.Alerts.emit/1` /
`resolve/1`. Phase 1 hard-allowlist of kinds:

```
:stuck_plan
:adapter_down
:rpc_down
:bundler_down
:quote_provider_down
:callback_latency_high
:queue_depth_high
:job_failures_high
```

Each emit is deduped per `(workspace_id, dedupe_key)`. A
subsequent `resolve/1` records a paired `ops.<kind>.resolved`
notification with `:info` severity. Today only `:stuck_plan` has
an automatic detector + recovery wiring (`ScanStuckPlans`); the
remaining kinds are emitted ad-hoc and will get dedicated
detectors in follow-up issues within #217.

The downstream `Bank.Notifications.Notification` `:unsafe_text`
gate refuses to persist any alert title / body that contains a
secret marker (`Authorization`, `Bearer`, `sk_live_`, PEM
markers, tokenized URLs). A regression there surfaces as
`{:error, %Ecto.Changeset{}}` instead of a leak.

---

## Smoke command

`mix bank.observability.smoke` exercises the read-side surfaces
without touching the chain or any external dependency. It
verifies:

1. `Bank.Ops.Health.snapshot/0` returns the expected shape.
2. `Bank.Ops.Health.adapter/0` returns one of the allowed
   statuses.
3. `Bank.Ops.AdapterHealthSnapshot.snapshot/0` returns a
   sanitized snapshot.
4. `Bank.Ops.Jobs.list_problem_jobs/1` returns sanitized rows
   (no `args` / `errors` / `meta` / `tags`).
5. `Bank.Ops.Health.stuck_plan_details/1` and
   `Bank.Ops.Health.plans_currently_stuck/2` are callable.
6. `Bank.Ops.Alerts.kinds/0` matches the documented allowlist.
7. `Bank.Stablecoins.ProviderHealth.all/0` is callable.
8. **Degraded-dependency simulation**: emit an `:adapter_down`
   alert for a temporary workspace, assert the second emit is
   `:deduped`, then `resolve/1` and assert the
   `ops.adapter_down.resolved` notification lands. This proves
   the alert + recovery pipeline works end-to-end without any
   real chain dependency.
9. Secret-hygiene scan over every check's printed `detail` —
   no `Bearer`, `sk_live_`, tokenized URL, or PEM marker may
   appear in any output line.

The task requires only `app.start`. It does NOT call the chain
adapter, signing path, RPC, or bundler. It does NOT read `.env`.

```
mix bank.observability.smoke
# → prints PASS/FAIL per check, exits non-zero on failure.
mix bank.observability.smoke --quiet
# → suppress per-check PASS lines.
```

The smoke task is idempotent — it inserts only a temporary
workspace + paired notifications and explicitly deletes them on
the way out via a `try/after` block so a partial failure still
removes whatever the alert-pipeline check inserted.

See also:

- `docs/runbooks/decision-reports.md`
- `docs/runbooks/guided-sandbox.md`
- `docs/incident-runbook.md`
- `docs/smoke-tests.md`
