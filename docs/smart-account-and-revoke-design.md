# Smart-account + permission-model design (alpha)

Tracks: GitHub #56 (decision), #57 (config + ABI + mapping), #58
(implementation), #31 (umbrella).

This document records the architectural decision behind a true
cryptographic delegation revoke on Base. It is the durable answer to
"what does revoke actually call, and why is that the right thing to
call?" The contract docs and the adapter README defer to this file
for that answer; the runbook only describes operator behavior.

## Status

Decided. Implementation tracked separately in #57 (wire the chosen
module's address, ABI fragment, and `delegation_id` ↔ on-chain mapping)
and #58 (replace the sentinel inner calldata with a real revoke and
update the tripwire). #31 stays open until #58 ships end-to-end.

**#57 status — landed.** The adapter-side scaffolding for the
Permission Validator is in place:

- ABI fragment + selector pin:
  [`cryptobank-ts-adapter/src/chains/base/permission_validator.ts`](../../cryptobank-ts-adapter/src/chains/base/permission_validator.ts)
  exports `KERNEL_PERMISSION_VALIDATOR_ABI` (`disablePermission(bytes32)`,
  selector `0x727e011e`) and `KERNEL_PERMISSION_DISABLE_FUNCTION`.
- `delegation_id` ↔ `permissionId` mapping helpers
  (`permissionIdFromDelegationId`, `delegationIdFromPermissionId`) plus
  the inner-disable encoder (`encodePermissionDisable`) and the full
  outer-wrap helper (`buildKernelPermissionDisableCallData`) that #58
  will plug into `executeRevoke`.
- Adapter env key `PERMISSION_VALIDATOR_ADDRESS` (optional in v0.1)
  and a strict accessor `requirePermissionValidatorAddress(config)`
  that throws a `#58`-referencing error when unset, so the live
  revoke cannot silently degrade back to a sentinel after #58 ships.
- Tripwire test
  [`cryptobank-ts-adapter/test/permission-validator.test.ts`](../../cryptobank-ts-adapter/test/permission-validator.test.ts)
  pins the ABI signature, selector, mapping round trip, and encoder
  output byte-for-byte against the canonical Phoenix fixture
  [`priv/adapter/fixtures/permission_id_mapping.json`](../priv/adapter/fixtures/permission_id_mapping.json).
- Phoenix-side, no schema or runtime change is needed:
  `delegations.delegation_id` is already a free-form string column,
  so the only updates were documentation (this ADR,
  `priv/adapter/contract.md`, the delegation moduledocs) and the
  fixture above.

**Sentinel revoke path is unchanged.** The live `executeRevoke` still
calls `buildSentinelRevokeCallData(self)`; no adapter execution logic
moved at #57. The swap point is marked inline with a `TODO(#58)`
block showing the exact replacement.

#58 remains pending: it deploys / pins a Permission Validator
address on Base, swaps the sentinel inner call for
`buildKernelPermissionDisableCallData(requirePermissionValidatorAddress(config), permissionIdFromDelegationId(delegationId))`,
updates the sentinel-pin tripwire, and runs the full revoke flow
end-to-end. When that lands, #31 closes.

## Decision

Adopt a **Kernel v3 (ERC-7579) modular smart account** on Base, with
delegation authority registered as a **per-delegation permission on a
Kernel-compatible Permission Validator module**. The on-chain
authority record is the permission's `bytes32 permissionId`. A
cryptographic revoke is a single call against that validator that
disables the permission, wrapped in the smart account's
ERC-7579 `execute(target, value, data)` so it flows through the same
ERC-4337 v0.7 UserOperation pipeline every other action uses.

This replaces the v0.1 SimpleAccount-shaped assumption, in which the
delegation key IS the smart-account owner and there is no separate
authority to disable. From #58 onward, "revoke" stops being a sentinel
on-chain anchor and starts being a chain-enforced disablement of the
delegation's signing rights.

## Context

### What v0.1 ships against today

The adapter targets ERC-4337 v0.7 with a SimpleAccount-shaped
`execute(target, value, data)` ABI. The `DELEGATION_SIGNER_KEY`
configured in the adapter env is the SimpleAccount owner — there is
no separate, individually disableable delegation authority on chain.
The "revoke" path is therefore a sentinel UserOperation with inner
call `execute(self, 0, 0x)`: a real on-chain anchor with a real
user-op hash and receipt, but not a cryptographic disablement of
the signing key. See [adapter `userop.ts`](../../cryptobank-ts-adapter/src/chains/base/userop.ts)
for the sentinel and the tripwire test pinning it byte-for-byte.

### Phoenix already speaks the right state machine

The Phoenix-side delegation projection
([`Bank.Delegations`](../lib/bank/delegations.ex),
[`Bank.Delegations.Delegation`](../lib/bank/delegations/delegation.ex))
already expresses the lifecycle a real revoke needs:

```
pending → active → revoking → revoked       (success)
                       │
                       └──► revoke_failed → revoking → revoked  (retry)
```

`Bank.Delegations.executable?/1` fails closed the moment `:revoking`
is recorded. `delegation_id` is already a string column
(`delegations.delegation_id`) opaque to Phoenix, and the adapter
contract already passes `delegation_id` end-to-end. None of that has
to change to support a real revoke — the missing piece is on chain.

### Phoenix–adapter callback contract is already authority-agnostic

`delegation.state_changed` carries `tx_refs` shaped as
`{chain, userop_hash, hash, nonce, bundler, block_number, status}`
for both transfer and revoke; the failure taxonomy
(`userop_build_failed`, `bundler_rejected`, `bundler_hash_mismatch`,
`confirmation_failed`, plus chain-level revert) is already exercised
end-to-end against the sentinel. Swapping the inner calldata for a
real revoke does not require any Phoenix-side schema, callback, or
state-machine changes. This is the property that makes the decision
below cheap to land.

## Options considered

### A. Kernel v3 (ZeroDev) — chosen

ERC-7579 modular account. Authority lives in installable Validator
modules; per-delegation state is exposed by a Permission Validator
that registers each delegation under a stable `bytes32 permissionId`.

- **Authority model**: install a Permission Validator once per smart
  account. Each grant registers a permission with a deterministic
  `permissionId`. Revoke = call the validator's permission-disable
  entry with that id; the userop signed by the now-disabled key
  stops validating immediately.
- **Standardised ABI surface**: ERC-7579 standardises
  `installModule` / `uninstallModule` / `execute` so the adapter's
  module-call layer is not vendor-locked even though the validator
  itself is Kernel-shaped.
- **Base maturity**: ZeroDev runs production bundlers and paymasters
  on Base, including Coinbase Smart Wallet co-existence; the
  ecosystem has documented session-key flows on Base mainnet.
- **viem support**: `viem/account-abstraction` already supports
  Kernel-shaped accounts; the existing
  `buildAndSignUserOp` path slots in unchanged once `callData` is
  the real disable call instead of the sentinel self-call.
- **Operational simplicity**: a single Permission Validator install
  per smart account, then per-delegation state managed by id. No
  multisig topology to reason about.

### B. Safe (Safe{Core} modules / guards) — rejected for v0.1

Safe is a multisig framework with a module/guard plugin slot. To use
it as a delegation host you either:

- pick a third-party session-key module (Rhinestone, Pimlico session
  keys, etc.) — which moves the "module choice" problem one layer
  deeper without simplifying it; or
- write a custom Safe module — out of scope for #56 and worse than
  option D below.

The default Safe authority shape is "N-of-M owner signatures over a
SafeTx". Encoding a single AI-driven delegation against that shape is
awkward: you'd either spend an owner slot (giving the agent more
authority than intended) or layer a session-key module that has its
own per-vendor revoke ABI we'd still have to integrate.

Safe also costs more gas to deploy and operate than the Kernel
shape we'd otherwise pick, which matters for a per-user smart account
on Base.

### C. Biconomy Nexus — rejected as primary, kept as fallback

Nexus is a credible ERC-7579 account in the same architectural family
as Kernel. The day-to-day adapter code would look very similar.
We are not picking it as primary because:

- Kernel has more time-on-Base in production deployments and
  documented session-key flows, which matters for an alpha that
  needs to ship and stay shipped.
- viem and the major bundler vendors document Kernel-first integration
  paths.
- ERC-7579 standardises enough of the surface that switching from
  Kernel to Nexus later — should that ever be needed — is a re-pin of
  module address + revoke ABI, not a re-architecture.

If Kernel proves blocked at #57 (e.g., a required Permission Validator
is unavailable on Base for our needs), Nexus is the documented
fallback and #57 should re-open #56 to record the swap.

### D. Custom minimal permission module — rejected for v0.1

A bespoke module would give us the cleanest semantic match to our
trust engine, at the cost of: writing, auditing, deploying, and
permanently maintaining custom on-chain code. For v0.1 the missing
primitive is not "novel permission semantics" — it is "a delegation
authority that can actually be revoked at all". A battle-tested
modular account with a published Permission Validator buys us months
of safety review for hours of integration work.

A custom module remains the right bet later if Kernel's permission
model constrains product evolution — e.g., if our trust assessment
needs per-call attestations the existing validators cannot express.
That decision should be re-opened explicitly when those needs are
real, not pre-committed now.

## What "delegation authority" is on chain

After #58 ships:

- One Kernel v3 smart account is deployed per user (1 in v0.1, the
  `SMART_ACCOUNT_ADDRESS` the adapter is bonded to).
- A Permission Validator module is installed against that account
  exactly once at provisioning time. Its address is configured on
  the adapter as `PERMISSION_VALIDATOR_ADDRESS` (#57 names this).
- Each granted delegation registers a permission with the validator,
  scoped to the actions the agent is allowed to perform (the
  `signing_requirements.scope` already passed end-to-end). The
  validator returns a stable `bytes32 permissionId`.
- The adapter persists nothing. The adapter contract already
  forwards `delegation_id` to Phoenix on every callback; #57 binds
  `delegations.delegation_id` (currently a string column) to the
  hex-encoded `permissionId`. The mapping is 1:1, opaque to
  Phoenix, and stable across restarts.
- A signature produced by the delegation key validates if and only
  if the permission corresponding to `delegation_id` is still
  registered against this smart account.

## What revoke must call

The contract-level revoke is a single ERC-7579 call against the
Permission Validator, wrapped in the smart account's `execute`:

```
smartAccount.execute(
  PERMISSION_VALIDATOR_ADDRESS,
  0,
  encodePermissionDisable(permissionId)
)
```

Where `encodePermissionDisable` is the ABI-encoded call to the
Permission Validator's permission-disable entry. The exact function
selector, signature, and `permissionId` derivation are #57's
responsibility — those depend on the specific validator deployment
chosen and are deliberately not pinned here, because pinning a
specific selector before #57 has confirmed module availability would
be premature.

The outer `execute(target, value, data)` envelope is unchanged from
v0.1 — the adapter already wraps every action that way. Once #58
swaps the inner calldata, the entire AA pipeline (UserOperation
build, sign, bundler submit, receipt wait, callback emission) is
the same code path that already runs for transfers.

## What does NOT need to change

These are explicitly stable across #57/#58:

- **Phoenix delegation state machine** — already
  `:granted → :revoking → :revoked` / `:revoke_failed`. Confirmed
  fail-closed in `Bank.Delegations.executable?/1`.
- **`delegation.state_changed` callback contract** — same shape
  (`state`, `reason`, `tx_refs`, `delegation_id`).
- **AA pipeline in the adapter** — `buildAndSignUserOp`, bundler
  submit, receipt wait, hash-mismatch fail-closed.
- **Failure taxonomy** — `userop_build_failed`, `bundler_rejected`,
  `bundler_hash_mismatch`, `confirmation_failed`, plus chain-level
  revert. The same enum applies to a real revoke.
- **Phoenix retry posture** — operator can retry from
  `:revoke_failed` exactly as today; the adapter resubmits a fresh
  user-op against the same `permissionId`.
- **Adapter idempotency** — in-flight set keyed by
  `smart_account_id` continues to suppress duplicate sends.

The only thing that changes at the byte level is the inner calldata
returned by `buildSentinelRevokeCallData` (renamed at that point to
`buildPermissionDisableCallData` or similar). The tripwire test
`test/base-revoke-sentinel-pin.test.ts` exists to fail loudly at
that exact moment and force whoever lands #58 to update this doc,
the contract spec, and the runbook in lockstep.

## Implementation target for #57

#57 is the bridge between this decision and the implementable
revoke. It must land:

1. **Smart-account provisioning notes** — how the operator deploys a
   Kernel v3 account on Base, installs the Permission Validator, and
   binds the resulting addresses to adapter env. Either as a section
   in `docs/deploy.md` or as a sibling doc; either is fine.
2. **Adapter env keys** — at minimum
   `PERMISSION_VALIDATOR_ADDRESS` (Base mainnet address of the
   chosen Permission Validator). Document fallback behavior in the
   adapter when unset (must fail closed at startup, not at request
   time, since the missing module would silently degrade revoke
   back to a sentinel).
3. **Module ABI fragment** — the Permission Validator's
   permission-disable signature, captured as a TypeScript ABI in the
   adapter alongside the existing `SIMPLE_ACCOUNT_EXECUTE_ABI`. Pin
   the exact signature in a Zod schema or unit test so a typo
   surfaces at build time.
4. **`delegation_id` ↔ `permissionId` mapping** — Phoenix already
   stores `delegation_id` as a string. #57 documents that this
   string is the hex-encoded `bytes32 permissionId` returned at
   permission-install time, and verifies the round trip with a
   contract test against the canonical Phoenix fixtures.
5. **Contract-doc alignment** — `priv/adapter/contract.md` updated
   to describe the new revoke call shape and reference this ADR.

#58 then becomes a small, focused change: swap the sentinel encoder
for a real one, update the tripwire pin, and run the full end-to-end
revoke flow against a Kernel-shaped account on a test network. When
#58 lands, #31 closes.

## Why this fits the bank runtime model

- **Phoenix stays the system of record**. The on-chain authority
  record is opaque to Phoenix — it's just a `bytes32` stored as a
  string in `delegations.delegation_id`. Phoenix continues to drive
  the delegation lifecycle from policy and trust assessments; the
  chain enforces what Phoenix has already decided.
- **The trust engine model is unchanged**. Trust assessments still
  decide whether a counterparty is `trusted | sensitive | unknown |
  conflicted`; revocation acts on the delegation that authorises the
  agent, not on the per-action trust decision.
- **The decision memo's "Solidity used sparingly" principle holds**.
  The only on-chain code we add is configuration (which Permission
  Validator address, which permission scope) — no bespoke contracts.
- **Operator clarity stays good**. A real revoke produces the same
  callbacks the operator already sees today; the difference is that
  `:revoked` now means "the chain refuses further userops from this
  delegation" rather than "the chain anchored an intent to stop".
  The runbook needs a one-paragraph update at #58 time, not a
  rewrite.

## Re-open conditions

This decision should be reconsidered (re-opening #56) if any of the
following becomes true:

- Kernel v3's Permission Validator on Base is shown to be
  unavailable, unaudited at our risk tolerance, or otherwise blocked
  during #57 implementation. Documented fallback: Biconomy Nexus.
- Product needs evolve to require per-call attestations or signed
  permission deltas the off-the-shelf validators cannot express. In
  that case, evaluate option D (custom module) on its merits.
- Base itself becomes the wrong primary chain. The ERC-7579 surface
  is portable, so the chain change matters more than the module
  change, but both warrant a fresh decision pass.
