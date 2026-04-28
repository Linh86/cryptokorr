# Base Sepolia execution-day runbook

Tight time-ordered checklist for the Base Sepolia execution day.
Cross-references the deeper runbooks; do not duplicate their
content.

> **MODEL CORRECTION — 2026-04-23.** Earlier revisions of this
> runbook drove an operator through "Phase 2: install Permission
> Validator" and "Step 6: verify validator + run receipt check"
> against a single `PERMISSION_VALIDATOR_ADDRESS`. That model was
> wrong — `@zerodev/permissions` does not have a single
> deployable validator contract. See
> [`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md).
> The env var has been removed. PR #132 closed #58 / #31 with
> live cryptographic grant + revoke on Base Sepolia; the
> day-of smoke for the cryptographic path lives in
> [`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md). The flow
> below covers the chain-side prerequisites (smart-account
> deploy, env hygiene) before the smoke runs.

Pairs with:

- [docs/zerodev-permissions-integration.md](zerodev-permissions-integration.md)
- [docs/operator-secrets-checklist.md](operator-secrets-checklist.md)
  / [docs/operator-secrets-checklist-cs.md](operator-secrets-checklist-cs.md)
- [docs/provisioning-kernel-v3.md](provisioning-kernel-v3.md)
- [docs/smoke-tests.md](smoke-tests.md)
- [chain_adapter/scripts/README.md](../chain_adapter/scripts/README.md)

`[chain]` marks steps that touch on-chain state.

## Pre-day

**Do:** Complete `operator-secrets-checklist.md`; record values in
the team password manager under `CryptoBank / Base Sepolia / Chain
Adapter`.

**Expect:** Two different bearer secrets, two different EOA keys,
funded operator EOA on Base Sepolia, RPC + bundler URLs, optional
`KERNEL_FACTORY_ADDRESS`. Leave `SMART_ACCOUNT_ADDRESS` blank.

**If not:** Do not proceed — a missing or reused key here becomes
an irreversible mainnet mistake later.

## Step 1 — Phoenix preflight

```sh
mix bank.kernel.preflight --phase deploy
mix bank.kernel.preflight --phase verify    # before adapter bind
```

**Expect:** `status: ready` (or `:blocked` listing the missing
inputs), `mode: awaiting_zerodev_integration` (stale label from
before PR #132 — runtime is no longer awaiting), `chain_id: 84532`,
redacted private-key fields. No RPC.

**If not:** Common failures: placeholder still set, wrong chain id
(`8453` vs `84532`), RPC URL missing scheme, trailing whitespace.

## Step 2 — Adapter env preflight

```sh
cd chain_adapter
sh scripts/check-env.sh
# or: ( set -a; . ./.env; sh scripts/check-env.sh )
```

**Expect:** `PASS`. The `mode: sentinel-era (awaiting ZeroDev
SDK integration)` line is stale relative to runtime (PR #132
landed cryptographic grant + revoke); the `PASS` is what
matters.

**If not:** `check-env.sh` is no-network; any failure is local env.
Fix each flagged `MISSING`, `PLACEHOLD`, `WHITESPCE`, or `MALFORMED`.

## Step 3 — Fund operator EOA `[chain]`

**Do:** Send Base Sepolia ETH to `OPERATOR_ADDRESS` (NOT the
delegation signer) from a faucet; target 0.01 ETH.

**If not:** Faucet rate-limit or wrong chain — check Sepolia
Basescan for the balance.

## Step 4a — Derive expected smart-account address (no chain)

Pure-local CREATE2 derivation. No RPC, no secrets, no broadcast.
Run before funding so you know what address to fund.

```sh
cd chain_adapter
OPERATOR_ADDRESS=0x...your-eoa npx tsx scripts/provision-kernel.ts
```

**Expect:** JSON receipt on stdout with
`expected_smart_account_address`. Same input → same output, every
run.

**If not:** `provision-kernel.ts` errors are env-shape problems
(missing/placeholder/malformed `OPERATOR_ADDRESS`).

## Step 4b — Deploy Kernel v3 smart account `[chain]`

```sh
cd chain_adapter
OPERATOR_ADDRESS=0x...your-eoa \
OPERATOR_PRIVATE_KEY=0x...32-byte-hex \
BASE_RPC_URL=https://sepolia.base.org \
BUNDLER_RPC_URL=https://your-bundler.example/base-sepolia \
npx tsx scripts/provision-kernel.ts --broadcast
```

**Expect:** Same JSON receipt with `mode: "broadcast"`,
augmented with `user_op_hash`, `transaction_hash`, `block_number`.

**If not:** Common causes: insufficient balance on the operator
EOA (faucet not landed); wrong chain id; bundler URL invalid;
`OPERATOR_PRIVATE_KEY` doesn't derive to `OPERATOR_ADDRESS` (the
script refuses to broadcast in that case). Re-derive with `4a` to
confirm the expected address.

## Step 5 — Verify the deployment `[chain]`

Read-only check that the deployed kernel matches pinned values.
No secrets.

```sh
cd chain_adapter
SMART_ACCOUNT_ADDRESS=0x...from-step-4a \
BASE_RPC_URL=https://sepolia.base.org \
npx tsx scripts/verify-installed-validator.ts
```

**Expect:** JSON receipt with `overall_ok: true` and exit `0`.
Each `findings[]` entry confirms one pinned expectation
(`is_deployed`, `implementation_address`, `kernel_version`,
`root_validator_address`).

**If not:** Exit `1` and `overall_ok: false` mean the on-chain
state doesn't match the pinned Kernel v3.1 deployment. Do NOT
bind the address to the adapter; investigate (different version,
different owner, wrong chain).

## Step 6 — Install permissions on the account `[chain]`

Permission install runs through the adapter runtime
(`POST /dispatch/grant_delegation`), not from a script here. After
the adapter env is bound (Step 7), kick off a connect via
`POST /v1/connect/smart_account`; the adapter's `executeGrant`
builds the ZeroDev `PermissionPlugin`, installs it via the SDK's
first-UserOp enable-signature flow, and emits a `granted`
callback. The full smoke flow is in
[`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md).

## Step 7 — Bind addresses + restart adapter

**Do:** Set `SMART_ACCOUNT_ADDRESS`, `KERNEL_FACTORY_ADDRESS`,
`DELEGATION_SIGNER_KEY` on the adapter host (Fly secrets, AWS
Secrets Manager, etc.). Restart the container. Re-run
`sh scripts/check-env.sh`.

**Expect:** `PASS`. The `mode: sentinel-era (awaiting ZeroDev
SDK integration)` line is stale relative to runtime (PR #132
landed cryptographic grant + revoke); the `PASS` is what
matters.

**If not:** No-network check, so any `FAIL` is an env problem on
the host.

## Step 8 — Smokes `[chain]`

Runbook: `smoke-tests.md`.

```sh
ADAPTER_BASE_URL=... ADAPTER_DISPATCH_SECRET=... ADAPTER_CALLBACK_SECRET=... \
SMART_ACCOUNT_ID=... DELEGATION_ID=... TARGET_ADDRESS=0x...DeAD AMOUNT=1 \
mix bank.smoke.transfer

ADAPTER_BASE_URL=... ADAPTER_DISPATCH_SECRET=... ADAPTER_CALLBACK_SECRET=... \
SMART_ACCOUNT_ID=... \
mix bank.smoke.revoke
```

**Expect:** `PASS` + exit 0 for both.

**If not:** See the FAIL tables in `smoke-tests.md`. For rows
without `permission` artifacts (legacy / non-grant-flow rows),
`state: revoked` means **on-chain anchored, trust downgraded** —
NOT cryptographically impossible. For rows with artifacts (new
grants under PR #132), `revoked` additionally means the kernel
rejects further user-ops from the disabled permission. The
cryptographic-path smoke is the day-of focus and lives in
[`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md).

## After the day

- Commit the deployment journal (chain, addresses, hashes, deploy
  tx) to the team's internal records.
- Cryptographic grant + revoke shipped on Base Sepolia under PR
  #132 (#58 / #31 closed). For rows with `permission` artifacts
  the revoke disables the delegation at the contract level; for
  rows without, the legacy sentinel anchor still runs.
- Do NOT promote to Base mainnet until the operator's own
  Sepolia smoke (per
  [`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md)) is green
  end-to-end. Mainnet re-rolls burn real ETH.

## Out of scope

- The cryptographic grant + revoke smoke itself — that lives in
  [`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md).
- Incident response for failed cryptographic revokes (issue #38);
  failure-code triage is in the smoke runbook and
  [`docs/incident-runbook.md`](incident-runbook.md).
- Anything requiring chain access to validate — every step not
  marked `[chain]` is local.
