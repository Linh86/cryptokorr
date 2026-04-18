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
| Postgres unreachable                                 | [Database outage](#database-outage)                      |

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
  If it cannot, a one-off operator fix is needed — do NOT
  manually force-set `:confirmed`. Instead, abort:
  ```elixir
  Bank.Decisions.abort_plan!(plan_id, reason: "manual_abort_after_incident")
  ```
  and advise the partner to re-submit the intent.
- The `ConfirmExecution` safety-net poller ages stuck plans out to
  `:aborted` after its own timeout; let it run unless the backlog is
  large.

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
      succeeded. (Cryptographic enforcement still requires the
      #84 → #83 → #58 sequence; until then, the on-chain anchor is
      a sentinel UserOp.)
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
- **This sentinel does not cryptographically revoke the delegation
  key at the smart-account level** — that enforcement is tracked in
  #31 and is currently sequenced through three concrete pieces of
  work:
  - **#56 (DECIDED)** — chose Kernel v3 (ERC-7579 modular account)
    with a Permission Validator module installed against it. See
    [docs/smart-account-and-revoke-design.md](smart-account-and-revoke-design.md).
  - **#57 (LANDED, narrowed)** — adapter-side mapping
    (`delegation_id` ↔ `permissionId`), config key
    (`PERMISSION_VALIDATOR_ADDRESS` + strict accessor), and the
    EIP-7579 outer execute envelope. The validator's INNER disable
    ABI was deliberately not pinned without a verified deployment.
  - **#84 (provisioning)** — deploy a Kernel v3 smart account on
    Base + install a Permission Validator against it. Operator
    runbook: [docs/provisioning-kernel-v3.md](provisioning-kernel-v3.md);
    templates under `cryptobank-ts-adapter/scripts/`.
  - **#83 (verification)** — pin the validator's disable ABI
    against a verified deployment (audit / source / on-chain
    bytecode hash). The verify script
    `cryptobank-ts-adapter/scripts/verify-installed-validator.ts`
    emits the bytecode keccak hash that #83 binds as a tripwire
    fixture.
  - **#58 (wiring)** — swap the sentinel inner call for the real
    disable call in `executeRevoke`. Blocked on #84 + #83.

  Until #58 closes, Phoenix's fail-closed posture (delegations
  marked `:revoking`/`:revoke_failed`/`:revoked` are non-executable
  for `RunExecution`) is the only safeguard for the delegation key.
  If the operator cannot get the revoke through and the situation
  is dangerous, the fallback is to **rotate the smart account's
  delegation off chain** — an adapter-side operator procedure that
  lives in the adapter repo.

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
