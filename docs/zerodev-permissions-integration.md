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

The list below has been narrowed: blockers (1) and the
smart-account-deploy half of (2) were resolved by the kernel
provisioning skeleton landing in
`chain_adapter/scripts/provision-kernel.ts` + dev-deps on
`@zerodev/sdk@5.5.10` and `@zerodev/ecdsa-validator@5.4.9`. The
remaining items still gate the cryptographic revoke (#58).

1. ✅ **`@zerodev/sdk` + `@zerodev/ecdsa-validator` deps installed.**
   Both are pinned in `chain_adapter/package.json` `devDependencies`
   so the production runtime image can omit them via
   `npm ci --omit=dev`. `@zerodev/permissions` is NOT yet a dep —
   it gets added when per-permission install lands as part of #58.
2. ⏳ **Per-account sudo signer for revoke.** `provision-kernel.ts`
   `--broadcast` mode signs the deploy UserOp with the operator EOA
   bound to `OPERATOR_ADDRESS`; that same EOA is the kernel's root
   ECDSA validator. The adapter runtime currently does NOT hold
   that key (`DELEGATION_SIGNER_KEY` is the runtime signer, not the
   root). Per-account sudo signer storage + secrets-management
   policy is still open.
3. ⏳ **Bundler RPC + paymaster (or native gas) for the revoke
   UserOp.** `provision-kernel.ts --broadcast` already routes the
   deploy through a bundler; the revoke path will reuse the same
   bundler config. No new infrastructure once the operator is
   provisioned.
4. ⏳ **Persistence of the serialized plugin blob (or raw policy +
   signer reconstruction params) at grant-time** so the adapter
   can rebuild the plugin at revoke-time. Phoenix's
   `delegations.delegation_id` is still opaque-string-only.
5. ⏳ **Populate `KernelPermissionPin`** with the chosen signer +
   policy module addresses + accepted `@zerodev/permissions` package
   version range. Only meaningful once #58 is being implemented;
   the slot stays `null` until then.
6. ⏳ **Decision on the on-the-wire shape of `delegation_id`.**
   Phoenix's column is opaque; either side has to commit to one of:
   4-byte `permissionId` hex (10 chars), 21-byte `validationId` hex
   (44 chars), or a serialized plugin blob (kilobytes per
   delegation). Storing both `permissionId` and the blob is also
   reasonable.
7. ⏳ **Decision on whether per-permission revoke is the right
   design, or whether session-key rotation / `invalidateNonce` is a
   better fit for our threat model.** Per-permission revoke is
   surgical but requires plugin-blob persistence; rotation is
   coarser but simpler.

## Issue impact (current state)

- **#83** — re-scoped to "populate the `KernelPermissionPin` slot
  with the verified signer + policy module addresses + version
  range". Slot is exported and `null` in
  `chain_adapter/src/chains/base/permission_validator.ts`. Blocked
  on the per-permission install design landing in #58.
- **#84** — **partially complete.**
  `chain_adapter/scripts/provision-kernel.ts` is now a real
  no-secret-safe Kernel v3.1 provisioning template (dry-run by
  default, `--broadcast` for chain interaction).
  `chain_adapter/scripts/verify-installed-validator.ts` is a
  real read-only verification template. **#84 stays OPEN until an
  operator runs `provision-kernel.ts --broadcast` end-to-end on
  Base Sepolia and records the resulting smart-account address in
  the deployment journal.** No on-chain provisioning has been
  performed from this repo.
- **#58** — "swap sentinel for cryptographic revoke". Plumbing
  (`delegation_id` + `config` threading) was landed under earlier
  commits. The swap depends on hard blockers (4)–(7) above. Blocker
  (1) is now resolved.
- **#31** — umbrella for "true cryptographic revoke". Still open;
  closes when #58 closes.

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
