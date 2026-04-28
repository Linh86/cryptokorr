# Provisioning a Kernel v3 smart account on Base

Operator runbook for Kernel v3 smart-account provisioning on Base.

> **MODEL CORRECTION — 2026-04-23.** Earlier revisions of this
> runbook instructed operators to deploy "a Permission Validator
> module" at a single address and bind it to a `PERMISSION_VALIDATOR_ADDRESS`
> env var. That model was wrong: ZeroDev's `@zerodev/permissions`
> does not have a single deployable Permission Validator contract.
> See [`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md)
> for what the corrected ZeroDev model actually looks like and the
> hard blockers that have to be resolved before per-permission
> cryptographic revoke can ship. Until those land, the runtime is
> sentinel-era; operators do **not** capture or set any
> `PERMISSION_VALIDATOR_ADDRESS`.

Pairs with:

- [docs/smart-account-and-revoke-design.md](smart-account-and-revoke-design.md) — architectural decision (#56).
- [docs/zerodev-permissions-integration.md](zerodev-permissions-integration.md) — corrected ZeroDev permissions model and outstanding hard blockers.
- [docs/deploy.md](deploy.md) — generic Phoenix deploy procedure; this runbook is the chain-side prereq.
- [docs/operator-secrets-checklist.md](operator-secrets-checklist.md) — secrets the operator still needs to prepare.
- [docs/incident-runbook.md](incident-runbook.md) — what to do when revoke does not land.
- [`chain_adapter/README.md`](../chain_adapter/README.md) — adapter env table.
- [`chain_adapter/scripts/`](../chain_adapter/scripts/) — operator scripts. The provisioning + verification templates here are currently **deferred stubs** (see scripts/README.md); only `check-env.sh` is live.

Tracks: GitHub #84. The runbook is partial pending the ZeroDev SDK
integration described in
[`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md).

## Status

This runbook records the **smart-account deployment portion** of
provisioning as understood today. The corrected ZeroDev model
invalidated the previous "install a Permission Validator at a
recorded address" + "verify the validator's bytecode hash" steps —
those are deferred to the integration doc. The remainder (deploy a
Kernel v3 account, fund it, plumb the env vars the adapter actually
reads) is operationally meaningful and described below.

The `SMART_ACCOUNT_ADDRESS` shipped in the adapter's `.env.example`
is still a placeholder. The runtime is sentinel-era and stays that
way until the integration ships.

## End-state target

When the SDK integration is complete and an operator has provisioned
a Kernel v3 smart account, the adapter runtime needs (at minimum):

| Env var (adapter side)         | Bound to                                                                           |
| ------------------------------ | ---------------------------------------------------------------------------------- |
| `SMART_ACCOUNT_ADDRESS`        | The deployed Kernel v3 modular account address.                                    |
| `KERNEL_FACTORY_ADDRESS`       | The Kernel v3 factory used to deploy the account (recorded for redeploys / audit). |
| `DELEGATION_SIGNER_KEY`        | The EOA signing UserOperations against the smart account.                          |

Additional ZeroDev SDK env shape (per-account sudo key, plugin blob
storage, etc.) is part of the integration TODO and not yet decided —
see [`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md).
The previous `PERMISSION_VALIDATOR_ADDRESS` env has been removed.

Phoenix-side, no schema change is needed. `delegations.delegation_id`
remains a free-form string column; the adapter and Phoenix will
agree on its on-the-wire encoding when the integration lands.

## Vendor + chain choice

- **Account implementation: Kernel v3 (ZeroDev).** Decided in
  [#56](smart-account-and-revoke-design.md#a-kernel-v3-zerodev--chosen).
- **Network: Base.** Provision against **Base Sepolia first**
  (chain id `84532`); promote to **Base mainnet** (chain id `8453`)
  only after Sepolia is proven end-to-end and the SDK integration
  has shipped against Sepolia.
- **Bundler / paymaster: operator's existing provider.** ZeroDev,
  Pimlico, Alchemy AA, Stackup, etc. — the adapter is bundler-
  agnostic at the runtime level.

## Prerequisites the operator must have

1. **A funded operator EOA on the target Base network.** Used to pay
   gas for the smart-account deployment. Sepolia needs Base-Sepolia
   ETH from a faucet; mainnet needs real ETH. Keep this key separate
   from `DELEGATION_SIGNER_KEY` — they have different lifetimes and
   different blast radii.
2. **A Base RPC endpoint** (`https://sepolia.base.org`,
   `https://mainnet.base.org`, or a paid RPC).
3. **A bundler endpoint that supports ERC-4337 v0.7 on the target
   chain.** Same provider the runtime adapter will use is preferred.
4. **Node.js 22+ and a workspace separate from the production
   adapter container** for running provisioning scripts when they
   come back online.
5. **Access to set environment variables on the adapter host.**

## No-secret preflight from Phoenix

Before touching any funded key, run the Phoenix-side preflight. It
validates only presence and shape of operator inputs, prints
redacted values, and makes **no RPC calls**:

```sh
mix bank.kernel.preflight --phase deploy
mix bank.kernel.preflight --phase install
mix bank.kernel.preflight --phase verify
```

Each phase reports `mode: awaiting_zerodev_integration` until the
corrected SDK integration lands.

## Step 1 — Pick the smart-account address scheme

Kernel v3 smart accounts are deterministic — the address depends on
the factory + the implementation + the salt. Choose the salt
deliberately so a re-deploy yields a stable address. Document the
choice in the deployment journal.

## Step 2 — Deploy the Kernel v3 smart account

Operator-side action; not done from inside the runtime container.
`chain_adapter/scripts/provision-kernel.ts` is a real, no-secret-safe
template targeting Kernel v3.1.

### 2a. Dry-run (no secrets, no RPC)

Pure-local CREATE2 derivation. Confirms what smart-account address
your operator EOA will own:

```sh
cd chain_adapter
OPERATOR_ADDRESS=0x...your-eoa npx tsx scripts/provision-kernel.ts
```

The script prints a JSON receipt with the deterministic
`expected_smart_account_address`, the canonical factory and
implementation addresses, the ECDSA root validator address, and the
init-code hash. Record the receipt in the deployment journal — same
input always yields the same output, so this is the address you'll
fund + bind to the adapter.

### 2b. Broadcast (chain interaction)

Once the operator EOA is funded on Base Sepolia, deploy:

```sh
cd chain_adapter
OPERATOR_ADDRESS=0x...your-eoa \
OPERATOR_PRIVATE_KEY=0x...32-byte-hex \
BASE_RPC_URL=https://sepolia.base.org \
BUNDLER_RPC_URL=https://your-bundler.example/base-sepolia \
npx tsx scripts/provision-kernel.ts --broadcast
```

The script signs and submits a no-op UserOp through the bundler;
the EntryPoint deploys the kernel account from `initCode` on first
use. The receipt is augmented with `user_op_hash`,
`transaction_hash`, and `block_number`. Refuses to redeploy if the
address already has bytecode.

Record from the receipt:

- `expected_smart_account_address` → bind to the adapter as
  `SMART_ACCOUNT_ADDRESS`;
- `factory_address` → bind to `KERNEL_FACTORY_ADDRESS`;
- `transaction_hash` and `block_number` → deployment journal.

`--broadcast` is the ONLY way to interact with chain. Default
behaviour is dry-run.

## Step 3 — Verify the deployed account

Before binding the new kernel account to the adapter, confirm it
matches the pinned Kernel v3.1 deployment values:

```sh
cd chain_adapter
SMART_ACCOUNT_ADDRESS=0x...from-step-2 \
BASE_RPC_URL=https://sepolia.base.org \
npx tsx scripts/verify-installed-validator.ts
```

The script makes read-only RPC calls and prints a JSON receipt
with `findings` and an `overall_ok` boolean. Each finding compares
an on-chain observation against a pinned expectation:

- `is_deployed` — `eth_getCode` returns non-empty bytecode.
- `implementation_address` — EIP-1967 storage slot points at the
  pinned Kernel v3.1 implementation.
- `kernel_version` — `accountId()` resolves to `0.3.1`.
- `root_validator_address` — `rootValidator()` returns the
  canonical ECDSA validator for `>=0.3.1`.

Exit code is `0` iff every finding passes. `1` otherwise — do NOT
bind the address to the adapter env if verification fails.

## Step 4 — Install permissions on the account (deferred)

The runtime does not yet wire ZeroDev permissions end-to-end;
per-permission install requires the SDK integration tracked in
[`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md).
Until then, leave the account in its base configuration; the
adapter's revoke path is sentinel-only and does not exercise
permissions.

## Step 5 — Adapter env binding + hygiene

Set the values from Step 2 on the adapter host (Fly secrets, AWS
Secrets Manager, etc.) and run the env hygiene check:

```sh
sh chain_adapter/scripts/check-env.sh
```

Expected output: `mode: sentinel-era (awaiting ZeroDev SDK
integration)` plus `PASS: required envs look healthy`. The script
makes no network calls.

## Step 6 — Smoke tests

Once the adapter is configured and running, run the Phoenix smokes
(see [`docs/smoke-tests.md`](smoke-tests.md)):

```sh
mix bank.smoke.transfer
mix bank.smoke.revoke
```

In sentinel-era mode `mix bank.smoke.revoke` exercises the AA
plumbing end-to-end (`SimpleAccount.execute(self, 0, 0x)` UserOp,
bundler, callback) but does NOT cryptographically disable the
delegation. A successful smoke means "on-chain anchored, trust
downgraded", not "cryptographically impossible". Phoenix's state
machine fail-closes regardless.

## Re-roll procedure

If something goes wrong on Sepolia:

1. Pick a new salt for Step 1 and redeploy a fresh Kernel v3 account.
2. Update `SMART_ACCOUNT_ADDRESS` to the new value.
3. Re-run the env hygiene check + smokes.

The previous account remains on chain but is no longer bound to
the runtime config. There is no separate Permission Validator to
unbind in the corrected model.

On Base mainnet, treat re-rolls more conservatively — coordinate
with operator approvals and document rationale in the deployment
journal.

## Tracking

- #56 — Kernel v3 architectural decision. Landed.
- #84 — provisioning runbook + templates. **Partial.** Smart-account
  deployment portion is documented; the wrong-model template
  scripts are now deferred stubs. Closes when the SDK integration
  lands.
- #83 — pin contract for the corrected ZeroDev model. **Re-scoped.**
  See [`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md).
- #58 — sentinel → cryptographic revoke swap. Blocked on the SDK
  integration above.
- #31 — umbrella; closes when #58 closes.
