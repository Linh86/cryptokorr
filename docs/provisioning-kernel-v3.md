# Provisioning a Kernel v3 smart account + Permission Validator on Base

Operator runbook for the one-time setup that gets the runtime out of
the sentinel-era and into a Kernel-provisioned state. Pairs with:

- [docs/smart-account-and-revoke-design.md](smart-account-and-revoke-design.md) — the architectural decision and the runtime contract this provisioning satisfies (#56).
- [docs/deploy.md](deploy.md) — generic Phoenix deploy procedure; this runbook is the chain-side prereq.
- [docs/staging.md](staging.md) — staging topology; the "Kernel-provisioning" subsection there points back here.
- [docs/incident-runbook.md](incident-runbook.md) — what to do when revoke does not land (still useful in both modes).
- [`cryptobank-ts-adapter/README.md`](../../cryptobank-ts-adapter/README.md) — adapter env table; this runbook fills in the values it asks for.
- [`cryptobank-ts-adapter/scripts/`](../../cryptobank-ts-adapter/scripts/) — provisioning + verification template scripts referenced inline below.

Tracks: GitHub #84. Completion of this runbook is the prerequisite
for #83 (verifying the validator interface) and #58 (wiring the
cryptographic revoke).

## Status

This runbook records the **provisioning path**. Actual on-chain
execution of the steps below is **operator-side work** and has not
been performed in this repo: the `SMART_ACCOUNT_ADDRESS` shipped in
the adapter's `.env.example` is still a placeholder, and
`PERMISSION_VALIDATOR_ADDRESS` is unset. The adapter's strict
`requirePermissionValidatorAddress` accessor enforces that the live
revoke cannot silently degrade to a sentinel once #58 ships.

Until an operator has executed this runbook against a real Base
deployment and recorded the resulting addresses in the runtime
config, the project remains in **sentinel-era** mode (see
"Sentinel-era vs Kernel-provisioned mode" below).

## End-state target

When this runbook completes successfully, the runtime has a real
on-chain target for cryptographic delegation revoke. Concretely:

| Env var (adapter side)         | Bound to                                                                           |
| ------------------------------ | ---------------------------------------------------------------------------------- |
| `SMART_ACCOUNT_ADDRESS`        | The deployed Kernel v3 / ERC-7579 modular account address.                         |
| `PERMISSION_VALIDATOR_ADDRESS` | The Permission Validator module installed against that smart account.              |
| `KERNEL_FACTORY_ADDRESS`       | The Kernel v3 factory used to deploy the account (recorded for redeploys / audit). |
| `DELEGATION_SIGNER_KEY`        | The session-key style EOA that the Permission Validator will authorise.            |

Phoenix-side, no env or schema change is needed. `delegations.delegation_id`
is already a string column and will start receiving the lowercase hex
form of `bytes32 permissionId` once #58 wires the grant flow.

## Vendor + chain choice

- **Account implementation: Kernel v3 (ZeroDev).** Decided in
  [#56](smart-account-and-revoke-design.md#a-kernel-v3-zerodev--chosen).
  Documented fallback if Kernel is blocked at any step below: Biconomy
  Nexus (same ERC-7579 surface; re-pin the factory + validator
  addresses, otherwise the runbook is identical).
- **Network: Base.** Provision against **Base Sepolia first**
  (chain id `84532`) for the staging adapter; promote to **Base
  mainnet** (chain id `8453`) only after the Sepolia smoke is green
  end-to-end and #58 has landed against Sepolia.
- **Bundler / paymaster: operator's existing provider.** ZeroDev,
  Pimlico, Alchemy AA, and Stackup all run ERC-4337 v0.7 bundlers on
  Base. The adapter is bundler-agnostic at the runtime level — the
  choice only affects `BUNDLER_RPC_URL` and (optionally) a paymaster
  API key.

## Prerequisites the operator must have

Hard requirements before starting the checklist:

1. **A funded operator EOA on the target Base network.** Used to pay
   gas for the smart-account deployment + validator install. Sepolia
   needs Base-Sepolia ETH from a faucet; mainnet needs real ETH. Keep
   this key separate from `DELEGATION_SIGNER_KEY` — they have
   different lifetimes and different blast radii.
2. **A Base RPC endpoint.** Either a public RPC (`https://sepolia.base.org`,
   `https://mainnet.base.org`) for low-volume work, or a paid RPC
   (Alchemy, Infura, QuickNode) for higher throughput.
3. **A bundler endpoint that supports ERC-4337 v0.7 on the target
   chain.** Required for the validator install user-op. Same provider
   that the runtime adapter will use is preferred.
4. **Node.js 22+ and a workspace separate from the production
   adapter container** for running the provisioning scripts. The
   adapter's runtime image deliberately does NOT ship with the
   ZeroDev SDK installed (provisioning is a one-shot operator
   procedure, not part of the request-handling code path).
5. **Access to set environment variables on the adapter host.**
   Whichever secret store the deployment uses (Fly secrets, AWS
   Secrets Manager, etc.).

## No-secret preflight from Phoenix

Before touching the adapter scripts or any funded key, run the
Phoenix-side preflight. It validates only presence and shape of the
operator inputs, prints redacted values, and makes **no RPC calls**:

```sh
mix bank.kernel.preflight --phase deploy
mix bank.kernel.preflight --phase install
mix bank.kernel.preflight --phase verify
```

Phases mean:

| Phase | Checks | Chain side effects |
| ----- | ------ | ------------------ |
| `deploy` | operator key, delegation signer pubkey, Base RPC, bundler RPC, Kernel factory, Permission Validator address | none |
| `install` | all deploy inputs plus `SMART_ACCOUNT_ADDRESS` from phase 1 | none |
| `verify` | all install inputs before running the read-only adapter verifier | none |
| `runtime` | runtime binding has `SMART_ACCOUNT_ADDRESS` + `PERMISSION_VALIDATOR_ADDRESS` | none |

The preflight is intentionally conservative: placeholder values,
non-Base chain ids, malformed EVM addresses, and malformed RPC URLs
block the run before a provisioning script can be started. A green
preflight means "safe to run the adapter script", not "provisioning
has succeeded".

## Step-by-step checklist

> Each step is reversible-ish: you can throw away the deployment and
> redo it on Sepolia for free until you get a clean run. On mainnet,
> redoing means a fresh smart-account address and a re-grant flow,
> so do mainnet exactly once, after Sepolia is proven.

### Step 1 — Pick the target chain and record it

Decide whether this run targets Sepolia or mainnet. Record the choice
in the operator's deployment journal (the addresses below will be
chain-specific). The rest of this runbook assumes the choice is
fixed for the duration of one provisioning run.

### Step 2 — Provision the operator EOA and fund it

```sh
# Generate a fresh operator EOA (DO THIS IN AN AIR-GAPPED OR LOCAL
# WORKSPACE, NOT ON THE ADAPTER HOST):
openssl rand -hex 32   # paste into your wallet of choice; record the
                       # corresponding 0x-prefixed address.
```

Fund the resulting address with enough native ETH on the target
network to cover the deployment + install user-op (rule of thumb:
0.01 ETH on Sepolia, 0.005 ETH on mainnet).

> **Do NOT** reuse the runtime `DELEGATION_SIGNER_KEY` here. The
> operator EOA pays gas for provisioning; the delegation signer is
> what the Permission Validator authorises for runtime user-ops. They
> have different lifetimes and different rotation policies.

### Step 3 — Identify the Kernel v3 factory + Permission Validator deployments

This is the step that #83 will pin into a tripwire test. For #84 the
operator records the addresses they intend to use:

- **Kernel v3 factory address** on the target chain. Source: the
  vendor's official deployment manifest (ZeroDev publishes these in
  their docs). Record alongside the published version number.
- **Permission Validator address** on the target chain. Same source.

Record both in the operator's deployment journal with the source URL
and the date checked. Hand them to #83 for bytecode verification +
ABI pinning.

> Until #83 lands a verified ABI tripwire, the runtime will still
> refuse to wire a cryptographic revoke even if the addresses are
> set — `requirePermissionValidatorAddress` succeeds, but the
> `executeRevoke` swap in #58 will be gated on #83's verified ABI
> fragment. This is intentional: provisioning the account is not the
> same as proving the validator's interface.

### Step 4 — Deploy the Kernel v3 smart account

In a workspace separate from the production adapter:

```sh
# In a fresh workspace:
mkdir kernel-provisioning && cd kernel-provisioning
npm init -y
npm install viem @zerodev/sdk
# (or the equivalent Biconomy Nexus packages if pivoting to fallback)

# Copy the template script and edit:
cp /path/to/cryptobank-ts-adapter/scripts/provision-kernel.ts .
$EDITOR provision-kernel.ts

# Set runtime env for the script:
export OPERATOR_PRIVATE_KEY=0x...        # Step 2
export DELEGATION_SIGNER_PUBKEY=0x...    # the EOA the validator will authorise
export BASE_RPC_URL=...                  # Step 1 + Prereq 2
export BUNDLER_RPC_URL=...               # Prereq 3
export KERNEL_FACTORY_ADDRESS=0x...      # Step 3
export PERMISSION_VALIDATOR_ADDRESS=0x... # Step 3

npx tsx provision-kernel.ts
```

The template prints the deployed smart account address to stdout. It
does not write any state into either repo — record the address in the
operator's deployment journal and proceed to Step 5.

If the template is missing a vendor SDK call shape, that is on
purpose: it is a starting template, not a black-box installer.

### Step 5 — Install the Permission Validator against the new smart account

Same template script handles the install in its second phase, gated
by an `INSTALL_VALIDATOR=true` env var. Re-run with that flag set
once Step 4 has produced a deployed address:

```sh
export SMART_ACCOUNT_ADDRESS=0x...   # output of Step 4
export INSTALL_VALIDATOR=true

npx tsx provision-kernel.ts
```

The user-op submitted here installs the Permission Validator against
the smart account using ERC-7579's standard `installModule` entry.
On confirmation, the smart account exposes the Permission Validator's
authority in addition to the Kernel default validator (the operator
EOA from Step 2 retains its admin authority — do NOT uninstall the
default validator until #58 has shipped end-to-end and a real
delegation has been granted, otherwise the account is unrecoverable).

### Step 6 — Verify the install on chain

Run the verification template against the freshly provisioned account:

```sh
export SMART_ACCOUNT_ADDRESS=0x...        # Step 4
export PERMISSION_VALIDATOR_ADDRESS=0x... # Step 3

npx tsx /path/to/cryptobank-ts-adapter/scripts/verify-installed-validator.ts
```

The template asserts:

1. `eth_getCode(SMART_ACCOUNT_ADDRESS)` returns non-empty bytecode
   (the account is actually deployed).
2. The smart account reports the Permission Validator as an installed
   module (per ERC-7579's `isModuleInstalled(moduleType, module, data)`).
3. `eth_getCode(PERMISSION_VALIDATOR_ADDRESS)` returns non-empty
   bytecode and its keccak hash. The hash goes into the operator's
   deployment journal alongside the addresses; #83 pins it as a
   tripwire fixture.

Once the verifier emits a receipt, validate the journal shape with
`Bank.Delegations.Provisioning.validate_receipt/1` (or an equivalent
IEx call) before handing it to #83. That validator checks the Base
chain id, all three EVM addresses, the validator bytecode hash, the
vendor source URL, and the Basescan URL. It does not verify bytecode
against chain state — the adapter verifier already did that — but it
prevents #83 from pinning an incomplete or placeholder journal entry.

If any assertion fails, **do NOT bind the addresses to the runtime
env**. Fix the failure, redo Steps 4–5, and re-verify. A failing
verification on mainnet is a freshly burned smart-account address —
acceptable for Sepolia, expensive for mainnet, which is why mainnet
provisioning happens once after Sepolia is proven.

### Step 7 — Bind the addresses to the runtime

Set the following on the adapter host (using whichever secret store
the deployment uses):

```sh
SMART_ACCOUNT_ADDRESS=0x...           # Step 4
PERMISSION_VALIDATOR_ADDRESS=0x...    # Step 3 (same address bound in Step 5)
KERNEL_FACTORY_ADDRESS=0x...          # Step 3 (recorded for audit / redeploy)
DELEGATION_SIGNER_KEY=0x...           # the private key matching the pubkey from Step 4
```

Restart the adapter container. Verify with:

```sh
sh /path/to/cryptobank-ts-adapter/scripts/check-env.sh
```

The check-env script prints PASS/FAIL per required var and indicates
whether the adapter is in **sentinel-era** mode (no validator
address) or **Kernel-provisioned** mode (validator address present
and well-formed).

### Step 8 — Smoke

Re-run the existing transfer + revoke smoke checks from the Phoenix
operator host:

```sh
ADAPTER_BASE_URL=... ADAPTER_DISPATCH_SECRET=... ADAPTER_CALLBACK_SECRET=... \
SMART_ACCOUNT_ID=... DELEGATION_ID=... TARGET_ADDRESS=... \
mix bank.smoke.transfer

ADAPTER_BASE_URL=... ADAPTER_DISPATCH_SECRET=... ADAPTER_CALLBACK_SECRET=... \
SMART_ACCOUNT_ID=... \
mix bank.smoke.revoke
```

Expected outcomes against a Kernel-provisioned account, **before** #58
ships:

- `mix bank.smoke.transfer` — PASS (transfer path is unchanged by
  Kernel provisioning; ERC-4337 v0.7 still delivers the user-op
  through whichever validator is currently default).
- `mix bank.smoke.revoke` — PASS, but reaches `:revoked` via the
  **sentinel** path (the sentinel UserOp still wraps a no-op
  self-call). The on-chain delegation authority is NOT yet disabled
  cryptographically; the sentinel just anchors the intent. This is
  correct pre-#58 behaviour.

After #58 ships against the same provisioned account:

- `mix bank.smoke.revoke` — PASS via the cryptographic revoke. The
  `:revoked` state then means the Permission Validator has actually
  disabled the delegation's `permissionId`.

## Verification steps post-provision

Beyond the immediate smoke checks, confirm:

1. The smart-account address appears as deployed on Basescan
   (or Sepolia Basescan) with non-empty bytecode.
2. The validator install user-op shows in the bundler explorer with
   `success: true`.
3. The deployment journal entry has all of: chain, smart-account
   address, validator address, factory address, validator bytecode
   hash, deployment date, operator EOA used, link to the install
   user-op receipt. Hand this journal entry to #83.

## Sentinel-era vs Kernel-provisioned mode

The adapter has exactly two operational modes for revoke. The check
is a single env-var presence test, enforced by
`requirePermissionValidatorAddress(config)` in
`cryptobank-ts-adapter/src/config/index.ts`:

| Mode                  | `PERMISSION_VALIDATOR_ADDRESS` | What `executeRevoke` does                                                         |
| --------------------- | ------------------------------ | --------------------------------------------------------------------------------- |
| Sentinel-era (today)  | unset                          | Sentinel UserOp `execute(self, 0, 0x)`. Anchor only — no cryptographic disable.   |
| Kernel-provisioned (target post-#84) | set                  | Still sentinel until #58 ships. After #58: real ERC-7579 disable wrapped via `buildErc7579ExecuteCallData`. |

Note that **provisioning alone does not make the revoke
cryptographic** — that is #58's wiring. Provisioning establishes the
on-chain target so #58 has something real to call. Before #58, the
operator may set `PERMISSION_VALIDATOR_ADDRESS` to a valid
provisioned address and the live revoke will still be sentinel; the
strict accessor only triggers when #58's encoder reads it.

## What this runbook does NOT do

Out of scope for #84 (each is its own issue):

- **Verify the Permission Validator's disable ABI fragment.** Tracked
  in #83. Without #83, even with #84 complete, #58 cannot wire the
  cryptographic revoke — the inner body would be speculative.
- **Wire the cryptographic revoke into `executeRevoke`.** Tracked in
  #58. This runbook only establishes the on-chain target.
- **Migrate existing pre-Kernel grants to Kernel-shaped delegation
  ids.** Pre-#58 grants emit `del_*` placeholder ids that the
  `permissionIdFromDelegationId` mapping deliberately rejects. The
  migration plan lives with #58 (likely: drain the legacy delegation
  via the existing sentinel path, then re-grant on Kernel).
- **Switch the runtime away from the SimpleAccount-shaped
  `execute(address,uint256,bytes)` envelope used by transfer.** A
  Kernel v3 account exposes the ERC-7579 `execute(bytes32,bytes)`
  entry as well; whether transfer dispatch swaps to that envelope is a
  follow-up scoped under #58, not #84.
- **Configure paymaster / sponsored flows.** Out of scope; the
  contract already reserves a `paymaster_denied` abort reason but the
  runtime adapter does not emit it.

## Re-roll procedure

If the deployed account is misconfigured (wrong validator, validator
install user-op silently no-op'd, recovery key missing) and the
operator decides to scrap the deployment:

1. Generate a fresh operator EOA (Step 2) — never reuse a partially
   provisioned EOA across runs.
2. Re-run Steps 4–6.
3. Update the deployment journal with the new addresses; mark the
   prior entry **superseded** with a one-line reason.
4. **Sepolia**: this is free; just run it.
5. **Mainnet**: requires re-granting any active delegations against
   the new smart-account address, plus updating
   `SMART_ACCOUNT_ADDRESS` everywhere it is referenced. Coordinate
   with whoever owns delegation grant flow before re-rolling
   mainnet.

## Templates referenced

- [`scripts/provision-kernel.ts`](../../cryptobank-ts-adapter/scripts/provision-kernel.ts) — viem + ZeroDev SDK provisioning template (Steps 4 + 5).
- [`scripts/verify-installed-validator.ts`](../../cryptobank-ts-adapter/scripts/verify-installed-validator.ts) — on-chain install verification (Step 6).
- [`scripts/check-env.sh`](../../cryptobank-ts-adapter/scripts/check-env.sh) — runtime env hygiene check (Step 7).
- [`scripts/README.md`](../../cryptobank-ts-adapter/scripts/README.md) — overview of what the templates do and what they deliberately leave to the operator.

## What #83 and #58 still need next, after this runbook lands

- **#83** needs the deployment journal entry from Step 6: validator
  address, validator bytecode hash, vendor source URL. Without that,
  #83 cannot bind a verified ABI fragment to a real artifact.
- **#58** needs both #84 (this runbook executed end-to-end against
  Sepolia) AND #83 (verified ABI fragment) before the
  `executeRevoke` swap is safe. Wiring #58 against an unprovisioned
  account or an unverified validator interface is exactly the failure
  mode #58's prior blocker comment isolated.
