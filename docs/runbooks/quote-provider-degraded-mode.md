# Quote provider observability and degraded mode

> Status: ships with #176, runtime-visible from v0.1.

The quote/simulation pipeline (`Bank.Quotes.preview/2`) calls a
configured provider — `:stub` (default), `:live` (Tenderly via
`Bank.Quotes.LiveProvider`), or `:disabled` (fail-closed). This
runbook explains how to tell which mode is active, how the runtime
degrades when the live provider is unavailable, and how to read the
operational signals.

## How to tell stub vs live is active

### From the dispatch envelope (per-decision)

Every decision call records the *attempted* provider on the
persisted `SimulationReport.provider` column:

  * `"stub"` — the deterministic in-process provider produced the
    preview. Default in dev/test.
  * `"tenderly"` — the live HTTP provider produced or attempted the
    preview.
  * `"disabled"` — the deployment short-circuited with
    `provider: :disabled`.

Successful previews carry the responsible provider's id;
failed previews ALSO carry the attempted provider's id (#175) so an
operator inspecting a `:failed` row in `simulation_reports` can tell
whether the live HTTP call failed, the stub failed, or the
deployment is intentionally disabled.

The simulate endpoint surfaces the same field at
`simulation.provider` and `simulation.provider_trace_ref`. The
trace ref is provider-supplied and goes through
`Bank.Quotes.LiveProvider`'s secret-pattern allowlist before
landing on the wire (#174 / #442 / #445).

### From the deep-health payload (cluster-wide)

`GET /v1/health/deep` exposes a `quotes_provider` check block:

```json
{
  "checks": {
    "quotes_provider": {
      "status": "ok",
      "detail": null,
      "providers": [
        {
          "provider": "tenderly",
          "status": "healthy",
          "success_count": 42,
          "failure_count": 0,
          "last_success_at": "2026-05-06T07:51:03.214Z",
          "last_failure_at": null,
          "last_failure_reason": null
        }
      ]
    }
  }
}
```

The `providers` list is the same data
`Bank.Quotes.ProviderHealth.all/0` returns, drawn from a node-local
ETS table updated by `Bank.Quotes.preview/2`'s telemetry hook. No
HTTP probe runs on the provider — the readiness payload reports what
the runtime has already observed during real traffic.

`status` rollup:

  * `ok` — every tracked provider is `healthy` or `unknown`, OR no
    providers have been observed (fresh boot before the first
    preview call).
  * `degraded` — at least one provider is in `:degraded` status
    (≥80% success rate but at least one failure observed).
  * `down` — at least one provider is in `:failing` status (<80%
    success rate).

The worst per-provider status wins. `detail` carries a short
allowlist string of the form `provider_<id>_<status>` (e.g.
`provider_tenderly_failing`) — never an inspect of internal
structs, RPC URL, Authorization header, or PEM material.

### From `Application.get_env/2` (configured mode)

```elixir
Application.get_env(:bank, Bank.Quotes)
# => [provider: :live]   (or :stub / :disabled / a module name)
```

`Bank.Quotes.attempted_provider_id/1` returns the same string the
persistence layer records for the configured deployment, e.g.
`"tenderly"` for `:live`, `"stub"` for `:stub`, `"disabled"` for
`:disabled`.

## How the runtime degrades on provider outage

When `Bank.Quotes.LiveProvider` cannot reach the upstream (transport
error, timeout, 5xx, malformed body), `preview/2` returns a
structured `{:error, reason}` instead of crashing or returning a
fake success. The decision pipeline treats this as a fail-closed
signal:

  1. `Bank.Decisions.evaluate_intent/2` writes a `:failed`
     `SimulationReport` row carrying:
     - `provider` — the attempted provider id (`"tenderly"`),
     - `failure_conditions.items.[0]` — `{kind: "preview_failed",
       message: "preview provider unavailable" | "preview stale; awaiting refresh" | …}`,
     - `status: :failed`.
  2. `Bank.Autonomy.route/2` reads the `:failed` simulation and
     downgrades the autonomy outcome to `:hold` (or `:block` for
     `{:simulation_failed, _}` — the upstream answered but the
     dry-run rejected, which is a hard policy stop).
  3. The intent state is NEVER moved to `:executing` on a failed
     preview. The `Ecto.Multi` write is atomic — either the
     `:failed` row + the matching decision envelope land together,
     or the transaction rolls back and the intent stays in its
     prior state.
  4. `Bank.Quotes.ProviderHealth.record_failure/2` is called with a
     category atom (`:provider_unavailable`, `:simulation_failed`,
     `:provider_disabled`, `:not_yet_implemented`, `:stale`,
     `:unsupported`, `:provider_exception`, or `:error`). The
     readiness payload picks this up on the next `/v1/health/deep`
     hit; no notification storm — health is read-only.

There is no automatic retry storm: `Bank.Quotes.LiveProvider` is
configured with `retry: false` on Req. Re-simulation is operator-
or autonomy-driven through the existing `simulate(reason: "refresh")`
flow.

## Configuring live provider in staging

```elixir
# config/runtime.exs
config :bank, Bank.Quotes, provider: :live

config :bank, Bank.Quotes.LiveProvider,
  base_url: System.get_env("TENDERLY_BASE_URL"),
  api_key: System.get_env("TENDERLY_API_KEY")
```

Missing env vars in production do NOT raise — `LiveProvider` degrades
to `{:error, :provider_unavailable}` (logged with
`category=not_configured`). Staging deployments should run
`/v1/health/deep` after deploy: the `quotes_provider` check should
report `unknown` until the first preview, then `healthy` once a
real intent has been simulated against the live upstream.

## What is still quote/planning-only in MVP

The MVP plan keeps live execution on Base Sepolia + 0x only (#192).
1inch, CCTP, and Jupiter providers are quote/planning-only —
`Bank.Quotes.LiveProvider` (Tenderly-backed) is the sole source of
truth for live preview metadata. There is no live mainnet simulation
in v0.1.

## Smoke recipes

### Local stub-mode smoke

Run the deterministic stub-only smoke. No `.env`, no Tenderly HTTP,
no DB writes outside the resettable `Bank.Quotes.ProviderHealth`
ETS table:

```sh
mix bank.quotes.smoke
```

Expected output (PASS lines may print in either order; the summary
is canonical):

```text
Bank quote provider smoke

  PASS quotes.stub_success — stub returned %Preview{source: :stub, provider: "stub"}
  PASS quotes.attempted_provider_id — stub/live/disabled atoms + module forms resolve to expected ids
  PASS quotes.health_recorded_after_success — :healthy with success_count=1 after stub preview
  PASS quotes.health_recorded_after_failure — :failing with last_failure_reason=:provider_unavailable
  PASS quotes.health_snapshot_rollup — /v1/health/deep `quotes_provider` rolls up to :down on stub failure
  PASS quotes.secret_hygiene — ProviderHealth state carries no Authorization/sk_/pk_/credentialed-URL/PEM markers
  PASS quotes.live_provider_disabled_default — default deployment without `provider:` config resolves to "stub"

7 / 7 PASS
No live network, no `.env` reads, no Tenderly HTTP.
```

Exit code is 0 on PASS, 1 on FAIL — CI steps can read the exit
status without parsing stdout. The smoke is idempotent: the
runner snapshots `ProviderHealth` before the run and restores
existing state afterwards so the readiness payload does not
record the smoke's synthetic stub failure once the run exits.

### Manual one-shot stub preview

For a single API round-trip, hit the simulate endpoint with the
default (stub) provider:

```sh
curl -sS -X POST http://localhost:4000/v1/intents/<intent-id>/simulate \
  -H "x-api-key: $LOCAL_API_KEY" \
  -H "content-type: application/json" \
  -d '{"reason":"pre_submit_dry_run"}' \
  | jq '.simulation | {provider, status}'
# => { "provider": "stub", "status": "completed" }
```

### Staging live-provider smoke

Live provider is opt-in. The exact env var names and config keys
are:

```elixir
# config/runtime.exs
config :bank, Bank.Quotes, provider: :live

config :bank, Bank.Quotes.LiveProvider,
  base_url: System.get_env("TENDERLY_BASE_URL"),
  api_key: System.get_env("TENDERLY_API_KEY")
```

Set the environment variables outside of any committed file —
the runbook never includes real keys, and `TENDERLY_API_KEY` /
`TENDERLY_BASE_URL` should be passed in via the secret store
(operator's choice — `direnv`, `kubectl create secret`, etc.).
Missing env vars in production do NOT raise; `LiveProvider`
degrades to `{:error, :provider_unavailable}` (logged with
`category=not_configured`).

After a staging deploy:

  1. Verify the configured mode (no real keys printed):

     ```sh
     iex --remsh staging@host -e \
       'IO.inspect(Bank.Quotes.attempted_provider_id())'
     # => "tenderly"
     ```

  2. Run a real simulate against any seeded intent:

     ```sh
     curl -sS -X POST https://staging.example.com/v1/intents/<id>/simulate \
       -H "x-api-key: $STAGING_API_KEY" \
       -H "content-type: application/json" \
       -d '{"reason":"pre_submit_dry_run"}'
     ```

     Expected response excerpt:

     ```json
     {
       "simulation": {
         "provider": "tenderly",
         "status": "completed",
         "provider_trace_ref": "tenderly-trace-…"
       }
     }
     ```

  3. Confirm the health surface picked up the success:

     ```sh
     curl -sS https://staging.example.com/v1/health/deep \
       | jq '.checks.quotes_provider'
     # => {
     #   "status": "ok",
     #   "detail": null,
     #   "providers": [
     #     {
     #       "provider": "tenderly",
     #       "status": "healthy",
     #       "success_count": 1,
     #       "failure_count": 0,
     #       "last_success_at": "<iso8601>",
     #       "last_failure_at": null,
     #       "last_failure_reason": null
     #     }
     #   ]
     # }
     ```

### Verifying degraded / failing states safely

To prove the runtime degrades safely without breaking the live
upstream, point `TENDERLY_BASE_URL` at an invalid host and
re-run the simulate. The provider returns
`{:error, :provider_unavailable}`; the persisted
`simulation_reports` row carries `status: "failed"` and
`provider: "tenderly"`; `/v1/health/deep` shows
`quotes_provider.providers[].last_failure_reason:
"provider_unavailable"`. The intent's `current_simulation_id`
moves to the failed row and the autonomy router holds the
intent — no `:executing` transition.

The category-atom failure-reason vocabulary is the only thing
that surfaces in the readiness payload: `provider_unavailable`,
`simulation_failed`, `provider_disabled`, `not_yet_implemented`,
`stale`, `unsupported`, `provider_exception`, `error`. Free-form
upstream strings, response bodies, request URLs, Authorization
headers, and PEM material are never persisted.

## Secret hygiene posture

`Bank.Quotes.ProviderHealth` stores ATOMS only for
`last_failure_reason`, drawn from the fixed
`@result_tag_allowlist`. Free-form strings, raw `inspect/1`,
upstream response bodies, request URLs, Authorization headers, and
PEM material are never persisted in the readiness payload.
`Bank.Quotes.LiveProvider`'s log output (#174) is similarly
collapsed onto category atoms. The combined surface — health,
audit, replay, simulation reports — never carries provider
secrets.
