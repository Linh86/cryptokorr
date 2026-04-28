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
is blocked on three concrete missing artifacts — see the **Still
deferred** subsection below for the exact list. The work under #31
keeps the revoke plumbing and state model truthful while those are
missing; it does NOT provide cryptographic revocation.

The adapter submits a **sentinel self-transfer of 0 wei** on Base.
The sentinel is NOT a cryptographic revocation — it is a real
on-chain tx that anchors the revoke attempt in a block with a real
hash, real confirmations, and real failure modes (send error,
confirmation timeout, revert), exercising the same plumbing the
permission-module revoke will use. The delegation key can still sign
another userop until those three missing artifacts land; Phoenix enforces fail-closed on its
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

Cryptographic revocation at the smart-account level. The sentinel
user-op does not prevent the delegation key from signing another
user-op. The architectural decision behind a real revoke is captured
in [`docs/smart-account-and-revoke-design.md`](../../docs/smart-account-and-revoke-design.md)
(GitHub #56): a **Kernel v3 (ERC-7579) modular account on Base**.
The shape of the cryptographic revoke (which signer + policy
modules, what `delegation_id` carries on the wire, whether revoke
is per-permission via `Kernel.uninstallValidation` or coarser via
`Kernel.invalidateNonce`) is deferred to the ZeroDev SDK
integration tracked in
[`docs/zerodev-permissions-integration.md`](../../docs/zerodev-permissions-integration.md).

What is verifiable today:

- **#56 — DECIDED.** Kernel v3 smart-account host. Independent of
  the permission-system layer above it.
- **#57 — narrowed.** The ERC-7579 outer envelope is pinned in
  [`cryptobank-ts-adapter/src/chains/base/erc7579.ts`](../../chain_adapter/src/chains/base/erc7579.ts)
  against EIP-7579's normative `execute(bytes32, bytes)` signature
  (selector `0xe9ae5c53`), all-zeros single-call ModeCode, packed
  body layout. Earlier scaffolding (a `delegation_id ↔ bytes32
  permissionId` mapping, a `PERMISSION_VALIDATOR_ADDRESS` env, a
  `requirePermissionValidatorAddress` accessor, a fixture pinning
  the 66-char convention) was removed as an artefact of a
  wrong-model assumption — see the integration doc.
- **#84 — closed on Base Sepolia.** Operator runbook is in
  [`docs/provisioning-kernel-v3.md`](../../docs/provisioning-kernel-v3.md);
  scripts `provision-kernel.ts` and `verify-installed-validator.ts`
  are real, no-secret-safe templates targeting Kernel v3.1. A
  smart account was deployed at
  `0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C` on chain 84532;
  deploy tx
  `0xe6ad5263ed7023ee6b5f7dd2c529efda27ccb4cebce449c52a58a882c9fe4724`.
- **#83 — landed.** Was "pin the validator's disable ABI
  fragment". Re-scoped to "populate `KernelPermissionPin` against
  ZeroDev's actual primitives". The slot is populated with the
  ECDSA signer + six modern policy modules from
  `@zerodev/permissions@5.6.3` and the
  `uninstallValidation(bytes21,bytes,bytes)` ABI fragment from
  `KernelV3_1AccountAbi`; the
  `permission-validator-pin.test.ts` tripwire imports the same
  package values and asserts equality.
- **#58 — open.** The swap target is `Kernel.uninstallValidation`
  ON the smart account itself, signed by a sudo signer the adapter
  does not yet hold. There is no separate validator address to
  call into. Hard-blocker list (SDK runtime deps, per-account sudo
  signer, bundler/paymaster, plugin-blob persistence, pin shape,
  on-the-wire `delegation_id` encoding) is documented in the
  integration doc.

When #58 lands, the change is to the revoke `callData` only — both
the OUTER envelope (SimpleAccount → ERC-7579) AND the INNER body
(no-op self-call → kernel-account `uninstallValidation` call)
swap. Phoenix's callback contract and state machine do NOT need
to change. The adapter's tripwire test
(`test/base-revoke-sentinel-pin.test.ts`) will fail loudly the
moment the inner call shape changes, forcing whoever makes the
change to also update this contract, the runbook, and close #31.

### `delegation_id` semantics

Phoenix stores `delegations.delegation_id` as an opaque string
column. The on-the-wire encoding is deferred to the ZeroDev SDK
integration described in
[`docs/zerodev-permissions-integration.md`](../../docs/zerodev-permissions-integration.md);
the eventual value is one of: a 4-byte ZeroDev `permissionId`
(10 hex chars), a 21-byte Kernel `validationId` (44 hex chars),
or a serialized plugin blob. An earlier revision of this section
claimed the value was a 66-char `bytes32 permissionId` derived
from a single Permission Validator contract — that was a
wrong-model assumption (see the integration doc).

Pre-integration sentinel-era grants continue to use legacy
`del_…` placeholder ids. The adapter accepts and echoes any
non-empty string; no format-validation helpers run today.

Phoenix continues to treat `revoked` (via the sentinel path) as
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
  "delegation_id": "del_...",            // opaque on the wire; new
                                         // rows under #58 carry the
                                         // 4-byte permissionId hex
                                         // for human readability,
                                         // legacy rows still carry
                                         // del_… placeholders.
  "reason": "operator_requested",
  "permission": {                        // OPTIONAL — see #58 below.
    "blob": "<base64>",
    "permission_id": "0x<8 hex>",
    "validation_id": "0x<42 hex>",
    "kernel_version": "0.3.1",
    "package_version": "5.6.3"
  },
  "correlation_id": null                 // runtime-scoped
}
```

`delegation_id` is pulled from the Phoenix `delegations` projection at
dispatch time — the worker reads the current non-terminal row's
`delegation_id` and sends it through. If no non-terminal row exists
the worker cancels with `:no_such_delegation` without reaching the
adapter, since there is nothing to cryptographically revoke.

#### Optional `permission` block (#58)

When present, the adapter MUST attempt a real
`Kernel.uninstallValidation(bytes21,bytes,bytes)` UserOp signed by
the kernel's ROOT validator EOA. When absent, the adapter falls back
to the sentinel `SimpleAccount.execute(self, 0, 0x)` no-op self-call
(legacy behaviour). The block is additive and non-breaking — older
adapters silently drop it; newer adapters refuse to honor it without
a configured operator key (`OPERATOR_PRIVATE_KEY` /
`OPERATOR_ADDRESS`) and emit `state=revoke_failed,
reason=operator_key_missing` rather than downgrade silently.

Field semantics:

- `blob` — `serializePermissionAccount(...)` output (base64 string).
  Phoenix stores it verbatim in `delegations.permission_blob` and
  ships it through; the adapter reconstitutes the
  `PermissionPlugin` via `deserializePermissionAccount(...)` to
  rebuild the same plugin the grant flow installed.
- `permission_id` — 0x-prefixed 4-byte ZeroDev `permissionId`
  (10 hex chars). Denormalized for audit lookups.
- `validation_id` — 0x-prefixed 21-byte Kernel `validationId`
  (44 hex chars). The adapter feeds this directly to
  `uninstallValidation` as `vId`; it MUST equal
  `0x02 ‖ rightPad(permission_id, 20)`. The runtime asserts this
  consistency before any chain interaction; mismatch surfaces as
  `state=revoke_failed, reason=validation_id_mismatch`.
- `kernel_version` — kernel implementation version the blob was
  produced under (e.g. `"0.3.1"`).
- `package_version` — `@zerodev/permissions` package version pinned
  at grant-time. The adapter refuses if it differs from
  `KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion`
  (mismatch surfaces as `revoke_failed,
  reason=package_version_mismatch`). Defense against silent package
  drift on either side of the wire.

Phoenix populates the block via
`Bank.Delegations.permission_dispatch_block/1` at dispatch time
when the row is `cryptographically_revocable?/1` (i.e.
`permission_blob` and a 21-byte `validation_id` are both stored).
Sentinel-era rows have neither and continue to take the legacy
path. There is no plan to backfill artifacts onto legacy rows; new
grants populate them as they land.

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
