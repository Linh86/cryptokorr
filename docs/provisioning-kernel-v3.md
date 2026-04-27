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
The previous `chain_adapter/scripts/provision-kernel.ts` template
that drove this step has been replaced with a deferred stub —
[`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md)
lists the hard blockers (SDK runtime deps, sudo signer per kernel
account, plugin-blob persistence) that have to be resolved before
the template can be rewritten.

For now an operator who wants a Kernel v3 account on Base Sepolia
can construct one in a separate workspace using `@zerodev/sdk`
directly. Record:

- the resulting smart account address (for `SMART_ACCOUNT_ADDRESS`);
- the factory address used (for `KERNEL_FACTORY_ADDRESS`);
- the deployment transaction hash + chain id;
- the kernel implementation address.

## Step 3 — Install permissions on the account

**Deferred.** The runtime does not yet wire ZeroDev permissions
end-to-end; per-permission install requires the SDK integration.
Until then, leave the account in its base configuration; the
adapter's revoke path is sentinel-only and does not exercise
permissions.

## Step 4 — Adapter env binding + hygiene

Set the values from Step 2 on the adapter host (Fly secrets, AWS
Secrets Manager, etc.) and run the env hygiene check:

```sh
sh chain_adapter/scripts/check-env.sh
```

Expected output: `mode: sentinel-era (awaiting ZeroDev SDK
integration)` plus `PASS: required envs look healthy`. The script
makes no network calls.

## Step 5 — Smoke tests

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
