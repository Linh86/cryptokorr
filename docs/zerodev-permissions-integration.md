# ZeroDev kernel permissions — corrected model + integration TODO

This doc replaces a wrong-model assumption that had spread across
the repo's runbooks, scripts, and code: that ZeroDev's kernel
permissions architecture has a single deployable "Permission
Validator" contract at one address with one `disablePermission(bytes32)`
ABI fragment. It does not. This file is the single source of truth
for what the runtime actually has to integrate against, and the
hard blockers that have to be resolved before cryptographic revoke
(#58) can ship.

Authoritative references inspected on 2026-04-23:

- npm package `@zerodev/permissions@5.6.3` source — `toPermissionValidator.ts`,
  `constants.ts`, `toInitConfig.ts`, `types.ts`.
- ZeroDev SDK GitHub — `zerodevapp/sdk`, in particular
  `plugins/permission/toPermissionValidator.ts` and
  `packages/core/actions/account-client/uninstallPlugin.ts`.
- Kernel contract source — `zerodevapp/kernel`, especially
  `src/Kernel.sol`, `src/core/ValidationManager.sol`,
  `src/types/Types.sol`, `src/utils/ValidationTypeLib.sol`.
- ZeroDev docs — Permissions intro and Session Keys.
- contractscan.xyz cross-chain deployment confirmation for two
  representative module addresses (the rest are deployed via the
  same CREATE2 factory pattern).

## What was wrong

- The repo asked operators to look up a single
  `PERMISSION_VALIDATOR_ADDRESS` and bind it as adapter env. There
  is no such single address in ZeroDev's permissions architecture.
- `toPermissionValidator()` returns a plugin object whose `.address`
  is literally `zeroAddress`. It carries `validatorType: "PERMISSION"`
  and `source: "PermissionValidator"` (a string label), not a
  contract address.
- The repo's `VerifiedPermissionValidator` interface pinned a single
  `disableFunction: AbiFunction` taking one `bytes32` argument.
  ZeroDev does not expose any such function on any contract — revoke
  is a method on the smart account itself, not on a separate
  validator.
- The repo's `permissionIdFromDelegationId` helper enforced 66 chars
  (`0x` + 64 hex, i.e. `bytes32`). ZeroDev's actual `permissionId` is
  4 bytes (`bytes4`, 8 hex chars), and the kernel's `validationId`
  that wraps it is 21 bytes. The 66-char enforcement would reject
  every real ZeroDev id.

## What's actually true

### On-chain primitives

The contracts ZeroDev's permissions package addresses are CREATE2-
deployed and have the same address on every chain (Ethereum, Base,
Sepolia, Arbitrum, Optimism, …). Confirmed via contractscan.xyz for
the two representative modules below; the rest are deployed by the
same factory pattern per the package README.

**Signer modules** (`ISigner`):

| Constant | Address | Notes |
| --- | --- | --- |
| `ECDSA_SIGNER_CONTRACT` | `0x6A6F069E2a08c2468e7724Ab3250CdBFBA14D4FF` | EOA-signed permissions. |
| `WEBAUTHN_SIGNER_CONTRACT_V0_0_4` | `0x65DEeC8fEe717dc044D0CFD63cCf55F02cCaC2b3` | Passkey/WebAuthn permissions. |

**Policy modules** (`IPolicy`):

| Constant | Address | Notes |
| --- | --- | --- |
| `CALL_POLICY_CONTRACT_V0_0_5` | `0x85770b902D1e503D5f5141d9eaC16d0d08eEaDd2` | Per-call target/selector/value/argument allowlist. |
| `GAS_POLICY_CONTRACT` | `0xaeFC5AbC67FfD258abD0A3E54f65E70326F84b23` | Cap on cumulative gas spend. |
| `RATE_LIMIT_POLICY_CONTRACT` | `0xf63d4139B25c836334edD76641356c6b74C86873` | Time-window call-rate cap. |
| `SIGNATURE_POLICY_CONTRACT` | `0xF6A936c88D97E6fad13b98d2FD731Ff17eeD591d` | Allowed-signers filter. |
| `SUDO_POLICY_CONTRACT` | `0x67b436caD8a6D025DF6C82C5BB43fbF11fC5B9B7` | Unrestricted (delegated to the kernel's own validation). |
| `TIMESTAMP_POLICY_CONTRACT` | `0xB9f8f524bE6EcD8C945b1b87f9ae5C192FdCE20F` | Valid-after / valid-until window. |

The kernel implementation itself is also on chain (`Kernel.sol`,
`ValidationManager.sol`) at a per-version address, with the kernel
`uninstallValidation(bytes21,bytes,bytes)` method as the on-chain
revoke entry point.

### Permission identity

`permissionId` is computed off-chain in JS:

```ts
const pIdData = encodeAbiParameters(
  [{ name: "policyAndSignerData", type: "bytes[]" }],
  [[toPolicyId(policies), flag, toSignerId(signer)]]
);
const permissionId = slice(keccak256(pIdData), 0, 4); // bytes4
```

It is independent of any single validator address. The policy contract
addresses contribute to the hash via each policy's
`getPolicyInfoInBytes()` (concat of policy flag and the policy
contract address), so swapping a policy version produces a different
`permissionId`.

The kernel's `validationId` is 21 bytes:

```
0x02 ++ rightPad(permissionId, 20)   // VALIDATOR_TYPE.PERMISSION = 0x02
```

### How revoke actually works

There is no `disablePermission(bytes32)` selector on any contract.
Revoke is a UserOperation whose callData is
`Kernel.uninstallValidation(bytes21 vId, bytes deinitData, bytes hookDeinitData)`
**called on the smart account itself**, signed by a sudo signer for
that account, routed through the bundler.

`deinitData` is a multi-policy payload (a `PermissionDisableDataFormat`
whose length must equal `policyData.length + 1`), so per-permission
revoke needs the same plugin reconstruction the grant flow used —
either by re-deriving from raw policy + signer parameters, or by
deserializing a previously-saved `serializePermissionAccount(...)`
blob.

A coarser path also exists: `Kernel.invalidateNonce(uint32)` bumps
`validNonceFrom`, invalidating every validation whose install nonce
is below it. Closer to "rotate the whole set of session keys" than
to per-permission revoke.

## How CryptoBank should integrate (sketch)

1. **Grant** = construct a `PermissionPlugin` via
   `toPermissionValidator({ signer, policies, entryPoint, kernelVersion })`,
   install on the kernel account through a sudo-signed
   `Kernel.installValidations(...)` UserOp. Persist the resulting
   `permissionId` (4 bytes) AND a serialized plugin blob (so revoke
   can reconstruct the plugin) in Phoenix's `delegations` row.
2. **Verify (off-chain)** = `eth_call`
   `kernel.permissionConfig(bytes4 permissionId)` against the
   configured Base RPC; assert `.signer != address(0)` and
   `.policyData.length > 0`. Optionally compare against the install
   nonce.
3. **Revoke** = reconstruct the plugin from the persisted blob,
   build the UserOp callData `Kernel.uninstallValidation(vId,
   deinitData, hookDeinitData)`, sign with a sudo signer, route
   through the bundler. Phoenix's wire contract is unchanged: the
   adapter still receives `{smart_account_id, delegation_id,
   reason}` and emits `delegation.state_changed` callbacks.

## Hard blockers (for #58 / #83 / #84 to actually close)

Blockers (1), (4) (Phoenix-side persistence half), (5), and (6) are
now resolved by the #58 PR. Blocker (2) is resolved at the
config-plumbing level (operator key field is wired through
`AdapterConfig` with full validation); the operator must
provision the actual key in their secrets manager before the
cryptographic revoke can broadcast. Blocker (3) is unchanged from
the deploy path — the same bundler config the kernel was
provisioned through is reused at revoke-time.

1. ✅ **`@zerodev/sdk` + `@zerodev/ecdsa-validator` +
   `@zerodev/permissions@5.6.3` deps installed.** All pinned in
   `chain_adapter/package.json` `dependencies`, not
   `devDependencies`, because the production cryptographic revoke
   path lazy-imports them at first use (see
   `chain_adapter/src/chains/base/revoke.ts`
   `executeCryptographicRevoke`). A runtime image built with
   `npm ci --omit=dev` still carries these packages and can honor
   `permission`-block dispatches.
2. ⏳ **Per-account sudo signer for revoke — config wired,
   provisioning still operator-driven.** `AdapterConfig.operatorPrivateKey`
   + `operatorAddress` are now first-class env vars validated at
   startup (placeholder rejection, derived-address match, refuses
   to conflate with `DELEGATION_SIGNER_KEY`). The adapter refuses
   to broadcast a cryptographic revoke without them and emits
   `state=revoke_failed, reason=operator_key_missing` — never
   silently downgrades to sentinel. The operator still has to
   provision the actual key (HSM / KMS / secrets-manager policy
   open as a separate hardening track per Subagent D's review).
3. ⏳ **Bundler RPC + paymaster (or native gas) for the revoke
   UserOp.** `provision-kernel.ts --broadcast` already routes the
   deploy through a bundler; the cryptographic revoke uses the
   same `BUNDLER_RPC_URL` env. No new infrastructure once the
   operator is provisioned. Paymaster is unwired — the revoke
   UserOp carries `value: 0n` so native funding on the smart
   account is sufficient.
4. ✅ **Persistence of the serialized plugin blob + denormalized
   header.** Phoenix's `delegations` table now carries
   `permission_blob`, `permission_id`, `validation_id`,
   `kernel_version`, `permission_package_version`,
   `installed_at_block`, and `install_tx_hash` (migration
   `20260427120000_add_delegation_permission_artifacts.exs`). All
   nullable; legacy rows stay sentinel. The `Bank.Delegations`
   context decodes the artifacts from `granted` callbacks and
   builds the wire-shaped `permission` block via
   `permission_dispatch_block/1`. **Open**: the adapter-side
   grant flow (`wallet_connect.js` + the upcoming
   `dispatch_grant_delegation`) does not yet emit a populated
   `granted` callback — until it does, no row carries artifacts
   and every revoke continues on the sentinel path. Tracked
   under `docs/wallet-connect.md` v1.1.
5. ✅ **`KernelPermissionPin` populated.**
   `chain_adapter/src/chains/base/permission_validator.ts` exports
   `KERNEL_PERMISSION_PIN` with the canonical signer + policy
   module addresses sourced from `@zerodev/permissions@5.6.3` and
   the kernel-account `uninstallValidation(bytes21,bytes,bytes)`
   ABI fragment sourced from `KernelV3_1AccountAbi` in
   `@zerodev/sdk@5.5.10`. Both halves are verified by
   `test/permission-validator-pin.test.ts` so a future package bump
   that drifts cannot land silently. The cryptographic revoke
   encoder consumes the pin's `uninstallValidationFunction` ABI
   fragment directly.
6. ✅ **Decision on the on-the-wire shape of `delegation_id`:
   4-byte `permissionId` hex (10 chars).** New rows write
   `permission_id` as the `delegation_id` so an operator pasting
   the field into Etherscan or `kernel.permissionConfig(bytes4)`
   gets a real lookup. The denormalized `permission.permission_id`
   field on the dispatch payload carries the same value
   redundantly; the adapter feeds `permission.validation_id` to
   `uninstallValidation` rather than re-deriving from
   `delegation_id`, so the wire field stays decorative for
   cryptographic rows. Sentinel-era rows continue to send `del_…`
   placeholders unchanged.
7. ⏳ **Decision on whether per-permission revoke is the right
   design, or whether session-key rotation / `invalidateNonce` is a
   better fit for our threat model.** Per-permission revoke is now
   the default code path (#58 lands the encoder + executor); the
   `invalidateNonce` coarser path is documented as the operator
   recovery option when the per-permission attempt fails closed
   (e.g. corrupted blob, missing operator key, package version
   drift). Either path stays available; this is no longer a
   blocker.

## Issue impact (current state)

- **#83** — **CLOSED.** `KernelPermissionPin` populated against
  `@zerodev/permissions@5.6.3`; tripwire test enforces package +
  ABI drift. The cryptographic revoke encoder in
  `chain_adapter/src/chains/base/uninstall_validation.ts`
  consumes the pin's `uninstallValidationFunction` directly.
- **#84** — **CLOSED** on Base Sepolia. The smart account at
  `0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C` was deployed and
  verified against the same Kernel v3.1 deployment values
  `provision-kernel.ts` pins (factory
  `0xaac5D4240AF87249B3f71BC8E4A2cae074A3E419`, implementation
  `0xBAC849bB641841b44E965fB01A4Bf5F074f84b4D`, root validator
  `0x845ADb2C711129d4f3966735eD98a9F09fC4cE57`); deploy tx
  `0xe6ad5263ed7023ee6b5f7dd2c529efda27ccb4cebce449c52a58a882c9fe4724`.
- **#58** — "swap sentinel for cryptographic revoke". **Encoder +
  executor + persistence + config landed under this PR.** The
  cryptographic path is wired end-to-end and runs the moment two
  operator-driven gates close: (a) provisioning a real
  `OPERATOR_PRIVATE_KEY` matching the kernel's root validator EOA
  in adapter env, and (b) the grant flow emitting a `granted`
  callback that populates the artifact columns. Until both are in
  place every revoke continues to take the sentinel path; the
  cryptographic path's fail-closed posture refuses to downgrade
  silently if a `permission` block arrives but the operator key is
  missing.
- **#31** — umbrella for "true cryptographic revoke". Closes
  when the first end-to-end cryptographic revoke confirms on
  chain (operator runbook step, not blocked by code).

## What survives the correction

- The wire-level `delegation_id` field in
  `priv/adapter/contract.md` and `DispatchRevokeDelegationSchema`.
- The ERC-7579 outer-execute envelope pin in
  `chain_adapter/src/chains/base/erc7579.ts` (selector
  `0xe9ae5c53`). Independent of the permission system above it.
- The sentinel revoke body itself (`SimpleAccount.execute(self, 0,
  0x)`). Anchors the revoke attempt on chain; does NOT
  cryptographically disable the delegation. The sentinel-pin
  tripwire test is unchanged.
- Phoenix's delegation state machine
  (`active → revoking → revoked | revoke_failed`) and the dispatch
  contract.
