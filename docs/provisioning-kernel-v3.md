# Provisioning a Kernel v3 smart account on Base

Operator runbook for Kernel v3 smart-account provisioning on Base.

> **MODEL CORRECTION — 2026-04-23.** Earlier revisions of this
> runbook instructed operators to deploy "a Permission Validator
> module" at a single address and bind it to a `PERMISSION_VALIDATOR_ADDRESS`
> env var. That model was wrong: ZeroDev's `@zerodev/permissions`
> does not have a single deployable Permission Validator contract.
> See [`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md)
> for the corrected ZeroDev model. Cryptographic grant + revoke
> shipped live on Base Sepolia under PR #132 (#58 / #31 closed);
> operators still do **not** capture or set any
> `PERMISSION_VALIDATOR_ADDRESS`. The day-of smoke runbook is in
> [`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md).

Pairs with:

- [docs/smart-account-and-revoke-design.md](smart-account-and-revoke-design.md) — architectural decision (#56).
- [docs/zerodev-permissions-integration.md](zerodev-permissions-integration.md) — corrected ZeroDev permissions model and outstanding hard blockers.
- [docs/deploy.md](deploy.md) — generic Phoenix deploy procedure; this runbook is the chain-side prereq.
- [docs/operator-secrets-checklist.md](operator-secrets-checklist.md) — secrets the operator still needs to prepare.
- [docs/incident-runbook.md](incident-runbook.md) — what to do when revoke does not land.
- [`chain_adapter/README.md`](../chain_adapter/README.md) — adapter env table.
- [`chain_adapter/scripts/`](../chain_adapter/scripts/) — operator scripts. `provision-kernel.ts`, `verify-installed-validator.ts`, and `check-env.sh` are all live, no-secret-safe templates.

Tracks: GitHub #84 (smart-account deploy) + #58 / #31
(cryptographic grant + revoke, closed by PR #132 against Base
Sepolia).

## Status

This runbook records the **smart-account deployment portion** of
provisioning. The corrected ZeroDev model invalidated the previous
"install a Permission Validator at a recorded address" + "verify
the validator's bytecode hash" steps — see the integration doc.
The remainder (deploy a Kernel v3 account, fund it, plumb the env
vars the adapter actually reads) is described below; the
permission-install side runs through the adapter runtime
(`POST /dispatch/grant_delegation`, see the MVP smoke runbook).

The `SMART_ACCOUNT_ADDRESS` shipped in the adapter's `.env.example`
is still a placeholder — operators bind the value they receive
from `provision-kernel.ts`.

## End-state target

Once an operator has provisioned a Kernel v3 smart account, the
adapter runtime needs:

| Env var (adapter side)         | Bound to                                                                           |
| ------------------------------ | ---------------------------------------------------------------------------------- |
| `SMART_ACCOUNT_ADDRESS`        | The deployed Kernel v3 modular account address.                                    |
| `KERNEL_FACTORY_ADDRESS`       | The Kernel v3 factory used to deploy the account (recorded for redeploys / audit). |
| `DELEGATION_SIGNER_KEY`        | Runtime session key — signs UserOperations under the installed permission.         |
| `OPERATOR_PRIVATE_KEY`         | Kernel root validator (sudo) key — signs grant install + cryptographic revoke. Required for #58 cryptographic path. |
| `OPERATOR_ADDRESS`             | EOA derived from `OPERATOR_PRIVATE_KEY` (paste-mismatch guard).                    |

`DELEGATION_SIGNER_KEY` and `OPERATOR_PRIVATE_KEY` MUST derive to
different EOAs; the adapter refuses any config where they
collide. The previous `PERMISSION_VALIDATOR_ADDRESS` env has been
removed.

Phoenix-side, the `delegations` table now carries `permission_blob`,
`permission_id`, `validation_id`, `kernel_version`,
`permission_package_version`, `installed_at_block`,
`install_tx_hash`, and `session_signer_address`. New rows write
the 4-byte `permission_id` (10 hex chars) into `delegation_id`;
legacy rows continue to use `del_…` placeholders. See
[`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md).

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

Each phase reports `mode: awaiting_zerodev_integration` — that
label predates PR #132 and is now stale at the runtime level
(cryptographic grant + revoke are live), but the preflight tool
itself has not yet been re-labeled. Operators can ignore the
mode string and proceed through the runbook; the on-chain path
is exercised by the MVP smoke runbook
([`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md)).

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

## Step 4 — Install permissions on the account

Permission install runs through the adapter runtime, not from
this provisioning script. Once the kernel account is deployed
and the adapter env is bound (see Step 5), kick off a connect
via `POST /v1/connect/smart_account`; the adapter's
`executeGrant` builds the ZeroDev `PermissionPlugin`, installs
it via the SDK's first-UserOp enable-signature flow, and emits
a `granted` callback whose `permission` block carries the
artifacts Phoenix persists. The full smoke flow is in
[`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md). The
integration doc explains the on-chain shape:
[`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md).

## Step 5 — Adapter env binding + hygiene

Set the values from Step 2 on the adapter host (Fly secrets, AWS
Secrets Manager, etc.) and run the env hygiene check:

```sh
sh chain_adapter/scripts/check-env.sh
```

Expected output: `mode: sentinel-era (awaiting ZeroDev SDK
integration)` plus `PASS: required envs look healthy`. The
`mode` string is out of date relative to runtime — cryptographic
grant + revoke landed under PR #132 — and the script itself has
not yet been re-labeled. The `PASS` line is what matters; the
script makes no network calls.

## Step 6 — Smoke tests

Once the adapter is configured and running, run the Phoenix smokes
(see [`docs/smoke-tests.md`](smoke-tests.md)):

```sh
mix bank.smoke.transfer
mix bank.smoke.revoke
```

For rows without `permission` artifacts (legacy or
freshly-granted-without-the-grant-flow), `mix bank.smoke.revoke`
exercises the sentinel AA plumbing
(`SimpleAccount.execute(self, 0, 0x)` UserOp, bundler, callback)
and a successful run means "on-chain anchored, trust
downgraded", not "cryptographically impossible". For rows with
`permission` artifacts (default for new grants under #58 / #31,
closed by PR #132) the cryptographic
`Kernel.uninstallValidation(...)` path runs instead — see
[`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md). Phoenix's
state machine fail-closes regardless of which path runs.

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
- #84 — provisioning runbook + templates. Closed.
  `provision-kernel.ts` and `verify-installed-validator.ts` are
  real, no-secret-safe templates targeting Kernel v3.1.
- #83 — `KernelPermissionPin` populated. Closed. See
  [`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md).
- #58 — sentinel → cryptographic revoke swap. **Closed by PR
  #132.** Operator smoke runbook:
  [`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md).
- #31 — umbrella for cryptographic revoke. **Closed by PR
  #132.**
