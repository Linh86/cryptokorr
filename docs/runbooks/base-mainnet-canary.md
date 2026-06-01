# Base mainnet capped canary broadcast — operator runbook

Issue [#181](https://github.com/Linh86/cryptokorr/issues/181) (epic
[#166](https://github.com/Linh86/cryptokorr/issues/166)).

> **Audience.** Operator preparing to run the *first* real Base
> mainnet broadcast on this deployment. The no-broadcast rehearsal
> ([`base-mainnet-rehearsal.md`](base-mainnet-rehearsal.md)) must
> have cleared first.
>
> **Posture.** This runbook walks the operator through the first
> capped, real, on-chain UserOp. **Broadcast actually happens** —
> a real transaction hash will be produced, real gas will be
> spent, and a small amount of real USDC will move on Base
> mainnet. The cap layer in code (`Bank.Chains.CanaryCaps`)
> bounds the loss surface.

## Why this rehearsal exists

The no-broadcast rehearsal (#180) proves the deployment is wired
correctly without touching chain state. The canary takes the next
step: prove the **real** dispatch path works end-to-end on
mainnet, but bound the blast radius so a misconfigured first
broadcast is recoverable.

Two safety layers ride together:

1. **The mainnet eligibility flag** (#178) — workspace
   `mainnet_enabled: true` is a precondition. Without it the
   dispatch worker aborts at `verify_mainnet_allowed/1` with
   `:mainnet_disabled` and never reaches the canary cap.
2. **The capped canary gate** (this issue) — once
   `verify_mainnet_allowed/1` clears, `verify_canary_caps/1`
   bounds the (chain, asset, amount) tuple to a small, fixed
   triple in `Bank.Chains.CanaryCaps`. A plan that exceeds any
   cap is aborted with `final_reason: "canary_<reason>"` and
   `Bank.AdapterClient` is **never** called.

Both gates are layered before the row is claimed for dispatch.
Either one failing closed is sufficient — together they prove no
mainnet UserOp can leave the runtime without an operator-set
workspace flag AND a cap-clean plan.

## What "capped" means here

The v0.1 defaults — defined in
[`lib/bank/chains/canary_caps.ex`](../../lib/bank/chains/canary_caps.ex)
as `default_caps/0` — are:

| Dimension | v0.1 default | Failure atom if violated |
| --- | --- | --- |
| Chain | `["base"]` (Base mainnet only) | `:canary_chain_not_allowed` |
| Asset | `["USDC"]` (no ETH, WETH, other ERC-20s) | `:canary_asset_not_allowed` |
| Per-broadcast amount | `Decimal.new("10.00")` USDC | `:canary_amount_exceeded` |

**Operator overrides.** The cap is configurable via
`config :bank, Bank.Chains.CanaryCaps, ...` so an operator can
relax the defaults for staging or expand the per-broadcast cap
once the canary has cleared. The cap module's moduledoc lists the
override shape; values may be `Decimal.t()`, integer, or
string-encoded numbers (the last so `config/runtime.exs` can read
from env without `Decimal` being available at config compile
time).

**What is NOT capped here.** Cumulative / per-day caps, multi-tx
budgets, or per-counterparty caps are explicitly out of scope for
the v0.1 canary. They need cross-broadcast persistent state and
are tracked as v1.1 follow-ups, not as runbook gaps.

## Pre-canary checklist

Before the operator initiates the canary UserOp, every box below
must be checked. Skipping any of them invalidates the canary
posture; treat the broadcast as a posture violation.

1. **Rehearsal cleared.** The no-broadcast rehearsal in
   [`base-mainnet-rehearsal.md`](base-mainnet-rehearsal.md) has
   been run end-to-end on this deployment with all five steps
   green. Save the rehearsal log timestamp; you will reference it
   in the canary's audit context.
2. **Workspace eligibility.**
   `Bank.Workspaces.set_mainnet_enabled(workspace, true)` has
   been called by an admin on the canary workspace. Confirm:
   ```elixir
   ws = Bank.Workspaces.get_workspace!(workspace_id)
   ws.mainnet_enabled  # => true
   ```
3. **Cap posture.** Confirm the active caps match the v0.1
   defaults (or the operator-approved override):
   ```elixir
   Bank.Chains.CanaryCaps.caps()
   # => %{
   #      allowed_chains: ["base"],
   #      allowed_assets: ["USDC"],
   #      amount_caps: %{"USDC" => Decimal.new("10.00")}
   #    }
   ```
4. **Pause / kill switch off.** The runtime is not globally
   paused and the canary workspace's `(workspace, chain)` scope
   is not paused:
   ```elixir
   Bank.Security.paused?(:global)                         # => false
   Bank.Security.paused?(workspace_id, {:chain, "base"})  # => false
   ```
5. **Smart account funded.** The smart account on Base mainnet
   has at least the canary amount of USDC plus enough native ETH
   for gas. The mainnet preflight (#179) does not gate on amount
   — that's the operator's responsibility.
6. **Adapter health.** `/v1/health/deep` reports
   `adapter.status: ok`. A `:degraded` adapter at canary time
   means the runtime cannot guarantee a clean dispatch round
   trip. Resolve per
   [`docs/runbooks/production-observability.md`](production-observability.md)
   § Adapter / RPC / bundler triage before proceeding.
7. **Operator confirmation.** The operator who will fire the
   canary UserOp has read this runbook, can identify the line
   below where broadcast actually occurs, and accepts that a
   real-money transaction is about to leave the runtime.

If any of the above is `false` or unknown — **stop**. Do not
flip flags or override caps to make the checklist green; resolve
the underlying issue first.

## Where broadcast actually occurs

The canary UserOp leaves the runtime at exactly **one** point in
the dispatch worker:

```
lib/bank/runtime/workers/run_execution.ex
  perform/1
    └── dispatch_and_progress/2
          └── Bank.AdapterClient.dispatch_transfer/1
              # ↑ The HTTP POST to the adapter that initiates
              #   the real on-chain UserOp. Every gate before
              #   this line is a fail-closed boundary; every
              #   line after this is post-broadcast plumbing.
```

The operator's mental model: every `verify_*` step in
`perform/1`'s `with` chain (`load_envelope`, `load_active_plan`,
`verify_delegation`, `verify_not_paused`, `verify_mainnet_allowed`,
`verify_canary_caps`, `claim_or_cancel`) executes against
read-only DB state. Only `dispatch_and_progress/2` after the
claim transitions the plan touches the network. If you read
`{:cancel, atom}` in the worker's return, **no broadcast
occurred**. If you read `:ok`, the adapter's response — and the
on-chain side effect — happened.

## The canary

### Step 1 — Pre-broadcast snapshot

Capture the deployment state for the audit trail:

```sh
mix bank.chain.mainnet.preflight
mix bank.observability.smoke
```

Both must pass. Both are read-only (#179, #257). Save the stdout
to the canary log alongside the workspace id, the smart account
address, and the cap configuration in effect.

### Step 2 — Submit the canary intent

Submit a single `transfer` intent on chain `base`, asset
`USDC`, with amount no larger than the active cap:

```elixir
{:ok, %{intent: intent}} =
  Bank.Intents.submit(
    %{
      "agent_id" => "canary-#{operator_handle}",
      "source" => "user",
      "idempotency_key" => "canary-#{utc_iso8601_now}",
      "kind" => "transfer",
      "asset" => "USDC",
      "chain" => "base",
      "amount" => "5.00",   # under the v0.1 $10 cap
      "target" => %{"counterparty_id" => canary_counterparty_id}
    },
    workspace_id: workspace_id
  )
```

The intent is the audit-trail anchor. Note its `id` —
post-canary verification (Step 5) reads it back.

### Step 3 — Approve and dispatch

Walk the decision through `/queue` exactly as you would any
mainnet intent. The decision pipeline gates on
`mainnet_enabled`, the policy version, the trust assertion, and
the simulator preview — same path every mainnet intent takes.
The canary cap fires at the **dispatch** stage, not the
decision stage; an over-cap intent that gets approved would
still be aborted by the dispatch worker before it reaches the
adapter.

### Step 4 — Observe broadcast

Tail the dispatch worker's audit events for the intent id:

```elixir
Bank.Audit
|> import_query(...)
|> where(correlation_id: ^intent.id)
|> order_by(asc: :inserted_at)
|> Bank.Repo.all()
```

Expected sequence (per `Bank.Audit.Events.execution_transition/2`
and the dispatch worker's side-effect helpers):

1. `execution.signing` — plan moved `:prepared → :signing`
   immediately before the adapter call. **Broadcast has now
   occurred.** This is the irreversible point.
2. `execution.broadcasting` — adapter callback reports the user
   op hash.
3. `execution.pending_confirmation` — adapter callback reports
   the tx hash.
4. `execution.confirmed` — adapter callback reports block
   number and final outcome.

If you see `execution.aborted` instead of `execution.signing`,
the canary did **not** broadcast. Read `final_reason` to find
out which gate fired:

  * `mainnet_disabled` — workspace flag flipped off mid-flight.
  * `canary_chain_not_allowed`, `canary_asset_not_allowed`,
    `canary_amount_exceeded` — canary cap rejected the plan.
  * `runtime_paused`, `chain_paused` — pause kicked in.
  * `delegation_not_active` — delegation race.
  * `adapter_rejected:<status>:<summary>` — adapter rejected at
    the wire.

### Step 5 — Post-canary public artifacts

After `execution.confirmed`, gather and record the **public
artifact set** required by issue #181:

```elixir
plan = Bank.Repo.get!(Bank.Decisions.ExecutionPlan, plan_id)
intent = Bank.Repo.get!(Bank.Intents.AgentIntent, plan.intent_id)

%{
  workspace_id: plan.workspace_id,
  smart_account_id: plan.smart_account_id,
  intent_id: intent.id,
  user_op_hash: Enum.find(plan.tx_refs, &userop_hash?/1),
  tx_hash: Enum.find(plan.tx_refs, &tx_hash?/1),
  block_number: extract_block_number(plan)
}
```

`tx_refs` is a `{:array, :string}` field on
`Bank.Decisions.ExecutionPlan`; the adapter populates it via
callbacks. The shape is documented in the
`Bank.Decisions.ExecutionPlan` moduledoc:

> `tx_refs` is a plain text array, not an FK array, since
> references are per-chain strings (tx hashes, user-op hashes,
> internal adapter ids) that aren't uniform enough to
> foreign-key.

Cross-check against the on-chain explorer (Basescan):

  * Tx hash → block number, gas used, status `success`.
  * User op hash → ERC-4337 entrypoint logs, sender ==
    `smart_account_id` address.
  * Amount transferred matches `intent.amount` and asset.

Append the artifact set to the canary log alongside the Step 1
preflight output. This **is** the canary's audit trail; the
runtime emits the matching `execution.*` events to the audit
table for replay.

### Step 6 — Sign-off

Only after Steps 1–5 are complete and verified does the canary
count as cleared. The next step, capped or uncapped, is a
deliberate operator decision, not an implicit consequence of the
canary clearing.

## Failure modes and next operator action

| Failure | Symptom | Next operator action |
| --- | --- | --- |
| `canary_chain_not_allowed` | Plan aborted; `final_reason: "canary_chain_not_allowed"` | Chain is mainnet but not in `Bank.Chains.CanaryCaps.caps().allowed_chains`. The v0.1 default ships `["base"]`. If the canary intentionally targets another mainnet chain, add it to the operator-approved override **before** the next attempt; do not work around by submitting via a different surface. |
| `canary_asset_not_allowed` | Plan aborted; `final_reason: "canary_asset_not_allowed"` | Asset is not in `allowed_assets` (v0.1: `["USDC"]`). Confirm the intent is on USDC; if a different asset is intended, expand the allowlist via config and re-test the rehearsal first. |
| `canary_amount_exceeded` | Plan aborted; `final_reason: "canary_amount_exceeded"` | Intent amount > per-asset cap (v0.1: `$10.00` USDC). Either resubmit a smaller intent or raise the cap via `config :bank, Bank.Chains.CanaryCaps, amount_caps: %{...}` — the latter requires re-running the rehearsal (#180) and updating the canary log. |
| `mainnet_disabled` | Plan aborted; `final_reason: "mainnet_disabled"` | Workspace flag flipped off mid-flight. Audit who flipped the flag (`workspace.mainnet_enabled.set` event), confirm the rehearsal posture is still valid, and re-flip only after the cause is understood. |
| `runtime_paused` / `chain_paused` | Plan aborted; `final_reason: "runtime_paused"` or `"chain_paused"` | Pause is on. Resolve the underlying incident per [`docs/incident-runbook.md`](../incident-runbook.md) § Emergency pause first. **Never** silently resume to unblock the canary. |
| `adapter_rejected:<status>:<summary>` | Plan aborted; `final_reason: "adapter_rejected:..."` | Adapter rejected at the HTTP layer. The summary names the failure mode (`unsupported_chain`, `invalid_signature`, etc.). Treat as a deployment-config bug; investigate adapter logs and re-run the rehearsal before retry. |
| `delegation_not_active` | Plan aborted; `final_reason: "delegation_not_active"` | The smart account's delegation was revoked between plan creation and dispatch. Re-grant the delegation via the standard onboarding flow; do not work around. |
| Unexpected tx hash with NO matching `execution.*` audit events | Tx hash visible on Basescan but no audit row | **STOP.** Pause the runtime via `Bank.Security.pause(:global, "canary_audit_drift", actor: :operator, actor_id: <id>)` and treat as an incident. The dispatch path's audit invariant has been violated. Follow [`docs/incident-runbook.md`](../incident-runbook.md) § Stuck executions and § Missing confirmation. |
| Adapter returns `:ok` but plan stays `:signing` past the threshold | Plan stuck; `/v1/health/deep` reports `stuck_plans.status: degraded` | Callback path failed. Follow [`docs/incident-runbook.md`](../incident-runbook.md) § Missing confirmation; do not re-broadcast — that risks double execution. |
| Operator initiates canary outside the rehearsal posture (rehearsal not run, or rehearsal not green) | n/a | Cancel the operator action. Re-run the rehearsal. The canary's safety properties depend on the rehearsal having cleared; running canary against an unrehearsed deployment is a rollout error, not a runtime error. |

## Pause / rollback

The canary's rollback path is **the same as any mainnet
incident**:

1. **Pause.** `Bank.Security.pause(:global, reason, actor: ...,
   actor_id: ...)` halts every dispatch worker. Subsequent
   plans abort at `verify_not_paused/1` with
   `final_reason: "runtime_paused"`. Existing in-flight
   broadcasts are not cancelled (the chain has already accepted
   them); they continue to lifecycle through callbacks.
2. **Revoke.** If the canary delegation is still active and you
   want to remove the smart account's authority entirely, fire
   `Bank.Security.revoke_delegation/1` for the canary smart
   account. The revoke goes through its own dispatch worker
   (`Bank.Runtime.Workers.RevokeDelegation`), gated identically
   on the mainnet flag. A revoke during the canary window is
   itself a chain action and pays gas.
3. **Disable mainnet eligibility.**
   `Bank.Workspaces.set_mainnet_enabled(workspace, false)` on
   the canary workspace closes the gate at every layer of the
   pipeline. New mainnet intents will fail closed at submit
   with `:mainnet_disabled`.
4. **Flip the cap to zero.** As a defensive measure, an
   operator can set
   `config :bank, Bank.Chains.CanaryCaps, amount_caps: %{}` (an
   empty map). Every mainnet plan then aborts at the cap layer
   with `:canary_amount_exceeded` because the asset key is
   missing.

The runbook is **not** the recovery procedure for any
post-broadcast incident; the recovery procedures live in
[`docs/incident-runbook.md`](../incident-runbook.md). This
section names the buttons the operator can press to bound the
incident; the recovery procedure is named per failure mode
upstream.

## Public artifact recording

Per #181 acceptance: every completed canary records the
following artifact set, sourced from the runtime's existing
data model. **No new schema** — the artifacts are derived from
columns that already exist post-#178.

| Artifact | Source column | Notes |
| --- | --- | --- |
| User op hash | `Bank.Decisions.ExecutionPlan.tx_refs` | Adapter populates via the `dispatch_transfer` callback. May be one of multiple entries; identify by 0x-prefix length (`0x[64 hex]`). |
| Tx hash | `Bank.Decisions.ExecutionPlan.tx_refs` | Adapter populates via the `confirm` callback. Same shape as user op hash; distinguishable by the adapter's callback contract. |
| Block number | Adapter callback metadata | Not stored as a first-class column; derived from the explorer at audit time. The runtime trusts the adapter's confirm callback for state but does not persist the block number. |
| Smart account | `Bank.Decisions.ExecutionPlan.smart_account_id` | The runtime smart account id; the on-chain address is derivable via `Bank.Delegations.lookup/1`. |
| Workspace id | `Bank.Decisions.ExecutionPlan.workspace_id` | UUID; matches `intent.workspace_id`. |
| Intent id | `Bank.Decisions.ExecutionPlan.intent_id` | The operator's audit-trail anchor — `intent.idempotency_key` ties the canary back to the operator handle that submitted it. |

The full artifact set is recorded in the canary log (a markdown
file the operator maintains alongside this runbook); the
runtime's `audit_events` and `execution_plans` tables are the
load-bearing source. Do **not** add fields to the schema for
canary-specific bookkeeping; the existing replay path is
sufficient.

## Cross-links

- [`docs/runbooks/base-mainnet-go-no-go.md`](base-mainnet-go-no-go.md) —
  formal closure review for epic #166. The cap values referenced
  in row 5 of the go/no-go checklist are the same ones enforced
  in `Bank.Chains.CanaryCaps` and named below.
- [`docs/runbooks/base-mainnet-rehearsal.md`](base-mainnet-rehearsal.md) —
  no-broadcast rehearsal (#180). **Must** clear before this
  runbook is invoked.
- [`docs/runbooks/production-observability.md`](production-observability.md) —
  daily operator triage; § Base mainnet feature gate (#178) and
  § Base mainnet preflight (#179).
- [`docs/incident-runbook.md`](../incident-runbook.md) —
  § Emergency pause, § Adapter outage, § Stuck executions,
  § Missing confirmation. Recovery procedures during or after a
  canary incident.
- [`docs/operator-secrets-checklist.md`](../operator-secrets-checklist.md) —
  env var / secret provisioning checklist.
- `Bank.Chains.CanaryCaps` moduledoc.
- `Bank.Runtime.Workers.RunExecution` moduledoc — the dispatch
  worker, including the full `with`-chain ordering of pre-dispatch
  gates.
- [`test/bank/chains/canary_caps_test.exs`](../../test/bank/chains/canary_caps_test.exs) —
  unit-level pin of the cap allowlist and failure atoms.
- [`test/bank/runtime/workers/run_execution_canary_caps_test.exs`](../../test/bank/runtime/workers/run_execution_canary_caps_test.exs) —
  defense-in-depth integration pin: cap-violating plans abort
  before any `Bank.AdapterClient` call leaves the test process.

## Related issues

- [#166](https://github.com/Linh86/cryptokorr/issues/166) — epic.
- [#178](https://github.com/Linh86/cryptokorr/issues/178) —
  workspace `mainnet_enabled` flag.
- [#179](https://github.com/Linh86/cryptokorr/issues/179) —
  read-only mainnet preflight.
- [#180](https://github.com/Linh86/cryptokorr/issues/180) —
  no-broadcast rehearsal runbook (prerequisite).
- [#181](https://github.com/Linh86/cryptokorr/issues/181) — this
  runbook + the cap module.
- [#182](https://github.com/Linh86/cryptokorr/issues/182) —
  mainnet go/no-go review (the canary's clean-run record is one
  of #182's inputs).
