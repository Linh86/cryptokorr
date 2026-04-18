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

**Issue #31 is NOT closed.** A true contract-level delegation revoke
requires the smart-account permission module from #32, which is not
wired in this repo. The work under #31 improves the revoke plumbing
and state model so Phoenix stays truthful while the real primitive is
missing, but does not provide cryptographic revocation.

The adapter submits a **sentinel self-transfer of 0 wei** on Base.
The sentinel is NOT a cryptographic revocation — it is a real
on-chain tx that anchors the revoke attempt in a block with a real
hash, real confirmations, and real failure modes (send error,
confirmation timeout, revert), exercising the same plumbing the
permission-module revoke will use. The delegation key can still sign
another userop until #32 lands; Phoenix enforces fail-closed on its
side for the entire window.

What landed under #31:

- Phoenix-side outbound dispatch:
  `Bank.AdapterClient.dispatch_revoke_delegation/1` (POSTs
  `/dispatch/revoke_delegation`, same typed error surface as transfer).
- Worker: `Bank.Runtime.Workers.RevokeDelegation` emits the security
  broadcast + `security.revoke_requested` audit, then dispatches. It
  retries on transport + 5xx, cancels on 4xx and invalid responses.
- Adapter execution (`src/chains/base/revoke.ts`): submits a 0-wei
  self-transfer via `walletClient.sendTransaction` and waits for
  receipt via `publicClient.waitForTransactionReceipt`. Emits
  `delegation.state_changed` twice — `revoking` on accept, then a
  terminal callback on resolution:
    * `revoked` with `tx_refs: [{chain, hash, block_number, status}]`
      on confirmed success. ONLY the confirmed-success path emits
      `revoked`.
    * `revoke_failed` with a diagnostic `reason` (`send_failed: …`,
      `confirmation_failed: …`, `sentinel_reverted`) on any
      chain-level failure. The adapter does NOT conflate failure with
      success.
- Adapter idempotency: an in-memory `inFlight: Set<smart_account_id>`
  suppresses duplicate on-chain sends while one is pending; a
  duplicate dispatch re-emits `revoking` and returns 202 without
  re-submitting the tx.
- Inbound `delegation.state_changed` callbacks flow through
  `Bank.Delegations.apply_callback/1`, which extracts the tx hash
  from `tx_refs` into `delegations.last_tx_hash` and records
  `last_reason`. The full lifecycle is:

      :granted → :revoking → :revoked              (success)
      :granted → :revoking → :revoke_failed         (any failure)
      :revoke_failed → :revoking → :revoked         (operator retry)

  `:revoke_failed` is a non-terminal state — the on-chain delegation
  is still live — so the row stays visible to `Bank.Delegations.get/1`,
  continues to occupy the per-smart-account uniqueness slot (a fresh
  grant is refused until the prior row reaches `:revoked` or
  `:expired`), and stays non-executable.
- Operator retry: `Bank.Security.revoke_delegation/2` can be invoked
  again from `:revoke_failed`; `record_revoke_requested/2` accepts
  `:revoke_failed` as a prior state so the adapter retries the revoke.
- Fail-closed posture: `Bank.Delegations.executable?/1` returns
  `false` for `:revoking`, `:revoke_failed`, `:revoked`, and
  `:expired`, so `Bank.Runtime.Workers.RunExecution` refuses to
  dispatch transfers from the moment `record_revoke_requested` runs
  — before the adapter has broadcast the sentinel — and stays
  fail-closed through the confirmation window and through any
  number of failed retries.
- Duplicate terminal callbacks (Oban retry + adapter retry) are
  benign: the second call finds no non-terminal row, returns
  `:not_found`, and the controller maps it to `accepted_with_warning`.

**What changed under #32 (does NOT close #31):**

- ERC-4337 / bundler integration landed in the adapter. The revoke
  path now routes through the same AA pipeline as transfers — inner
  call is `SimpleAccount.execute(self, 0, 0x)`, a sentinel self-call
  with zero value and zero calldata. Callback shape is now identical
  between transfer and revoke (both carry `userop_hash`, `nonce`,
  `bundler`, and — on confirmed — the chain-level `hash` and
  `block_number`).
- The full failure taxonomy (`userop_build_failed`, `bundler_rejected`,
  `confirmation_failed`, `sentinel_reverted`) is now exercised
  end-to-end on the same plumbing a real permission-module revoke
  will use.

**Still deferred (blocker for closing #31):**

- Cryptographic revocation at the smart-account level. The sentinel
  user-op does not prevent the delegation key from signing another
  user-op — there is no permission-module ABI to call. When that
  module ships, the only adapter-side change is the inner calldata:
  swap `execute(self, 0, 0x)` for
  `execute(permissionModule, 0, revokeSignature(delegationId))`.
  Phoenix's callback contract and state machine do NOT need to
  change.
- Phoenix continues to treat `revoked` (via the sentinel path) as
  "on-chain anchored, trust downgraded", NOT as "cryptographically
  impossible". Fail-closed posture is unchanged until #31 closes.

## Status (issue #32)

Base execution uses **ERC-4337 account abstraction v0.7** (EntryPoint
`0x0000000071727De22E5E9d8BAf0edAc6f37da032`). The adapter assembles
a UserOperation whose inner call is
`SimpleAccount.execute(target, value, data)`, signs the canonical
v0.7 user-op hash with the active delegation key, and submits
through a configured bundler. Phoenix does not speak EOA
transactions on Base — every Base execution (transfer, sentinel
revoke) flows through the same AA pipeline and surfaces the same
callback kinds.

**Adapter-side AA plumbing has landed** (`src/chains/base/userop.ts`
+ `src/chains/base/bundler.ts` + `src/chains/base/entrypoint.ts`).
Paymaster / sponsored flow is not wired (self-funded only in v0.1);
the paymaster denial path remains part of the contract for when
sponsored flow ships, but no code emits it yet.

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

**Field names and shapes:**

- `userop_hash` — EntryPoint v0.7 canonical user-op hash (32-byte hex).
- `hash` — on-chain transaction hash returned by the bundler receipt.
  Present on `execution.confirmed` / `execution.reverted`, and on
  `revoke_failed` when the user-op made it on chain but reverted.
- `nonce` — hex-string serialization of the v0.7 2D nonce (e.g.
  `"0x7"`). It is a full 256-bit value and therefore does NOT fit
  the `execution_plans.nonce :: :integer` column; Phoenix leaves
  that column nil and relies on `tx_refs` for nonce fidelity on the
  AA path. On the EOA path (non-Base chains, future work), the
  column is still populated from an integer nonce.
- `bundler` — opaque non-secret label identifying the bundler
  provider (e.g. `"base-v07-bundler"`). The bundler RPC URL itself
  may contain API keys, so it is never emitted directly.
- `status` — `"success" | "reverted" | "unknown"`; `"unknown"` when
  the bundler accepted the user-op but Phoenix could not confirm
  inclusion (confirmation timeout).

### Pre-submission denial taxonomy (`execution.aborted` reasons)

The adapter MUST report one of the following `reason` values so
Phoenix can distinguish operator-facing incidents from chain-level
failures. Matches the enum already used by
`Bank.Decisions.apply_execution_callback/1`:

- `userop_build_failed` — UserOperation construction or signing
  raised before submission (e.g. nonce read failed, gas estimation
  failed, signer rejected). `tx_refs` is empty.
- `bundler_rejected` — bundler refused the userop (sim failure,
  insufficient prefund, invalid signature).
- `bundler_hash_mismatch` — the bundler accepted the user-op but
  returned a hash that disagrees with the locally computed canonical
  EIP-4337 hash. Treated as a contract / infrastructure error
  (buggy bundler, MITM proxy, or chain-id divergence). The adapter
  fails closed before emitting `execution.broadcast` so Phoenix
  never anchors a misleading user-op hash. `tx_refs` is empty;
  the `reason` includes both hashes for the operator.
- `paymaster_denied` — sponsored flow denied by the paymaster policy.
  (Paymaster support itself is not yet wired in v0.1; reserved for
  when sponsored flow lands.)
- `delegation_revoked` — signing refused because the active delegation
  is no longer `granted`. Adapter MUST emit `delegation.state_changed`
  after the abort.
- `operator_paused` — runtime pause detected pre-submission.
- `replaced` — a prior userop with the same sender+nonce was mined
  first (typically an operator-driven replacement). Phoenix stops
  waiting on the original plan.
- `confirmation_failed: <detail>` — bundler accepted the user-op but
  `waitForUserOperationReceipt` timed out or errored. `tx_refs`
  carries the `userop_hash` with `status: "unknown"` so operators
  can look up the user-op out-of-band.
- `timeout` — submission attempt exceeded the adapter's bundler
  timeout; Phoenix may re-dispatch a fresh plan after operator review.

### Revoke failure taxonomy (`revoke_failed` reasons)

The sentinel revoke path emits `delegation.state_changed` with
`state=revoke_failed` on any failure branch, carrying a diagnostic
`reason` prefix that mirrors the transfer taxonomy:

- `userop_build_failed: <detail>`
- `bundler_rejected: <detail>`
- `bundler_hash_mismatch: <detail>` — same semantics as the
  transfer path: locally computed user-op hash diverged from the
  bundler-returned hash; adapter aborts before emitting any other
  callback. `tx_refs` is empty.
- `confirmation_failed: <detail>` — `tx_refs` carries
  `userop_hash` with `status: "unknown"`.
- `sentinel_reverted` (or the bundler-reported revert reason) — the
  user-op made it on chain but reverted. `tx_refs` carries both
  `userop_hash` and `hash` with `status: "reverted"`.

Phoenix treats `revoke_failed` as non-terminal, non-executable, and
retryable. The adapter MUST NOT emit `revoked` on any failure path.

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

JSON over HTTP(S). No public internet exposure — the adapter and
Phoenix coexist on a private network. Transport encryption (TLS / mTLS)
is operator-supplied at the ingress; both sides accept either `http://`
or `https://` for their counterpart's base URL.

Each direction is authenticated at the application layer with a
distinct bearer secret, so each rotates independently and a leak in
one direction does not authenticate the other:

| Direction              | Bearer header (set by sender, validated by receiver) | Env var (both services) |
| ---------------------- | ---------------------------------------------------- | ----------------------- |
| Phoenix → Adapter      | `Authorization: Bearer <ADAPTER_DISPATCH_SECRET>`    | `ADAPTER_DISPATCH_SECRET` |
| Adapter → Phoenix      | `Authorization: Bearer <ADAPTER_CALLBACK_SECRET>`    | `ADAPTER_CALLBACK_SECRET` |

Missing, malformed, or wrong bearer is rejected with `401` and the
body `{"error": {"code": "missing_authorization" | "invalid_authorization_scheme" | "invalid_credentials"}}`.
The bearer comparison is constant-time on both sides.

The adapter's `GET /health` deliberately stays public so liveness
probes do not need credentials.

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

One of `granted | revoking | revoke_failed | revoked | expired`.
Phoenix updates `Bank.Delegations` and appends audit.

Semantics of the failure state:

- `revoked` means the revoke **succeeded** on-chain. Phoenix requires
  a prior `revoking` transition — a direct `active → revoked` is
  refused as `:invalid_transition`.
- `revoke_failed` means the adapter attempted the revoke and could
  not complete it (send rejected, confirmation timeout, sentinel
  reverted). The on-chain delegation is still live; Phoenix stays
  fail-closed and the operator must retry.

The adapter MUST NOT emit `revoked` on a failure path.

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
