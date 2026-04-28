# Smart-account + permission-model design (alpha)

Tracks: GitHub #56 (smart-account decision), #84 (Kernel v3
provisioning), #83 (ZeroDev permission pin), #58 (cryptographic
revoke), #31 (umbrella).

This document records the architectural decision behind a true
cryptographic delegation revoke on Base. It is the durable answer
to "what does revoke actually call, and why is that the right
thing to call?" The contract docs and the adapter README defer to
this file; the runbook only describes operator behavior.

> **Model correction — 2026-04-23.** Earlier revisions of this ADR
> described "a single deployable Permission Validator contract at
> one address, pinned via `PERMISSION_VALIDATOR_ADDRESS` and
> `disablePermission(bytes32)`, with `permissionId` as `bytes32`."
> That model was wrong against `@zerodev/permissions@5.6.3` —
> `toPermissionValidator()` returns a plugin whose `.address` is
> `zeroAddress`; permissions compose from CREATE2 signer + policy
> modules; `permissionId` is `bytes4`; revoke is
> `Kernel.uninstallValidation(bytes21,bytes,bytes)` on the smart
> account itself. The body of this document has been rewritten to
> reflect the corrected model. See
> [`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md)
> for the canonical integration shape and the hard-blocker list;
> this file documents the architectural decision (Kernel v3) and
> defers integration specifics to that doc.

## Status

- **#56 — DECIDED.** Kernel v3 (ERC-7579) modular smart account on
  Base. The decision is independent of the permission-model
  correction below: a kernel-modular account is still the right
  host for a real cryptographic revoke once the integration lands.
- **#84 — CLOSED on Base Sepolia.** The
  smart-account-deploy portion of the operator runbook is in
  [`docs/provisioning-kernel-v3.md`](provisioning-kernel-v3.md);
  `chain_adapter/scripts/provision-kernel.ts` is the runnable
  template. A real Kernel v3.1 smart account was deployed at
  `0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C` and verified
  against the same pinned values (factory
  `0xaac5D4240AF87249B3f71BC8E4A2cae074A3E419`, implementation
  `0xBAC849bB641841b44E965fB01A4Bf5F074f84b4D`, root validator
  `0x845ADb2C711129d4f3966735eD98a9F09fC4cE57`); deploy tx
  `0xe6ad5263ed7023ee6b5f7dd2c529efda27ccb4cebce449c52a58a882c9fe4724`.
- **#83 — LANDED.** Was "pin the Permission Validator's
  `disablePermission(bytes32)` ABI fragment against a verified
  deployment." Re-scoped to "populate `KernelPermissionPin` from
  `chain_adapter/src/chains/base/permission_validator.ts` against
  ZeroDev's actual primitives". The pin is populated with the
  ECDSA signer + the six modern policy modules from
  `@zerodev/permissions@5.6.3` and the
  `uninstallValidation(bytes21,bytes,bytes)` ABI fragment from
  `KernelV3_1AccountAbi`; both halves are verified by the
  `permission-validator-pin.test.ts` tripwire.
- **#58 — STILL OPEN.** The sentinel-era revoke is unchanged. The
  swap target is no longer "a Permission Validator's disable
  function"; it is `Kernel.uninstallValidation(bytes21,bytes,bytes)`
  ON the smart account itself, signed by a sudo signer the adapter
  does not yet hold. The full hard-blocker list is in the
  integration doc.
- **#31 — STILL OPEN.** Closes when #58 ships against a
  Kernel-provisioned account.

What is verifiable today, independent of the integration:

- **ERC-7579 outer-execute envelope pin.** Pinned in
  [`chain_adapter/src/chains/base/erc7579.ts`](../chain_adapter/src/chains/base/erc7579.ts)
  against EIP-7579's normative `execute(bytes32 mode, bytes
  executionCalldata)` signature (selector `0xe9ae5c53`),
  all-zeros single-call ModeCode, packed body layout
  `target ‖ value ‖ callData`. Distinct from the SimpleAccount
  envelope (`execute(address,uint256,bytes)`, selector
  `0xb61d27f6`) the v0.1 paths use today, so a Kernel call cannot
  be wrapped with the wrong outer shape by accident. The pin
  survives the ZeroDev model correction because EIP-7579 is
  normative across every kernel-shaped account, regardless of how
  permissions above it compose.
- **Sentinel revoke pin.** The sentinel `executeRevoke` body is
  `SimpleAccount.execute(self, 0, 0x)` — a real on-chain anchor,
  not a cryptographic disablement. Pinned byte-for-byte in
  [`chain_adapter/test/base-revoke-sentinel-pin.test.ts`](../chain_adapter/test/base-revoke-sentinel-pin.test.ts).
  The tripwire fails loudly if the inner call shape changes,
  forcing whoever lands #58 to update this ADR + the integration
  doc + the operator runbooks in lockstep.
- **`KernelPermissionPin` populated.** Exported from
  [`permission_validator.ts`](../chain_adapter/src/chains/base/permission_validator.ts).
  `KERNEL_PERMISSION_PIN` carries the canonical ECDSA signer
  (`0x6A6F0…D4FF`) plus the six modern policy modules from
  `@zerodev/permissions@5.6.3` (CALL v0.0.5, GAS, RATE_LIMIT,
  SIGNATURE, SUDO, TIMESTAMP), and the
  `uninstallValidation(bytes21,bytes,bytes)` ABI fragment from
  `KernelV3_1AccountAbi` in `@zerodev/sdk@5.5.10`. The
  `permission-validator-pin.test.ts` tripwire imports the same
  package values and asserts equality, so a future package bump
  that drifts cannot land silently.

## Decision

Adopt a **Kernel v3 (ERC-7579) modular smart account** on Base for
the long-term delegation runtime. ERC-7579 standardises the
outer-execute envelope and the validator-module surface, so the
adapter's AA pipeline (`buildAndSignUserOp`, bundler submit,
receipt wait, callback emission) is stable across the eventual
permissions integration.

This replaces the v0.1 SimpleAccount-shaped assumption, in which
the delegation key IS the smart-account owner and there is no
separate authority to disable. From the integration onward,
"revoke" stops being a sentinel on-chain anchor and starts being
a chain-enforced disablement of the delegation's signing rights.

The **shape of the cryptographic revoke** — which signer module,
which policy modules, what `delegation_id` actually carries on the
wire (4-byte `permissionId`, 21-byte `validationId`, or a
serialized plugin blob), and whether revoke is per-permission via
`Kernel.uninstallValidation` or coarser via
`Kernel.invalidateNonce` — is deferred to
[`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md).
That doc is canonical for integration specifics; this ADR commits
only to the smart-account host (Kernel v3).

## Context

### What v0.1 ships against today

The adapter targets ERC-4337 v0.7 with a SimpleAccount-shaped
`execute(target, value, data)` ABI. The `DELEGATION_SIGNER_KEY`
configured in the adapter env is the SimpleAccount owner — there
is no separate, individually disableable delegation authority on
chain. The "revoke" path is therefore a sentinel UserOperation
with inner call `execute(self, 0, 0x)`: a real on-chain anchor
with a real user-op hash and receipt, but not a cryptographic
disablement of the signing key. See
[adapter `userop.ts`](../chain_adapter/src/chains/base/userop.ts)
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

`Bank.Delegations.executable?/1` fails closed the moment
`:revoking` is recorded. `delegation_id` is already a string
column (`delegations.delegation_id`) opaque to Phoenix, and the
adapter contract already passes `delegation_id` end-to-end. None
of that has to change to support a real revoke — the missing
piece is on chain. The on-the-wire encoding of `delegation_id`
itself (4-byte, 21-byte, or serialized plugin blob) is part of
the integration TODO; the column is encoding-agnostic.

### Phoenix–adapter callback contract is already authority-agnostic

`delegation.state_changed` carries `tx_refs` shaped as
`{chain, userop_hash, hash, nonce, bundler, block_number,
status}` for both transfer and revoke; the failure taxonomy
(`userop_build_failed`, `bundler_rejected`,
`bundler_hash_mismatch`, `confirmation_failed`, plus chain-level
revert) is already exercised end-to-end against the sentinel.
Swapping the inner calldata for a real revoke does not require
any Phoenix-side schema, callback, or state-machine changes.
This is the property that makes #56 cheap to land and keeps the
ZeroDev integration scoped to the adapter side.

## Options considered

### A. Kernel v3 (ZeroDev) — chosen

ERC-7579 modular account. Validator authority is installable via
plugins; the ZeroDev permissions package builds those plugins
from a chosen signer + policy combination, computing a
`permissionId` deterministically off-chain.

- **Standardised outer surface.** ERC-7579 standardises
  `installModule` / `uninstallModule` / `execute`, so the
  adapter's outer-call layer is portable across compatible
  accounts even though we pick Kernel as primary.
- **Base maturity.** ZeroDev runs production bundlers and
  paymasters on Base, and documents session-key flows on Base
  mainnet.
- **viem support.** `viem/account-abstraction` already supports
  Kernel-shaped accounts; the existing `buildAndSignUserOp` path
  slots in unchanged once `callData` is the real revoke call
  instead of the sentinel self-call.
- **Operational simplicity for the smart-account layer.** One
  Kernel account per user; the permissions composition (which
  signer + policies, how revoke flows) is a layer above and
  documented separately in the integration doc.

### B. Safe (Safe{Core} modules / guards) — rejected for v0.1

Safe is a multisig framework with a module/guard plugin slot. To
use it as a delegation host you either:

- pick a third-party session-key module (Rhinestone, Pimlico
  session keys, etc.) — which moves the "module choice" problem
  one layer deeper without simplifying it; or
- write a custom Safe module — out of scope for #56 and worse
  than option D below.

The default Safe authority shape is "N-of-M owner signatures over
a SafeTx". Encoding a single AI-driven delegation against that
shape is awkward: you'd either spend an owner slot (giving the
agent more authority than intended) or layer a session-key module
that has its own per-vendor revoke ABI we'd still have to
integrate.

Safe also costs more gas to deploy and operate than the Kernel
shape we'd otherwise pick, which matters for a per-user smart
account on Base.

### C. Biconomy Nexus — rejected as primary, kept as fallback

Nexus is a credible ERC-7579 account in the same architectural
family as Kernel. The day-to-day adapter code would look very
similar. We are not picking it as primary because:

- Kernel has more time-on-Base in production deployments and
  documented session-key flows, which matters for an alpha that
  needs to ship and stay shipped.
- viem and the major bundler vendors document Kernel-first
  integration paths.
- ERC-7579 standardises enough of the outer surface that
  switching from Kernel to Nexus later — should that ever be
  needed — is a re-pin at the integration layer (signer/policy
  module addresses, kernel implementation address), not a
  re-architecture of the AA pipeline.

If Kernel proves blocked at integration time (e.g. a required
ZeroDev module is unavailable on Base for our needs), Nexus is
the documented fallback and #56 should re-open to record the
swap.

### D. Custom minimal permission module — rejected for v0.1

A bespoke module would give us the cleanest semantic match to
our trust engine, at the cost of: writing, auditing, deploying,
and permanently maintaining custom on-chain code. For v0.1 the
missing primitive is not "novel permission semantics" — it is
"a delegation authority that can actually be revoked at all".
A battle-tested modular account with a ZeroDev permissions
integration buys us months of safety review for hours of
adapter work.

A custom module remains the right bet later if ZeroDev's
permissions model constrains product evolution — e.g. if our
trust assessment needs per-call attestations the existing
policies cannot express. That decision should be re-opened
explicitly when those needs are real, not pre-committed now.

## What "delegation authority" is on chain

After the integration ships:

- One Kernel v3 smart account is deployed per user (1 in v0.1,
  the `SMART_ACCOUNT_ADDRESS` the adapter is bonded to).
- Each granted delegation is a ZeroDev permission constructed
  off-chain via `toPermissionValidator({ signer, policies, … })`.
  The signer + policy contract addresses are CREATE2-deployed
  ZeroDev modules with the same address on every chain (see the
  integration doc's address table).
- The grant flow installs that permission on the kernel account
  via a sudo-signed `Kernel.installValidations(...)` UserOp,
  routed through the bundler.
- Each permission carries a deterministic `bytes4 permissionId`
  computed as
  `slice(keccak256(encodeAbiParameters([toPolicyId(policies),
  flag, toSignerId(signer)])), 0, 4)`. The kernel keys its
  storage on the 21-byte `validationId` (`0x02` ‖
  `rightPad(permissionId, 20)`).
- The adapter persists nothing about permissions in v0.1
  beyond what Phoenix sends (`delegation_id` opaque). The
  integration TODO records that grant-time persistence of a
  serialized plugin blob (or raw policy + signer reconstruction
  params) is required so the adapter can rebuild the plugin at
  revoke-time; that is one of the hard blockers in the
  integration doc.
- A signature produced by the delegation key validates if and
  only if the corresponding permission's `permissionConfig[pId]`
  storage slot on the kernel account is non-zero (i.e. the
  permission is still installed).

## What revoke must call

The contract-level revoke is **not** a call against a separate
Permission Validator contract. It is `Kernel.uninstallValidation`
ON the smart account itself, signed by a sudo signer for that
account, routed through the bundler — wrapped in the smart
account's own ERC-7579 `execute(bytes32 mode, bytes executionCalldata)`
envelope when called via the AA pipeline:

```
smartAccount.execute(
  ERC_7579_SINGLE_CALL_MODE,             // bytes32: 0x000…000
  abi.encodePacked(
    smartAccount,                        // 20 bytes — call to self
    uint256(0),                          // 32 bytes
    abi.encodeCall(
      Kernel.uninstallValidation,
      (validationId, deinitData, hookDeinitData)
    )
  )
)
```

Where:

- `validationId = 0x02 ‖ rightPad(permissionId, 20)` (21 bytes).
- `deinitData` is a multi-policy `PermissionDisableDataFormat`
  payload whose length must equal `policyData.length + 1`. The
  adapter reconstructs it by rebuilding the same `PermissionPlugin`
  the grant flow used (from a persisted serialization blob or
  from raw policy + signer parameters).
- `hookDeinitData` matches the install-time hook configuration.

The OUTER ERC-7579 envelope is pinned (in
`chain_adapter/src/chains/base/erc7579.ts`) because it is normative
in EIP-7579 and stable across every kernel-shaped implementation.
The INNER `Kernel.uninstallValidation` ABI is part of the kernel
implementation's own surface (not a separate validator contract),
and pinning its selector + argument shape is part of the
`KernelPermissionPin` design tracked in #83 — see the
integration doc.

A coarser path also exists: `Kernel.invalidateNonce(uint32)` bumps
`validNonceFrom` and invalidates every validation whose install
nonce is below it. It is "rotate the whole set of session keys"
rather than "revoke one permission"; whether to use it instead of
per-permission revoke is one of the open product questions noted
in the integration doc.

The outer `execute(bytes32, bytes)` envelope above is
**structurally distinct** from the v0.1 SimpleAccount-shaped
`execute(address, uint256, bytes)` envelope (selectors
`0xe9ae5c53` vs `0xb61d27f6` respectively). The smart-account
migration in #58 swaps the outer envelope as well as the inner
body. The AA pipeline itself is unchanged — only `callData`
differs.

## What does NOT need to change

These are explicitly stable across the integration:

- **Phoenix delegation state machine** — already
  `:granted → :revoking → :revoked` / `:revoke_failed`. Confirmed
  fail-closed in `Bank.Delegations.executable?/1`.
- **`delegation.state_changed` callback contract** — same shape
  (`state`, `reason`, `tx_refs`, `delegation_id`).
- **AA pipeline in the adapter** — `buildAndSignUserOp`, bundler
  submit, receipt wait, hash-mismatch fail-closed.
- **Failure taxonomy** — `userop_build_failed`,
  `bundler_rejected`, `bundler_hash_mismatch`,
  `confirmation_failed`, plus chain-level revert. The same enum
  applies to a real revoke.
- **Phoenix retry posture** — operator can retry from
  `:revoke_failed` exactly as today; the adapter resubmits a
  fresh user-op.
- **Adapter idempotency** — in-flight set keyed by
  `smart_account_id` continues to suppress duplicate sends.

What changes at the byte level is the entire `callData` field of
the revoke UserOperation: the OUTER envelope swaps from
SimpleAccount's `execute(address,uint256,bytes)` (selector
`0xb61d27f6`) to ERC-7579's `execute(bytes32,bytes)` (selector
`0xe9ae5c53`), and the INNER body swaps from a no-op self-call
to a `Kernel.uninstallValidation(...)` call against the smart
account itself. The tripwire test
`test/base-revoke-sentinel-pin.test.ts` exists to fail loudly at
that exact moment and force whoever lands #58 to update this doc,
the integration doc, the contract spec, and the runbook in
lockstep.

## Why this fits the bank runtime model

- **Phoenix stays the system of record.** The on-chain authority
  record is opaque to Phoenix — a string in
  `delegations.delegation_id`. Phoenix continues to drive the
  delegation lifecycle from policy and trust assessments; the
  chain enforces what Phoenix has already decided.
- **The trust engine model is unchanged.** Trust assessments
  still decide whether a counterparty is `trusted | sensitive |
  unknown | conflicted`; revocation acts on the delegation that
  authorises the agent, not on the per-action trust decision.
- **The decision memo's "Solidity used sparingly" principle
  holds.** No bespoke contracts; the only on-chain code we
  consume is canonical ZeroDev modules and the kernel
  implementation itself.
- **Operator clarity stays good.** A real revoke produces the
  same callbacks the operator already sees today; the difference
  is that `:revoked` will eventually mean "the chain refuses
  further userops from this delegation" rather than "the chain
  anchored an intent to stop". The runbook needs a one-paragraph
  update at integration time, not a rewrite.

## Re-open conditions

This decision should be reconsidered (re-opening #56) if any of
the following becomes true:

- ZeroDev's primitives on Base are shown to be unavailable,
  unaudited at our risk tolerance, or otherwise blocked during
  integration. Documented fallback: Biconomy Nexus.
- Product needs evolve to require per-call attestations or
  signed permission deltas the off-the-shelf policies cannot
  express. In that case, evaluate option D (custom module) on
  its merits.
- Base itself becomes the wrong primary chain. The ERC-7579
  outer surface is portable, so the chain change matters more
  than the module change, but both warrant a fresh decision
  pass.
