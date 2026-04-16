# Phoenix ↔ TS Adapter Contract (v0.1)

## Status (issue #30)

The transfer dispatch path is **wired end-to-end** on Base + USDC:

- Phoenix-side outbound dispatch: `Bank.AdapterClient.dispatch_transfer/1`
  (POSTs `/dispatch/transfer`, maps HTTP outcomes to typed errors).
- Worker: `Bank.Runtime.Workers.RunExecution` calls the client, advances
  the plan `:prepared` → `:signing` and the intent `:decided` →
  `:executing` on HTTP 202, aborts on 4xx / unresolvable target /
  revoked delegation, retries on 5xx and transport errors.
- Inbound callbacks: `POST /internal/adapter/callback` routes through
  `Bank.Decisions.apply_execution_callback/1`, which updates plan + owning
  intent atomically. `Bank.Runtime.Workers.ConfirmExecution` stays as a
  safety-net poller.
- Adapter-side: `src/chains/base/transfer.ts` emits
  `execution.broadcast` → `execution.confirmed` (or `.reverted` /
  `.aborted`) on every tx.

Still deferred (explicitly out of scope for #30): swap execution, any
staging or production deploy pipeline.

## Status (issue #31)

On-chain delegation revoke is wired end-to-end:

- Phoenix-side outbound dispatch:
  `Bank.AdapterClient.dispatch_revoke_delegation/1` (POSTs
  `/dispatch/revoke_delegation`, same typed error surface as transfer).
- Worker: `Bank.Runtime.Workers.RevokeDelegation` emits the security
  broadcast + `security.revoke_requested` audit, then dispatches. It
  retries on transport + 5xx, cancels on 4xx and invalid responses.
- Inbound `delegation.state_changed` callbacks already flow through
  `Bank.Delegations.apply_callback/1` (unchanged from v0.1). The
  adapter is expected to emit `revoking` then `revoked` for a revoke
  request; Phoenix keeps the `:granted → :revoking → :revoked`
  lifecycle visible on the control tower through those callbacks.
- Fail-closed posture is preserved: until the adapter confirms
  `revoked`, policy evaluation keeps treating the delegation as
  in-flight (operator-visible) rather than assuming revoke completed.

## Status (issue #32)

Base execution assumes **ERC-4337 account abstraction** (EntryPoint
v0.7+). Phoenix no longer speaks EOA transactions on Base: the adapter
assembles a UserOperation, signs it against the active delegation,
submits through a bundler, and reports progress through the same
callback kinds used for EOA flow.

**In-repo scope for #32 is the contract + data model.** The bundler /
EntryPoint / paymaster integration itself lives in the TypeScript
adapter (separate repo / service) and is tracked there.

### Lifecycle mapping

| Chain-level event                  | Phoenix callback kind  | `tx_refs` shape                         |
| ---------------------------------- | ---------------------- | --------------------------------------- |
| Bundler accepted userop            | `execution.broadcast`  | `[{chain, userop_hash, nonce, bundler}]`|
| Userop included, call succeeded    | `execution.confirmed`  | adds final tx hash                      |
| Userop included, call reverted     | `execution.reverted`   | adds final tx hash + revert reason      |
| Pre-submission denial              | `execution.aborted`    | empty or `[{stage, reason}]`            |

Phoenix's `%ExecutionPlan{tx_refs: [text]}` already accepts
per-chain-string references (see `execution_plan.ex` module doc) —
userop hashes, final tx hashes, or bundler ids all coexist.

### Pre-submission denial taxonomy (`execution.aborted` reasons)

The adapter MUST report one of the following `reason` values so
Phoenix can distinguish operator-facing incidents from chain-level
failures. Matches the enum already used by
`Bank.Decisions.apply_execution_callback/1`:

- `bundler_rejected` — bundler refused the userop (sim failure,
  insufficient prefund, invalid signature).
- `paymaster_denied` — sponsored flow denied by the paymaster policy.
- `delegation_revoked` — signing refused because the active delegation
  is no longer `granted`. Adapter MUST emit `delegation.state_changed`
  after the abort.
- `operator_paused` — runtime pause detected pre-submission.
- `replaced` — a prior userop with the same sender+nonce was mined
  first (typically an operator-driven replacement). Phoenix stops
  waiting on the original plan.
- `timeout` — submission attempt exceeded the adapter's bundler
  timeout; Phoenix may re-dispatch a fresh plan after operator review.

### `signing_requirements` (AA conventions)

`signing_requirements` remains opaque to Phoenix. Conventionally, for
Base AA flow the adapter expects:

```jsonc
{
  "delegation_id": "del_...",           // required
  "scope": { /* per-delegation policy */ },
  "entry_point": "0x...EntryPointV0_7", // optional; adapter default OK
  "nonce_key": "0x00...",               // optional; AA key-of-key
  "sponsor": "self" | "paymaster"       // optional; default self
}
```

Phoenix always sets `delegation_id` + `scope`. The rest is forwarded
from `Bank.Delegations.scope` if present; the adapter resolves
defaults otherwise.

### Failure-mode recovery stance

- **Bundler down / timeout** — retryable by the worker (counts as 5xx
  equivalent). The adapter SHOULD surface HTTP 503 on dispatch when
  its configured bundler is unreachable so Phoenix retries with
  backoff, rather than accepting the dispatch and aborting later.
- **Paymaster denial** — deterministic. The adapter returns HTTP 422
  on dispatch (no plan state change) or emits `execution.aborted`
  with `reason=paymaster_denied` post-accept. Phoenix fails closed;
  operator must re-price or switch sponsor.
- **Userop replacement** — if an operator (outside Phoenix) replaces
  a stuck userop, the adapter MUST emit `execution.aborted` with
  `reason=replaced` so Phoenix stops polling on the old plan.
- **Validation-time revert (entryPoint.validateUserOp)** — treated
  identically to `bundler_rejected`: the userop never existed on
  chain.

## Service boundary

The TS adapter owns:
- Chain-specific calldata assembly (Base, USDC-first).
- Smart-account delegation mechanics (signing, granting, revoking).
- Bundler / RPC interaction, including confirmation polling on-chain.

The Phoenix control plane owns:
- Intent lifecycle, policy evaluation, decision envelopes, approvals.
- Audit trail and operator UI.
- All `/v1/` external API surface.

**The adapter never writes directly to Phoenix persistence.** It
receives work items and posts callbacks. Phoenix is the system of
record for everything except live chain state.

## Transport

JSON over HTTPS, mutually authenticated (mTLS in production, shared
bearer secret in dev). No public internet exposure — the adapter and
Phoenix coexist on a private network.

Phoenix → Adapter: `POST {adapter_base}/dispatch/{action}`
Adapter → Phoenix: `POST {phoenix_base}/internal/adapter/callback`
(behind private auth, not `/v1/`).

All timestamps are RFC3339 UTC (`2026-04-15T20:00:00Z`).

## Work items (Phoenix → Adapter)

### `transfer`

Corresponds to `%Bank.Intents.AgentIntent{kind: :transfer}` after a
`:auto_exec` envelope. See `fixtures/dispatch_transfer.json`.

```jsonc
{
  "action": "transfer",
  "execution_plan_id": "uuid",          // joins back on callback
  "intent_id": "uuid",
  "smart_account_id": "sa_...",
  "chain": "base",
  "asset": "USDC",
  "amount": "50",                        // decimal string, base units
  "target": {
    "address": "0x...",
    "counterparty_id": "uuid|null"       // null for raw address
  },
  "signing_requirements": {
    "delegation_id": "del_...",
    "scope": { /* opaque to Phoenix */ }
  },
  "correlation_id": "uuid"               // always = intent_id in v0.1
}
```

### `swap`

Whitelisted swap, same skeleton plus `expected_output` and
`slippage_bps` — see `fixtures/dispatch_swap.json`.

### `revoke_delegation`

Matches the `Bank.Runtime.Workers.RevokeDelegation` job.
See `fixtures/dispatch_revoke_delegation.json`.

```jsonc
{
  "action": "revoke_delegation",
  "smart_account_id": "sa_...",
  "reason": "operator_requested",
  "correlation_id": null                 // runtime-scoped
}
```

## Callbacks (Adapter → Phoenix)

Every callback carries:

- `execution_plan_id` OR `smart_account_id` (one of the two).
- `callback_id` — monotonic per adapter process; used to dedupe.
- `emitted_at` — adapter wall clock.

### `execution.broadcast`

A transaction has been broadcast. Phoenix moves the plan to
`broadcast` and enqueues `Bank.Runtime.enqueue_confirmation/2`.
Fixture: `fixtures/callback_execution_broadcast.json`.

### `execution.confirmed`

Transaction is final. Phoenix writes `execution.confirmed` audit and
the execution plan reaches `completed`.
Fixture: `fixtures/callback_execution_confirmed.json`.

### `execution.reverted`

Transaction broadcast but reverted (chain-level). Phoenix writes
`execution.reverted` and the plan reaches `failed`.
Fixture: `fixtures/callback_execution_reverted.json`.

### `execution.aborted`

Pre-broadcast refusal (signing refused, delegation revoked, operator
pause). No tx hash is required.
Fixture: `fixtures/callback_execution_aborted.json`.

### `delegation.state_changed`

One of `granted | revoking | revoked | expired`. Phoenix updates
`Bank.Delegations` and appends audit.
Fixture: `fixtures/callback_delegation_state_changed.json`.

## Failure-safe posture

Per `docs/bank-v0.1-runtime-flow-and-api.md §4`:

- **Adapter unreachable for dispatch**: Phoenix degrades toward
  `:hold` (not block) via `Bank.Autonomy` — the intent can resume
  when the adapter recovers.
- **Confirmation poll times out**: the `ConfirmExecution` worker
  snoozes; operators see the pending state on the dashboard.
- **Callback with unknown `execution_plan_id`**: Phoenix logs and
  discards. Adapter is expected to dedupe on its end.
- **Revoke requested while an execution is in flight**: the adapter
  MUST abort the execution before processing the revoke, and emit
  `execution.aborted` followed by `delegation.state_changed`.

## Versioning

The contract lives in-repo under `priv/adapter/`. Breaking changes
bump a top-level `contract_version` field in both directions
(currently `1`). The adapter is expected to advertise its supported
versions at startup.
