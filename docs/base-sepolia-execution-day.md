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
> The provisioning-script templates have been replaced with
> deferred stubs and the env var has been removed. Today the
> execution-day flow is: smart-account deploy + env hygiene +
> sentinel-era smokes; per-permission cryptographic revoke is
> blocked on the SDK integration described in the integration
> doc.

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
inputs), `mode: awaiting_zerodev_integration`, `chain_id: 84532`,
redacted private-key fields. No RPC.

**If not:** Common failures: placeholder still set, wrong chain id
(`8453` vs `84532`), RPC URL missing scheme, trailing whitespace.

## Step 2 — Adapter env preflight

```sh
cd chain_adapter
sh scripts/check-env.sh
# or: ( set -a; . ./.env; sh scripts/check-env.sh )
```

**Expect:** `PASS`. `mode: sentinel-era (awaiting ZeroDev SDK
integration)`.

**If not:** `check-env.sh` is no-network; any failure is local env.
Fix each flagged `MISSING`, `PLACEHOLD`, `WHITESPCE`, or `MALFORMED`.

## Step 3 — Fund operator EOA `[chain]`

**Do:** Send Base Sepolia ETH to `OPERATOR_ADDRESS` (NOT the
delegation signer) from a faucet; target 0.01 ETH.

**If not:** Faucet rate-limit or wrong chain — check Sepolia
Basescan for the balance.

## Step 4 — Deploy Kernel v3 smart account `[chain]`

The previous `chain_adapter/scripts/provision-kernel.ts` template
is currently a **deferred stub** — see
[`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md)
for why and the hard-blocker list.

Operators who want a Kernel v3 account on Base Sepolia today
construct one in a separate workspace using `@zerodev/sdk`
directly (the runtime adapter does not depend on the SDK), and
record:

- the resulting smart account address (for `SMART_ACCOUNT_ADDRESS`);
- the factory address used (for `KERNEL_FACTORY_ADDRESS`);
- the deployment transaction hash + chain id;
- the kernel implementation address.

**Expect:** Stable address you can re-derive from the same salt.

**If not:** The SDK error names the cause (zero balance, wrong
chain, malformed factory).

## Step 5 — Install permissions on the account `[chain]` — DEFERRED

Per-permission install requires the ZeroDev SDK integration in the
runtime — see the integration doc. Today the smart account stays
in its base configuration; the adapter's revoke path is sentinel-
only and does not exercise per-permission install.

## Step 6 — Bind addresses + restart adapter

**Do:** Set `SMART_ACCOUNT_ADDRESS`, `KERNEL_FACTORY_ADDRESS`,
`DELEGATION_SIGNER_KEY` on the adapter host (Fly secrets, AWS
Secrets Manager, etc.). Restart the container. Re-run
`sh scripts/check-env.sh`.

**Expect:** `PASS`. `mode: sentinel-era (awaiting ZeroDev SDK
integration)`.

**If not:** No-network check, so any `FAIL` is an env problem on
the host.

## Step 7 — Smokes `[chain]`

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

**If not:** See the FAIL tables in `smoke-tests.md`. Note that
`state: revoked` in sentinel-era mode means **on-chain anchored,
trust downgraded** — NOT cryptographically impossible. That
remains true until the ZeroDev SDK integration ships.

## After the day

- Commit the deployment journal (chain, addresses, hashes, deploy
  tx) to the team's internal records.
- Adapter stays in `mode: sentinel-era` until the SDK integration
  ships. The smoke `state: revoked` continues to mean trust
  downgrade only.
- Do NOT promote to Base mainnet until Sepolia is green
  end-to-end AND the cryptographic revoke (#58) has shipped
  against Sepolia. Mainnet re-rolls burn real ETH.

## Out of scope

- The full ZeroDev SDK integration (per-account sudo signer,
  plugin-blob persistence, `Kernel.uninstallValidation` wiring).
  See [docs/zerodev-permissions-integration.md](zerodev-permissions-integration.md).
- Incident response for failed cryptographic revokes once they
  ship (issue #38).
- Anything requiring chain access to validate — every step not
  marked `[chain]` is local.
