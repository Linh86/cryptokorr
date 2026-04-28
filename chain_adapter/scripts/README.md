# Adapter operator scripts

Operator-side templates for Kernel v3 smart-account provisioning on
Base. They live alongside the adapter codebase but are NOT part of
the adapter runtime — `tsconfig.json` excludes them and `vitest`
only matches `*.test.ts`. Their dependencies (`@zerodev/sdk`,
`@zerodev/ecdsa-validator`) are kept in `devDependencies` so a
production runtime image built with `npm ci --omit=dev` does not
ship the SDK.

## Status

`provision-kernel.ts` and `verify-installed-validator.ts` were
previously deferred stubs after the ZeroDev model correction. They
are now implemented as real, no-secret-safe templates targeting
**Kernel v3.1** on Base Sepolia (default) or Base mainnet:

- Dry-run by default — pure-local CREATE2 derivation, no RPC, no
  secrets, no broadcast.
- Read-only verification of an already-deployed kernel account.
- Real chain interaction is **opt-in via `--broadcast`** on
  `provision-kernel.ts`.

Per-permission install + cryptographic revoke remain DEFERRED — see
[`docs/zerodev-permissions-integration.md`](../../docs/zerodev-permissions-integration.md).
The runtime is sentinel-era until that integration ships.

## Inventory

| Script | What it does | Modes |
| --- | --- | --- |
| [`provision-kernel.ts`](provision-kernel.ts) | Derives the deterministic Kernel v3.1 smart-account address for `(OPERATOR_ADDRESS, KERNEL_ACCOUNT_INDEX)`. With `--broadcast`, signs + submits the deploy UserOp through the bundler. | dry-run (default) / `--broadcast` |
| [`verify-installed-validator.ts`](verify-installed-validator.ts) | Read-only RPC checks against the configured `SMART_ACCOUNT_ADDRESS`: deployed bytecode, kernel implementation, kernel version, root validator, current nonce. | always read-only |
| [`check-env.sh`](check-env.sh) | Adapter runtime env hygiene check: every required adapter env is present, non-placeholder, well-shaped. No network calls. | always offline |

## `provision-kernel.ts`

```sh
# Dry-run: derive the expected smart-account address.
OPERATOR_ADDRESS=0x...your-eoa npx tsx scripts/provision-kernel.ts

# Broadcast: deploy on Base Sepolia. Requires the EOA to be funded.
OPERATOR_ADDRESS=0x...your-eoa \
OPERATOR_PRIVATE_KEY=0x...32-byte-hex \
BASE_RPC_URL=https://sepolia.base.org \
BUNDLER_RPC_URL=https://your-bundler.example/base-sepolia \
npx tsx scripts/provision-kernel.ts --broadcast
```

Required env (always):

- `OPERATOR_ADDRESS` — public EOA address that owns the kernel
  account. The kernel root ECDSA validator binds to this.

Optional env (always):

- `KERNEL_ACCOUNT_INDEX` — salt for CREATE2 derivation (default `0`).
  Same EOA + same index → same kernel address. Increment to mint
  multiple kernel accounts owned by the same EOA.
- `BASE_CHAIN_ID` — `84532` (Sepolia, default) or `8453` (mainnet).

Required env (`--broadcast` only):

- `BASE_RPC_URL` — Base RPC endpoint (https://...).
- `BUNDLER_RPC_URL` — ERC-4337 v0.7 bundler endpoint (https://...).
- `OPERATOR_PRIVATE_KEY` — 0x-prefixed 32-byte hex; must derive to
  `OPERATOR_ADDRESS`. The script refuses to broadcast on mismatch.

Output: a JSON receipt on stdout (schema documented as
`DryRunReceipt` / `BroadcastReceipt` types in `provision-kernel.ts`).
Operators record the receipt in their deployment journal and feed
`expected_smart_account_address` into the adapter env as
`SMART_ACCOUNT_ADDRESS`.

The script makes **no network calls** in dry-run mode. It refuses
to redeploy a kernel account that already has bytecode on chain.

## `verify-installed-validator.ts`

```sh
SMART_ACCOUNT_ADDRESS=0x...derived-from-provision-kernel \
BASE_RPC_URL=https://sepolia.base.org \
npx tsx scripts/verify-installed-validator.ts
```

Required env:

- `SMART_ACCOUNT_ADDRESS` — the kernel account address from
  provisioning.
- `BASE_RPC_URL` — Base RPC endpoint.

Optional env:

- `BASE_CHAIN_ID` — same as above.

Output: a JSON receipt on stdout listing `findings` (one per pinned
expectation) and an `overall_ok` boolean. Exit `0` iff every read
matches the pinned Kernel v3.1 deployment values; exit `1`
otherwise. Read-only — no secrets, no broadcasts.

The script intentionally does **not** verify a "Permission
Validator address" or pin a `disablePermission` ABI fragment —
those concepts do not exist in ZeroDev's permissions architecture.
See the integration doc above for what the eventual cryptographic
revoke targets (`Kernel.uninstallValidation` on the smart account
itself).

## `check-env.sh`

No-secret, no-network. Validates that every required adapter env is
present, non-placeholder, and well-shaped (addresses are 0x+20
bytes, no trailing whitespace). Reports `mode: sentinel-era
(awaiting ZeroDev SDK integration)` — there used to be a tri-state
mode keyed on a `PERMISSION_VALIDATOR_ADDRESS` env var; both inputs
were artefacts of a wrong-model assumption and have been removed.

## What these scripts do NOT do

- They do not install ZeroDev permissions on the kernel account.
  Per-permission install and cryptographic revoke depend on the
  full SDK integration in
  [`docs/zerodev-permissions-integration.md`](../../docs/zerodev-permissions-integration.md).
- They do not modify any state in Phoenix.
- They do not write to disk; receipts go to stdout.
- They do not depend on any hosted ZeroDev API. The dry-run path
  is pure-local CREATE2; broadcast goes through the operator's own
  bundler.
