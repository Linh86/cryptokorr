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

**#57 status — landed (narrowed scope).** The adapter-side
scaffolding for the parts of the Permission Validator path that are
verifiable today, independently of any specific validator
deployment, is in place:

- **Mapping convention.** `delegation_id` ↔ `permissionId` round
  trip in
  [`cryptobank-ts-adapter/src/chains/base/permission_validator.ts`](../../cryptobank-ts-adapter/src/chains/base/permission_validator.ts)
  (`permissionIdFromDelegationId`, `delegationIdFromPermissionId`).
  The convention — lowercase 0x-prefixed hex form of `bytes32`, 66
  chars total — is our design choice and does not depend on which
  Permission Validator deployment #58 picks. Pre-Kernel `del_…`
  placeholder ids are rejected explicitly so a Kernel revoke against
  one fails loudly rather than silently degrading.
- **ERC-7579 outer envelope.** Pinned in
  [`cryptobank-ts-adapter/src/chains/base/erc7579.ts`](../../cryptobank-ts-adapter/src/chains/base/erc7579.ts)
  against EIP-7579's normative `execute(bytes32 mode, bytes
  executionCalldata)` signature (selector `0xe9ae5c53`), the
  all-zeros single-call ModeCode, and the packed body layout
  `target ‖ value ‖ callData`. Distinct from the SimpleAccount
  envelope (`execute(address,uint256,bytes)`, selector `0xb61d27f6`)
  the v0.1 paths use today, so a Kernel call cannot be wrapped with
  the wrong outer shape by accident.
- **Adapter env key + strict accessor.** `PERMISSION_VALIDATOR_ADDRESS`
  (optional in v0.1) plus
  `requirePermissionValidatorAddress(config)` that throws a
  `#58`-referencing error when unset — so the live revoke cannot
  silently degrade back to a sentinel after #58 ships.
- **Tripwire tests.**
  [`cryptobank-ts-adapter/test/permission-validator.test.ts`](../../cryptobank-ts-adapter/test/permission-validator.test.ts)
  pins the mapping round trip and the strict accessor;
  [`cryptobank-ts-adapter/test/erc7579.test.ts`](../../cryptobank-ts-adapter/test/erc7579.test.ts)
  pins the ERC-7579 selector, mode constant, packed body shape, and
  structural distinction from the SimpleAccount envelope.
- **Fixture.** The mapping is pinned byte-for-byte against the
  canonical Phoenix fixture
  [`priv/adapter/fixtures/permission_id_mapping.json`](../priv/adapter/fixtures/permission_id_mapping.json).
- Phoenix-side, no schema or runtime change is needed:
  `delegations.delegation_id` is already a free-form string column,
  so the only updates were documentation (this ADR,
  `priv/adapter/contract.md`, the delegation moduledocs) and the
  fixture above.

**What #57 deliberately did NOT pin: the validator's own disable
ABI.** The Permission Validator's per-permission disable function
name + selector + ABI fragment depends on the specific deployment
#58 picks. Pinning a name like `disablePermission(bytes32)` from a
plausible reference implementation, without verifying it against the
bytecode of an actual deployment we will use, would be speculation;
a wrong selector would surface as a silent on-chain revert at the
first real revoke. That pin is part of #58 and gates the swap below.

**Sentinel revoke path is unchanged.** The live `executeRevoke` still
calls `buildSentinelRevokeCallData(self)`; no adapter execution logic
moved at #57. The swap point is marked inline with a `TODO(#58)`
block enumerating the remaining sub-prereqs.

#58 remains pending. It is NOT a one-liner: it has three sub-prereqs
in order — (a) migrate the live smart account from SimpleAccount to
Kernel v3 / ERC-7579 on Base, (b) pick + verify a Permission
Validator deployment, capture its disable ABI fragment + selector
against the deployed bytecode, and add a tripwire test pinning that
fragment alongside `permission_validator.ts`, (c) wire `executeRevoke`
to call
`buildErc7579ExecuteCallData(validatorAddress, 0n, <verified inner
disable body>)`, update the sentinel-pin tripwire, and run the full
revoke flow end-to-end. When that lands, #31 closes.

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
Permission Validator, wrapped in the smart account's standard
ERC-7579 `execute` envelope:

```
smartAccount.execute(
  ERC_7579_SINGLE_CALL_MODE,           // bytes32: 0x000…000
  abi.encodePacked(
    PERMISSION_VALIDATOR_ADDRESS,      // 20 bytes
    uint256(0),                        // 32 bytes
    encodePermissionDisable(permissionId)
  )
)
```

Where `encodePermissionDisable` is the ABI-encoded call to the
Permission Validator's permission-disable entry. The function name +
selector + ABI shape of that inner call depend on the specific
validator deployment #58 picks and are deliberately not pinned here
or in `permission_validator.ts`, because pinning a specific selector
before a deployment is verified would surface as a silent on-chain
revert at the first real revoke. The OUTER ERC-7579 envelope IS
pinned (in `cryptobank-ts-adapter/src/chains/base/erc7579.ts`)
because it is normative in EIP-7579 and stable across every
candidate ERC-7579 implementation.

Note that the outer `execute(bytes32, bytes)` envelope above is
**structurally distinct** from the v0.1 SimpleAccount-shaped
`execute(address, uint256, bytes)` envelope (selectors `0xe9ae5c53`
vs `0xb61d27f6` respectively). The smart-account migration in #58
swaps the outer envelope as well as the inner body. The AA pipeline
itself (UserOperation build, sign, bundler submit, receipt wait,
callback emission) is unchanged — only `callData` differs.

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

What changes at the byte level is the entire `callData` field of the
revoke UserOperation: the OUTER envelope swaps from SimpleAccount's
`execute(address,uint256,bytes)` (selector `0xb61d27f6`) to
ERC-7579's `execute(bytes32,bytes)` (selector `0xe9ae5c53`), and the
INNER body swaps from a no-op self-call to a verified Permission
Validator disable. The tripwire test
`test/base-revoke-sentinel-pin.test.ts` exists to fail loudly at
that exact moment and force whoever lands #58 to update this doc,
the contract spec, and the runbook in lockstep.

## Implementation target for #57 (as originally scoped)

> **Update — 2026-04-18.** #57 ultimately landed in narrowed form
> after a deep review found that pinning the Permission Validator's
> disable ABI fragment was speculative without a verified deployment
> to bind it against. See the **#57 status — landed (narrowed scope)**
> subsection above for what actually shipped, and what was deferred
> to #58. The original target list below is preserved for context.

#57 is the bridge between this decision and the implementable
revoke. It must land:

1. **Smart-account provisioning notes** — how the operator deploys a
   Kernel v3 account on Base, installs the Permission Validator, and
   binds the resulting addresses to adapter env. Either as a section
   in `docs/deploy.md` or as a sibling doc; either is fine. *(Status:
   deferred to #58 — the operator workflow depends on the chosen
   validator deployment, which is part of #58.)*
2. **Adapter env keys** — at minimum
   `PERMISSION_VALIDATOR_ADDRESS` (Base mainnet address of the
   chosen Permission Validator). Document fallback behavior in the
   adapter when unset (must fail closed at startup, not at request
   time, since the missing module would silently degrade revoke
   back to a sentinel). *(Status: landed in #57 with a strict
   per-revoke-call accessor in place of a startup gate, since
   leaving the env unset must remain valid in v0.1 — the live
   sentinel path does not read it.)*
3. **Module ABI fragment** — the Permission Validator's
   permission-disable signature, captured as a TypeScript ABI in the
   adapter alongside the existing `SIMPLE_ACCOUNT_EXECUTE_ABI`. Pin
   the exact signature in a Zod schema or unit test so a typo
   surfaces at build time. *(Status: deferred to #58 — pinning a
   specific function name + selector before the deployment is
   verified would surface as a silent on-chain revert at the first
   real revoke; #57 instead pinned the verifiable ERC-7579 OUTER
   `execute(bytes32,bytes)` envelope, which is normative across
   every ERC-7579 deployment.)*
4. **`delegation_id` ↔ `permissionId` mapping** — Phoenix already
   stores `delegation_id` as a string. #57 documents that this
   string is the hex-encoded `bytes32 permissionId` returned at
   permission-install time, and verifies the round trip with a
   contract test against the canonical Phoenix fixtures. *(Status:
   landed in #57.)*
5. **Contract-doc alignment** — `priv/adapter/contract.md` updated
   to describe the new revoke call shape and reference this ADR.
   *(Status: landed in #57 with the narrowed-scope language.)*

#58 then becomes a focused but multi-step change: pick + verify a
Permission Validator deployment, pin its disable ABI fragment in a
new tripwire test, swap the sentinel encoder for the real
ERC-7579-wrapped disable call, update the existing sentinel-pin
tripwire, and run the full end-to-end revoke flow against a
Kernel-shaped account on a test network. When #58 lands, #31 closes.

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
