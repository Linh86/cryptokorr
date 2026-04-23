# Base Sepolia execution day — sequenced operator checklist

Time-ordered pointer sheet for the operator running Kernel v3
provisioning + adapter bring-up against **Base Sepolia**. Does not
replace the runbooks below — sequences them and names the **no-secret
preflight** for each step so most errors are caught locally before
any chain action.

References (read these; this doc only tells you the order):

- [`operator-secrets-checklist.md`](operator-secrets-checklist.md) — secret + env prep ([Czech](operator-secrets-checklist-cs.md)).
- [`provisioning-kernel-v3.md`](provisioning-kernel-v3.md) — full provisioning runbook (source of truth).
- [`deploy.md`](deploy.md) — adapter env strictness, three-mode table.
- [`smoke-tests.md`](smoke-tests.md) — transfer + revoke smokes.
- [`chain_adapter/scripts/README.md`](../chain_adapter/scripts/README.md) — `check-env.sh` + provisioning templates.

Steps marked `[chain]` touch the chain; everything else is local /
no-network and can be re-run free.

## Pre-day

**Do:** Complete `operator-secrets-checklist.md`; record values in
the team password manager under `CryptoBank / Base Sepolia / Chain
Adapter`.

**Expect:** Two different bearer secrets, two different EOA keys,
funded operator EOA on Base Sepolia, RPC + bundler URLs, confirmed
`KERNEL_FACTORY_ADDRESS` + `PERMISSION_VALIDATOR_ADDRESS`. Leave
`SMART_ACCOUNT_ADDRESS` blank.

**If not:** Do not proceed — a missing or reused key here becomes an
irreversible mainnet mistake later.

## Step 1 — Phoenix preflight

```sh
mix bank.kernel.preflight --phase deploy
mix bank.kernel.preflight --phase install    # after Step 4 lands
mix bank.kernel.preflight --phase verify     # before Step 6
```

**Expect:** `status: green`, `mode: kernel_candidate`,
`chain_id: 84532`, redacted private-key fields. No RPC.

**If not:** Common failures: placeholder still set, wrong chain id
(`8453` vs `84532`), RPC URL missing scheme, trailing whitespace.

## Step 2 — Adapter env preflight

```sh
cd chain_adapter
sh scripts/check-env.sh
# or: ( set -a; . ./.env; sh scripts/check-env.sh )
```

**Expect:** `PASS`. `mode: sentinel-era` (unset is correct for
first-time bring-up) or `mode: straddle` (acceptable if env set
before #83 lands).

**If not:** `check-env.sh` is no-network; any failure is local env.
Fix each flagged `MISSING`, `PLACEHOLD`, `WHITESPCE`, or `MALFORMED`.

## Step 3 — Fund operator EOA `[chain]`

**Do:** Send Base Sepolia ETH to `OPERATOR_ADDRESS` (NOT the
delegation signer) from a faucet; target 0.01 ETH.

**If not:** Faucet rate-limit or wrong chain — check Sepolia
Basescan for the balance.

## Step 4 — Phase 1: deploy smart account `[chain]`

Runbook: `provisioning-kernel-v3.md` Step 4.

```sh
npx tsx /path/to/chain_adapter/scripts/provision-kernel.ts
```

**Expect:** Stdout prints `smart_account_address`,
`deploy_userop_hash`, `deploy_tx_hash`. Record all three.

**If not:** Script refuses on placeholder env or zero balance. If
user-op submission fails, the bundler error names the cause.

## Step 5 — Phase 2: install Permission Validator `[chain]`

Runbook: `provisioning-kernel-v3.md` Step 5.

```sh
export SMART_ACCOUNT_ADDRESS=0x...   # from Step 4
export INSTALL_VALIDATOR=true
npx tsx /path/to/chain_adapter/scripts/provision-kernel.ts
```

**Expect:** `install_userop_hash` + `install_tx_hash`.

**If not:** Script refuses if the smart account has no bytecode on
the target chain (Phase 1 did not land or wrong RPC).

## Step 6 — Verify `[chain]`, then receipt check

Runbook: `provisioning-kernel-v3.md` Step 6.

```sh
export VENDOR_SOURCE="<URL to vendor artifact>"
npx tsx /path/to/chain_adapter/scripts/verify-installed-validator.ts \
  > kernel-receipt.json
mix bank.kernel.receipt.check ./kernel-receipt.json
```

**Expect:** JSON receipt with
`permission_validator_bytecode_keccak256`, `chain_id: 84532`, both
addresses, Basescan URL. Receipt check confirms shape + "No RPC
calls were made and no secret values were read."

**If not:** Any refusal is a hard stop. Do NOT bind addresses to the
runtime env if verification failed; re-run Steps 4–5.

## Step 7 — Bind addresses + restart adapter

Runbook: `provisioning-kernel-v3.md` Step 7.

**Do:** Set `SMART_ACCOUNT_ADDRESS`, `PERMISSION_VALIDATOR_ADDRESS`,
`KERNEL_FACTORY_ADDRESS`, `DELEGATION_SIGNER_KEY` on the adapter
host. Restart the container. Re-run `sh scripts/check-env.sh`.

**Expect:** `PASS`. Mode is `straddle` until #83 ships; once #83's
pin ships in the running release, the same command reports
`kernel-provisioned`.

**If not:** No-network check, so any `FAIL` is an env problem on the
host.

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

**If not:** See the FAIL tables in `smoke-tests.md`. Note that
`state: revoked` in `sentinel-era` or `straddle` mode means
**on-chain anchored, trust downgraded** — NOT cryptographically
impossible. Expected pre-#58.

## After the day

- Commit the deployment journal (chain, addresses, hashes, receipt
  JSON) to the team's internal records — this is the chain-side
  handoff #84 → #83.
- Leave the adapter in `straddle` until #83 ships; the warn-level
  revoke log is expected, not a regression.
- Do NOT promote to Base mainnet until Sepolia is green end-to-end,
  #58 has shipped against Sepolia, AND #83 has populated the pin.
  Mainnet re-rolls burn real ETH.

## Out of scope

- Vendor-SDK call bodies inside `provision-kernel.ts` — documented
  inline in the template.
- Incident response for failed revokes once #58 ships (issue #38).
- Anything requiring chain access to validate — every step not
  marked `[chain]` is local or read-only RPC.
