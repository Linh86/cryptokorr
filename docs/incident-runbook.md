# Alpha incident runbook

Operator playbook for the Bank control plane. Covers the incident
categories the alpha is most likely to hit: adapter outages, stuck
executions, callback auth failures, chain-side refusals, emergency
pauses, and revocation gone wrong. Pairs with
[docs/monitoring.md](monitoring.md) (what to watch) and
[docs/deploy.md](deploy.md) (how to roll back code).

## How to use this doc

1. **Identify the symptom** in the table below.
2. Jump to the matching section.
3. Execute the **Immediate actions** — these are safe to run without
   approval.
4. Move to **Diagnose** once traffic is protected.
5. Record the timeline in the incident channel as you go. Template at
   the bottom of this file.

| Symptom                                              | Section                                                  |
| ---------------------------------------------------- | -------------------------------------------------------- |
| `/v1/health/deep` reports `adapter: error`           | [Adapter outage](#adapter-outage)                        |
| Execution plans stuck in `:broadcasting` / `:pending_confirmation` | [Stuck executions](#stuck-executions)          |
| 401 spike on `/internal/adapter/callback`            | [Callback auth mismatch](#callback-auth-mismatch)        |
| Partner reports "transfer never confirmed"           | [Missing confirmation](#missing-confirmation)            |
| Chain refuses every intent (bundler_rejected, etc.)  | [Chain-side refusal cascade](#chain-side-refusal-cascade)|
| Delegation revoke submitted but never lands          | [Revoke did not land](#revoke-did-not-land)              |
| Need to stop *everything* right now                  | [Emergency pause](#emergency-pause)                      |
| Workspace API keys leaking / one agent compromised   | [Workspace agent-key lockdown](#workspace-agent-key-lockdown) |
| Postgres unreachable                                 | [Database outage](#database-outage)                      |
| Verifying recovery after any pause / abort / revoke   | [Resume checklist](#resume-checklist)                    |

> **Not yet supported (tracked under #228):** per-chain, per-smart-account,
> and per-api-key scoped pauses are still design/implementation work. Today
> the fail-closed pause levers are the global / counterparty
> [Emergency pause](#emergency-pause) and the
> [Workspace agent-key lockdown](#workspace-agent-key-lockdown). If an
> incident would benefit from a narrower scope, use the available wider
> pause and record the desired narrower scope in the incident notes until
> #228 Phase 1 lands. Design memo: PR #310.

---

## Adapter outage

**Signal**: `bank.ops.health.adapter_up = 0` for 5+ min, deep health
returns 503 with `adapter: error`.

### Immediate actions

1. Confirm the adapter process is actually down:
   ```sh
   curl -sSf "$ADAPTER_BASE_URL/healthz" -o /dev/null -w "%{http_code}\n"
   ```
2. Check the adapter's container / process logs.
3. If the adapter is down *and* plans are queuing up, pause execution
   to stop accumulating retries:
   ```sh
   curl -XPOST "$PHX_HOST/v1/security/pause" \
     -H "authorization: Bearer $OP_TOKEN" \
     -d '{"scope": "global", "reason": "adapter_outage"}'
   ```

### Diagnose

- **Adapter crashed**: restart; check recent deploy. Roll back via
  [docs/deploy.md](deploy.md#rollback) if the last deploy is
  suspicious.
- **Network partition**: check ingress / VPC peering.
- **Bundler upstream down**: the adapter cannot broadcast. Wait it out
  (Alchemy/Pimlico status pages) or fail over to a secondary bundler
  if the adapter supports one.

### Recovery

1. Verify `/healthz` returns 200 again.
2. Resume execution:
   ```sh
   curl -XPOST "$PHX_HOST/v1/security/resume" \
     -H "authorization: Bearer $OP_TOKEN" \
     -d '{"scope": "global"}'
   ```
3. Oban retries drain the backlog automatically. Watch
   `oban.job.stop.duration{queue="runtime_execution"}` fall off.
4. Run the transfer smoke (`mix bank.smoke.transfer`) to confirm
   round-trip health.

---

## Stuck executions

**Signal**: `bank.ops.health.stuck_plans > 0` for 5+ min, or partner
reports a transfer hanging.

### Detection sources

Two independent signals fire on stuck plans:

- **Telemetry gauge `bank.ops.health.stuck_plans`** — a single
  workspace-agnostic count emitted on the readiness deep-check
  poller. Surfaces in `/v1/health/deep` and your metrics backend.
- **Audit event `ops.stuck_plan_detected`** — emitted per stuck plan
  by `Bank.Runtime.Workers.ScanStuckPlans` (#230-b). The cron fires
  every 2 minutes; per-plan emissions are deduped on a 5-minute
  aligned `window_start` so a single legitimately-stuck plan
  generates one alert per 5 min, not every tick. Per-status
  thresholds (in seconds, tunable via
  `config :bank, Bank.Ops.Health, stuck_plan_thresholds: [...]`):

  | status                    | default threshold |
  | ------------------------- | ----------------- |
  | `:prepared`               | 600 (10 min)      |
  | `:signing`                | 300 (5 min)       |
  | `:broadcasting`           | 600 (10 min)      |
  | `:pending_confirmation`   | 1800 (30 min)     |

  Audit `after_ref` carries `execution_status`, `stuck_for_seconds`,
  `threshold_seconds`, `window_start`. `subject_type` is
  `execution_plan`; `subject_id` is the plan UUID;
  `correlation_id` is the parent intent.

### Audit grep recipe

```sh
# All currently-active detector signals across the workspace.
curl -sS "http://localhost:4000/v1/audit?event_type=ops.stuck_plan_detected" \
  -H "Authorization: Bearer cb_<…redacted…>" \
  | jq '.data[] | {plan: .subject_id, after: .after_ref}'
```

Pivot from a flagged plan to the manual-abort audit row by
`subject_id`:

```sh
curl -sS "http://localhost:4000/v1/audit?event_type=execution.aborted&subject_id=<plan-uuid>" \
  -H "Authorization: Bearer cb_<…redacted…>" | jq '.data[0]'
```

The `execution.aborted` row's `after_ref.final_reason` echoes the
operator-supplied reason; `actor` distinguishes a runtime-emitted
abort (`:runtime`, e.g. `RunExecution`'s pause/delegation guards)
from an operator-emitted one (`:user`, the manual abort path
below).

### Immediate actions

1. List stuck plans:
   ```sh
   /app/bin/bank remote
   ```
   ```elixir
   import Ecto.Query
   alias Bank.Decisions.ExecutionPlan
   alias Bank.Repo

   cutoff = DateTime.utc_now() |> DateTime.add(-900, :second)

   Repo.all(
     from p in ExecutionPlan,
       where: p.execution_status in [:prepared, :signing, :broadcasting, :pending_confirmation],
       where: p.updated_at < ^cutoff,
       select: {p.id, p.execution_status, p.updated_at, p.tx_refs}
   )
   ```
2. Grab the userop hash (if present) from `tx_refs` and check it on
   the block explorer.

### Diagnose

- **Userop included but no callback**: adapter may have missed the
  event. Check adapter logs for the userop hash; confirm the
  event-tailer is running.
- **Userop never included**: bundler dropped it. Check mempool; the
  adapter should re-submit or mark aborted.
- **Callback arrived but was rejected**: search Phoenix logs for
  `Execution callback for unknown plan` or changeset errors.

### Recovery

- If the callback was lost, the adapter should be able to re-emit it.
  If it cannot, a one-off operator fix is needed — do NOT manually
  force-set `:confirmed`. Abort the stuck plan instead.
- **HTTP path (`POST /v1/security/abort_execution`, #230).** Admin
  API key, chain-action rate-limited (5 req / 60 s):
  ```sh
  curl -sS -X POST http://localhost:4000/v1/security/abort_execution \
    -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d '{"execution_plan_id":"<plan-uuid>","reason":"stuck_pending"}' \
    | jq
  # 200 — plan moved to :aborted; intent moved :decided|:executing → :blocked
  # {
  #   "status": "aborted",
  #   "data": {
  #     "execution_plan_id": "...",
  #     "decision_id":       "...",
  #     "execution_status":  "aborted",
  #     "final_outcome":     "aborted",
  #     "final_reason":      "stuck_pending",
  #     "workspace_id":      "..."
  #   }
  # }
  ```
  Only `:prepared` plans are abortable on this endpoint. Plans
  already dispatched (`:signing`, `:broadcasting`,
  `:pending_confirmation`) return `409 not_safe_to_abort` with
  `details.execution_status` carrying the current state — those need
  an adapter-side cancel + callback path that this v0.1 surface
  deliberately does not own. Already-terminal plans (`:confirmed`,
  `:reverted`, `:aborted`) return `200` idempotently with the same
  body shape and **no** second audit row, so re-issuing the call
  after a partial network failure is safe.
- **IEx fallback** for incidents that need to abort more than 5
  plans in a minute (e.g., adapter-side outage cascade) or for
  plans the chain-action rate cap has gated:
  ```elixir
  ws = Bank.Repo.get!(Bank.Workspaces.Workspace, "<workspace-uuid>")
  user = Bank.Accounts.get_user("<admin-user-uuid>")

  Bank.Decisions.abort_plan(plan_id, ws,
    reason: :stuck_pending,
    actor: :user,
    actor_id: user.id
  )
  # → {:ok, :aborted, %ExecutionPlan{...}, {:transitioned, prior_state, %AgentIntent{...}}}
  ```
  Same workspace boundary, same `FOR UPDATE` row lock, same audit
  emission as the HTTP path — just no role gate (you're already in
  IEx) and no rate cap.
- After the abort, advise the partner to re-submit the intent.
  The aborted plan flips to `active: false` so the partial unique
  index `execution_plans_decision_active_idx (WHERE active)`
  releases the slot — `request_manual_execution/3` for the same
  decision can land a fresh `:prepared, active: true` plan.
- Two safety nets cover the residual long tail:
  `Bank.Runtime.Workers.ScanStuckPlans` (#230-b) re-emits
  `ops.stuck_plan_detected` audit rows so the operator keeps
  seeing flags until the row leaves a non-terminal status; the
  legacy `ConfirmExecution` poller ages stuck plans out to
  `:aborted` after its own timeout. Let both run unless the
  backlog is large.

### Bulk-abort rate-limit caveat

The HTTP path is gated by the `:api_chain_action` rate limit
(default 5 req / 60 s per calling key, see
`config :bank, Bank.RateLimit, chain_action_per_window: 5`).
If a single incident produces more than 5 stuck plans in one
detection window (e.g., adapter cascade), the 6th `curl` returns
`429 rate_limited`. Drop to the IEx fallback above — same
workspace boundary, same `FOR UPDATE` row lock, same audit
emission, no rate cap.

---

## Callback auth mismatch

**Signal**: bursts of `BankWeb.Plugs.VerifyAdapterAuth: bearer
mismatch` or `missing_authorization` warnings; 401 rate on
`/internal/adapter/callback` > 1/min.

### Immediate actions

1. Confirm which side is wrong. The callback direction uses
   `ADAPTER_CALLBACK_SECRET`:
   ```sh
   # On the Phoenix host:
   /app/bin/bank eval 'Application.get_env(:bank, Bank.AdapterClient)[:callback_secret] |> String.slice(0, 6) |> IO.puts()'
   # On the adapter host:
   echo "$ADAPTER_CALLBACK_SECRET" | cut -c1-6
   ```
   The first 6 chars must match. If they don't, one side has the wrong
   secret. (For the dispatch direction the equivalent vars are
   `:dispatch_secret` / `ADAPTER_DISPATCH_SECRET`.)
2. If Phoenix is rejecting valid adapter traffic, pause intake so you
   don't pile up ambiguous state:
   ```sh
   curl -XPOST "$PHX_HOST/v1/security/pause" \
     -H "authorization: Bearer $OP_TOKEN" \
     -d '{"scope": "global", "reason": "auth_rotation_incident"}'
   ```

### Recovery

Redo the rotation procedure from
[docs/security.md](security.md#shared-secret-management). Key
points:

- Roll **both sides together** within the same window.
- The callback endpoint returns 401 on mismatch — the adapter should
  NOT mark events as delivered on a 401. Double check.
- Once both sides match, resume execution and run the smoke checks.

---

## Missing confirmation

**Signal**: a partner says "I sent a transfer five minutes ago, it
never confirmed," but the control tower shows the plan as
`:pending_confirmation`.

### Immediate actions

1. Pull the intent replay:
   ```sh
   curl "$PHX_HOST/v1/intents/<intent_id>/replay"
   ```
2. Note the userop hash (if any).
3. Hit the block explorer — filter by the smart account address.

### Diagnose

- **Userop included successfully, event missed**: adapter-side
  event-tailer gap. See [Stuck executions](#stuck-executions).
- **Userop dropped from mempool**: the adapter should have emitted
  `execution.aborted` with reason `replaced` or `timeout`. If it did
  not, the adapter has a gap.
- **Different plan / wrong chain**: double check the partner's
  `smart_account_id` and chain — it is surprisingly easy to send a
  Base tx while looking at a Base Sepolia explorer.

### Recovery

- If the userop succeeded on chain but Phoenix never got the
  callback, manually accept it via a signed operator intent rather
  than forcing plan state directly. We do not have a "reconcile from
  chain" tool yet — this is a known gap tracked for post-alpha.
- Otherwise, instruct the partner to re-submit. The original plan
  ages out to `:aborted` via the safety-net poller.

---

## Chain-side refusal cascade

**Signal**: every new plan terminates with
`{:aborted, :bundler_rejected}` or `:paymaster_denied` within
seconds.

### Immediate actions

1. Pause execution to stop burning attempts:
   ```sh
   curl -XPOST "$PHX_HOST/v1/security/pause" \
     -H "authorization: Bearer $OP_TOKEN" \
     -d '{"scope": "global", "reason": "chain_refusal_cascade"}'
   ```
2. Grab one `final_reason` from a failed plan — that's what the
   bundler / paymaster actually said.

### Diagnose

- **`bundler_rejected`**: nonce conflict, underpriced gas, or the
  bundler upstream is stricter than expected. Check bundler provider
  status.
- **`paymaster_denied`**: allowance exhausted, policy rejected the
  sponsor, or paymaster key rotated. Check sponsor balance + policy.
- **`delegation_revoked`**: every plan will abort if the delegation
  is gone. Check
  `Bank.Delegations.get("<smart_account_id>")`.

### Recovery

- For paymaster allowance: top up, then resume.
- For delegation gap: re-grant via the control tower (see
  [docs/security.md](security.md) on delegation flows), then resume.
- Run `mix bank.smoke.transfer` before resuming partner traffic.

---

## Revoke did not land

**Signal**: operator called `POST /v1/security/revoke_delegation` but
either the delegation row stays `:revoking` with no terminal
callback, or it transitioned to `:revoke_failed` (meaning the adapter
attempted the revoke and the chain-level attempt could not complete).

Note: Phoenix stays fail-closed the whole time — `RunExecution`
refuses to dispatch transfers from this smart account the moment the
`:revoking` projection is written, before the adapter has even
broadcast the sentinel, and continues to refuse through any
`:revoke_failed` retries. The operator risk here is visibility and
audit, not a window of unguarded execution.

### Immediate actions

1. Check the Oban retry state:
   ```elixir
   Oban.Job |> where(worker: "Bank.Runtime.Workers.RevokeDelegation") |> Repo.all()
   ```
2. Look for recent `Bank.AdapterClient /dispatch/revoke_delegation
   unavailable` warnings.
3. Query `delegations` for the smart account and inspect `state`
   plus `last_reason` — the adapter encodes the failure class in
   `last_reason` and the state is the source of truth for whether
   the revoke succeeded:
    - `state: :revoked` — chain confirmed; the revoke attempt
      succeeded. For rows with `permission_id` populated this is
      a cryptographic disablement (#58 / #31, closed by PR
      #132); for legacy rows without artifacts it is an on-chain
      anchor of intent (the sentinel UserOp).
    - `state: :revoke_failed` — chain-level attempt failed; the
      delegation is still live on-chain.
    - `state: :revoking` with no recent callback — adapter is
      probably down or slow.

### Diagnose

- Adapter outage (no callback at all): see [Adapter outage](#adapter-outage)
  first; the worker will retry and the revoke drives forward when the
  adapter is back.
- Adapter rejected the dispatch (4xx): look for
  `RevokeDelegation: adapter rejected smart_account ... (HTTP 4xx)`.
  4xx rejections are NOT retried — the delegation is stuck and needs
  manual investigation.
- `state: :revoke_failed`, `last_reason: send_failed: ...`: the
  adapter wallet couldn't broadcast the sentinel tx (nonce mismatch,
  insufficient gas funds on the adapter operator key, RPC outage).
  No tx hash to check on chain. Adapter logs have the underlying
  error; most common fix is topping up the adapter operator key.
- `state: :revoke_failed`, `last_reason: confirmation_failed: ...`:
  the sentinel tx was broadcast (hash is in `last_tx_hash`) but the
  adapter gave up waiting for 2 confirmations. Verify on Basescan —
  the tx usually did land a few blocks later; the callback just
  reported before the chain caught up.
- `state: :revoke_failed`, `last_reason: sentinel_reverted`: the
  sentinel self-transfer reverted. Rare (0-wei self-transfer almost
  never reverts); indicates adapter misconfiguration. Escalate to
  the adapter on-call.

### Recovery

- Once the adapter is healthy, Oban retries drain naturally.
- For a 4xx-rejected revoke, fix the root cause (the adapter's
  `error.code` tells you what), then re-issue the revoke.
- For `:revoke_failed`, an operator can **retry the revoke** on the
  same delegation row: call `POST /v1/security/revoke_delegation`
  again (or click "Retry revoke" on the control tower). Phoenix
  re-transitions the row `:revoke_failed → :revoking` and the
  adapter submits a fresh sentinel tx. Retry as many times as
  needed; each attempt appends a fresh audit trail.
- **The sentinel path is the LEGACY fallback.** For rows with
  `permission_id` populated the cryptographic
  `Kernel.uninstallValidation(...)` runs and `revoked` means the
  kernel rejects further user-ops from the disabled permission.
  For legacy rows without `permission` artifacts the sentinel
  still runs and `revoked` means "on-chain anchored, trust
  downgraded" only. Cryptographic enforcement landed under PR
  #132; the operator smoke runbook is in
  [docs/mvp-smoke-runbook.md](mvp-smoke-runbook.md). Phoenix's
  fail-closed posture (delegations marked
  `:revoking`/`:revoke_failed`/`:revoked` are non-executable for
  `RunExecution`) keeps the delegation off the dispatch path
  regardless of which revoke path runs.

  If the cryptographic revoke fails on a row that should have
  taken it, the callback's `reason` field carries one of the
  precise codes the adapter emits — `operator_key_missing`,
  `validation_id_mismatch`, `package_version_mismatch`,
  `session_signer_missing`, `permission_deserialization_failed`,
  `deinit_computation_failed`, `unaccepted_signer_module`,
  `unaccepted_policy_module`, or `uninstall_validation_reverted`.
  Match the code against the failure-triage table in the smoke
  runbook for remediation.

---

## Emergency pause

**Signal**: the operator sees something they cannot diagnose (unknown
mass approvals, unexplained transfers, confused audit). Stop first,
ask questions second.

### Immediate actions

```sh
# Pause everything. Accepts no new auto_execs, runs no dispatch.
curl -XPOST "$PHX_HOST/v1/security/pause" \
  -H "authorization: Bearer $OP_TOKEN" \
  -d '{"scope": "global", "reason": "unknown_incident"}'

# Revoke every active delegation in-flight.
# (Per smart account; repeat per row or use the control tower's
# bulk revoke once it lands.)
curl -XPOST "$PHX_HOST/v1/security/revoke_delegation" \
  -H "authorization: Bearer $OP_TOKEN" \
  -d '{"smart_account_id": "<sa_id>", "reason": "emergency_pause"}'
```

Only after the pause is confirmed, open the audit log and investigate.

### Recovery

- Resume only once you have a story for *why* the pause happened and
  evidence that the cause is addressed.
- Record the incident and outcome before unpausing.

---

## Workspace agent-key lockdown

**Signal**: a workspace's API keys are leaking, an agent process is
behaving suspiciously, or the operator wants to halt every `/v1`
request from one workspace without taking the whole runtime down
(#231-a / #231-b).

### Immediate actions

```sh
# Pause every API key in the calling workspace. Workspace is taken
# from the calling key's `current_scope`; a `workspace_id` field in
# the body is silently ignored.
curl -sS -X POST "$PHX_HOST/v1/security/pause_agent_keys" \
  -H "Authorization: Bearer cb_<…redacted-admin-key…>" \
  -H "Content-Type: application/json" \
  -d '{"reason": "credential leak under investigation"}' \
  | jq
# 200 — { "data": { "workspace_id": "...", "paused": true,
#                   "agent_keys_paused_at": "2026-05-01T...Z",
#                   "paused_by_user_id": "...",
#                   "reason": "credential leak under investigation" } }
```

Once paused, every `/v1` request from this workspace's API keys
returns `401 invalid_credentials` — including the calling admin key
that just made the pause call. The audit row carries
`event_type: "agent_keys.paused"`, `actor: :user`, the operator's
`actor_id`, and the workspace id as `subject_id`. See
[`docs/runbooks/api-key-auth-smoke.md`](runbooks/api-key-auth-smoke.md)
Step 16 for a full bootstrap walkthrough.

### Resume — bootstrap caveat

**The same workspace's HTTP API cannot resume itself.** The
`POST /v1/security/resume_agent_keys` endpoint exists but it is
itself behind `VerifyAPIKey`, so a paused workspace will 401 every
attempt. Resume MUST come from one of:

1. **The `/security` LiveView console** — Google OAuth session, NOT
   routed through `VerifyAPIKey`. Operator-recommended path.
2. **`Bank.APIKeys.resume_workspace/2` from IEx**:

   ```elixir
   ws   = Bank.Repo.get!(Bank.Workspaces.Workspace, "<workspace-uuid>")
   user = Bank.Accounts.get_user("<admin-user-uuid>")
   {:ok, :resumed, _} = Bank.APIKeys.resume_workspace(ws, user)
   ```

After resume, retry one of the previously-failing keys to confirm
`/v1` access is restored.

---

## Database outage

**Signal**: `bank.ops.health.database_up = 0`, Phoenix returning 500s,
many log lines `DBConnection.ConnectionError`.

### Immediate actions

1. Confirm Postgres is up (managed provider status page or
   `pg_isready`).
2. If the pool is exhausted but the DB is healthy (`queue_time`
   elevated), investigate runaway queries before raising the pool
   size.

### Diagnose

- **Provider outage**: wait it out, talk to the provider.
- **Connection leak**: restart Phoenix to recover; file a bug.
- **Disk full / WAL bloat**: provider-side incident. Escalate.

### Recovery

- When Postgres is back, Phoenix reconnects automatically.
- If Oban was backed up, jobs drain as capacity returns. Monitor
  `oban.job.stop.duration` until it returns to baseline.

---

## Resume checklist

Use this list AFTER any pause / abort / revoke action, before
declaring the incident resolved. Each step is a hard fail: stop
and re-investigate if a check returns the wrong shape.

1. **Deep readiness probe is `:ok`.**
   ```sh
   curl -sS "$PHX_HOST/v1/health/deep" | jq '.status'
   # → "ok"
   ```
   `:degraded` means at least one check (`database`, `adapter`,
   `stuck_plans`) is still red. Stop and resolve before moving on.
2. **No fresh `ops.stuck_plan_detected` rows in the current
   detection window.** The detector cron is every 2 min; the dedupe
   window is 5 min. If a new row appears 5+ min after your abort,
   something is still stuck.
   ```sh
   curl -sS "$PHX_HOST/v1/audit?event_type=ops.stuck_plan_detected&limit=5" \
     -H "Authorization: Bearer cb_<…redacted-admin-key…>" \
     | jq '.data[].after_ref.window_start'
   ```
3. **Every `agent_keys.paused` row in the last hour has a matching
   `agent_keys.resumed` row** (or the workspace is intentionally
   still locked down). Same query, swap `event_type` and grep
   `subject_id` for unmatched workspace ids.
4. **Every `security.paused` row in the last hour has a matching
   `security.resumed`** for the same scope (`global` /
   `counterparty:<id>`). The runtime never auto-resumes; an
   unmatched pause means the runtime is still gated.
5. **The smoke transfer round-trips against the staging adapter.**
   ```sh
   mix bank.smoke.transfer
   ```
   This exercises end-to-end intent → decision → dispatch →
   callback. A clean run is the strongest single signal that the
   stack is back.
6. **Issue resume curls per scope, in this order**, and confirm the
   `200` response shape from each:

   ```sh
   # Global runtime resume.
   curl -XPOST "$PHX_HOST/v1/security/resume" \
     -H "Authorization: Bearer cb_<…redacted-admin-key…>" \
     -d '{"scope": "global"}'

   # Counterparty-scoped resume (only if you previously paused this scope).
   curl -XPOST "$PHX_HOST/v1/security/resume" \
     -H "Authorization: Bearer cb_<…redacted-admin-key…>" \
     -d '{"scope": "counterparty:<cp-uuid>"}'

   # Workspace agent-key resume — MUST come from the /security
   # LiveView console or IEx (see "Workspace agent-key lockdown" §).
   ```

7. **Record the incident and outcome.** Use the [Incident log
   template](#incident-log-template) below.

---

## Communication checklist

When an incident affects partners or external parties:

- **Within 5 minutes of detection**: post in `#bank-alerts` with a
  one-liner: symptom, impact, action taken.
- **Within 15 minutes**: first partner-facing update if any partner
  session is affected. Channel: whichever the partner was
  onboarded into.
- **Every 30 minutes after**: status update until resolved.
- **Within 24 hours of resolution**: a short post-mortem in
  `#bank-alerts` covering:
  - Timeline (detected → diagnosed → recovered).
  - Root cause.
  - Impact (how many partners, how many plans).
  - Fix + follow-up tasks filed.

## Incident log template

Paste this into the incident channel at the top of the thread:

```
INCIDENT <short handle>
  Detected : <UTC timestamp>
  Symptom  : <one line>
  Severity : <page | warn | info>
  Commander: <name>

Timeline
  HH:MM UTC  <event>
  HH:MM UTC  <event>

Impact
  <partners, plans, data>

Root cause
  <one paragraph once known>

Follow-ups
  - <issue>
  - <issue>
```
