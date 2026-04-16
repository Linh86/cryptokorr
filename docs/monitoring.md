# Monitoring, alerts, and health checks

Operational observability for the Bank control plane during staging
and alpha. The goal is that an on-call operator can answer *"is
anything obviously broken?"* in under a minute without attaching to a
remote IEx shell.

## Health endpoints

| Endpoint           | Auth | Purpose                                                                       |
| ------------------ | ---- | ----------------------------------------------------------------------------- |
| `GET /health`      | none | Liveness. Returns 200 as long as the Phoenix endpoint is up. No DB touch.     |
| `GET /v1/health`   | none | Readiness. Verifies Postgres. Returns 503 if the DB is unreachable.           |
| `GET /v1/health/deep` | none | Full operational snapshot: DB + adapter reachability + stuck-plan count. Returns 503 if any check is degraded. |

Point the cloud load balancer at `/health` (cheap, no deps). Point
your pager's synthetic monitor at `/v1/health/deep` (catches more, at
the cost of a DB query + an adapter ping per probe — run every 30s,
not every second).

### Deep health response

```json
{
  "status": "degraded",
  "service": "bank",
  "version": "0.1.0",
  "checks": {
    "database":    { "status": "ok",    "detail": null },
    "adapter":     { "status": "error", "detail": "%Req.TransportError{reason: :econnrefused}" },
    "stuck_plans": { "status": "ok",    "count": 0, "threshold_minutes": 15 }
  }
}
```

Top-level `status` is `ok` iff every check is `ok`.

## Telemetry + metrics

Metric definitions live in
[`BankWeb.Telemetry`](../lib/bank_web/telemetry.ex). The poller emits
periodic health measurements every 10 seconds via
[`Bank.Ops.Health.emit_telemetry/0`](../lib/bank/ops/health.ex).

| Metric                          | Type         | Tags                               | What it tells you                                |
| ------------------------------- | ------------ | ---------------------------------- | ------------------------------------------------ |
| `bank.autonomy.decision.count`  | counter      | `outcome`, `risk_tier`, `reason_code` | Decisions per tier — detect policy drift         |
| `bank.quotes.preview.count`     | counter      | `provider`, `result`               | Quote provider health                            |
| `bank.execution.lifecycle.count`| counter      | `status`                           | Plans entering each lifecycle state              |
| `bank.security.event.count`     | counter      | `event`, `scope`                   | Pause/resume/revoke volume                       |
| `bank.ops.health.stuck_plans`   | last_value   | —                                  | Plans non-terminal past 15 min                   |
| `bank.ops.health.adapter_up`    | last_value   | —                                  | 1 if adapter is reachable, 0 otherwise           |
| `bank.ops.health.database_up`   | last_value   | —                                  | 1 if Postgres is reachable, 0 otherwise          |
| `oban.job.stop.duration`        | summary      | `queue`, `state`                   | Job execution time and retry rate                |
| `bank.repo.query.*`             | summary      | —                                  | DB query timing + queue wait                     |

### Exposing metrics

Phoenix LiveDashboard is wired at `/dev/dashboard` in dev. In staging
and prod the dashboard is not exposed publicly — add a Prometheus
reporter when a Prom server exists:

```elixir
# lib/bank_web/telemetry.ex (not yet live — drop in once Prom exists)
children = [
  {TelemetryMetricsPrometheus, metrics: metrics()}
]
```

`TelemetryMetricsPrometheus` exposes `GET /metrics`; scrape at 15s.

## What to alert on

These are the signals worth paging an operator for. Everything else
is dashboard-only.

| Alert                                    | Condition                                    | Severity | Why                                            |
| ---------------------------------------- | -------------------------------------------- | -------- | ---------------------------------------------- |
| Phoenix down                             | `/health` non-200 for 2 min                  | page     | Control plane is offline.                      |
| Database unreachable                     | `bank.ops.health.database_up = 0` for 1 min  | page     | No traffic can be served.                      |
| Adapter unreachable                      | `bank.ops.health.adapter_up = 0` for 5 min   | page     | No on-chain dispatch possible.                 |
| Stuck executions                         | `bank.ops.health.stuck_plans > 0` for 5 min  | page     | Callbacks broken or chain stalled.             |
| Callback auth failures                   | 401 rate on `/internal/adapter/callback` > 1/min | warn     | Secret rotation went wrong.                    |
| Oban queue backing up                    | `oban.job.stop.duration` p95 > 30s (any queue)| warn     | Jobs starving — likely DB or downstream.       |
| Decision abort rate                      | `bank.autonomy.decision.count{outcome="block"}` > 10% hourly | warn | Policy drift or attack signal.               |

## Alert destinations

For alpha, a single Slack channel is enough:

- **Channel**: `#bank-alerts` (private, operators + on-call only).
- **Delivery**: Alertmanager → Slack webhook, or equivalent on the
  chosen provider.

A paging integration (PagerDuty / OpsGenie) is only worth wiring once
we have a formal on-call rotation — during alpha the operator on
point is the one sitting at the keyboard.

## Dashboards

Minimum dashboard set for the alpha operator console (build on top of
whatever Grafana or provider-native tooling is available):

1. **Executive health** — one page:
    - Traffic light for each of `database_up`, `adapter_up`,
      `stuck_plans`.
    - Last hour of decision counts by outcome.
    - Last hour of execution lifecycle counts.
2. **Execution pipeline** — time series:
    - Plans per lifecycle status (stacked area).
    - Oban queue depth and job duration.
    - 4xx/5xx rate on `/internal/adapter/callback`.
3. **Chain surface** — time series:
    - Adapter reachability, `bank.quotes.preview.count` by result.
    - Security events (pause/resume/revoke) as markers.

## Runbook pointers

When a health check fails, these are the first things to check.
Detailed procedures land in [docs/incident-runbook.md](incident-runbook.md)
(issue #38).

| Symptom                             | First checks                                                              |
| ----------------------------------- | ------------------------------------------------------------------------- |
| `database_up = 0`                   | Postgres process, network ACL, pool exhaustion (`bank.repo.query.queue_time`). |
| `adapter_up = 0`                    | Adapter logs, bundler reachability, shared-secret mismatch.               |
| `stuck_plans > 0`                   | Callback receipts in audit log, `/internal/adapter/callback` 4xx rate.    |
| Oban queue backing up               | `oban_jobs` table for stuck rows; retry history for the top offending job. |

## Blocker note for issue #37

In-repo monitoring surface is complete:

- `Bank.Ops.Health` module with DB / adapter / stuck-plan checks.
- `GET /v1/health/deep` endpoint using that module, returning 503 on
  any degraded check.
- Telemetry poller emitting `bank.ops.health.*` gauges every 10s.
- This doc covering endpoints, metrics, alerts, and dashboard plans.

**What's blocked**: wiring to a concrete dashboard/alerting backend
(Grafana, Datadog, Prometheus) and creating the Slack webhook — these
need operator credentials and a chosen provider; tracked alongside the
cloud-provisioning work in [docs/staging.md](staging.md).
