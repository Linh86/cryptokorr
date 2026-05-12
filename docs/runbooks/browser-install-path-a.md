# Browser-Signed Install — Path A Runbook

**Status: working end-to-end as of `0x3a5ca77c…` (block 41415216, Base Sepolia)**

Path A = browser drives the install, **but** the session signer's
private key (`DELEGATION_SIGNER_KEY`) stays on `chain_adapter` and
never enters the browser. Phoenix proxies the UserOp-hash signing
request between the two.

This is the canonical recipe for the browser-driven install flow.
If it breaks, run the simulator first
(`mix bank.browser_install.e2e` or the raw `npx tsx` command
below) — it reproduces the entire chain without MetaMask popups
and prints the precise SDK step that broke.

---

## The 4-Layer Pipeline

```text
  Browser (assets/js/hooks/*)
   │
   ├─ phx-hook="WalletConnect"  ──┐  EIP-1193 provider, EIP-6963 picker,
   │                              │  binding via personal_sign over
   │                              │  Phoenix-issued challenge
   │
   └─ phx-hook="SessionPermissionInstall"
        │
        │  1. Preflight: eth_accounts, eth_chainId, data-bound-address,
        │     bundler URL, balance.
        │
        │  2. GET  /wallet_bindings/:id/install_envelope
        │  3. ZeroDev SDK: signerToEcdsaValidator(walletClient)
        │                  toPermissionValidator(sessionAccount-proxy)
        │                  createKernelAccount({index: BigInt(envelope.kernel_account_index)})
        │                  createKernelAccountClient({paymaster: true, ...})
        │
        │  4. SDK builds UserOp, asks sessionAccount.signMessage({raw: userOpHash})
        │       │
        │       └────────►  Phoenix
        │                    │
        │                    │  POST /wallet_bindings/:id/sign_install_userop_hash
        │                    │   { user_op_hash, session_signer_address }
        │                    │  (CSRF + session-cookie + operator-role gated)
        │                    │
        │                    └────────►  chain_adapter
        │                                 │
        │                                 │  POST /install/sign_session_portion
        │                                 │  Authorization: Bearer ADAPTER_DISPATCH_SECRET
        │                                 │  { user_op_hash, session_signer_address? }
        │                                 │
        │                                 │  privateKeyToAccount(DELEGATION_SIGNER_KEY)
        │                                 │  .signMessage({raw: userOpHash})
        │                                 │  → EIP-191 signature
        │                                 │
        │                                 └────────►  Phoenix  ─────►  Browser
        │
        │  5. SDK now also asks walletClient.signTypedData(...) for the
        │     sudo enable signature → MetaMask popup → user signs
        │
        │  6. SDK submits the doubly-signed UserOp:
        │       │
        │       └────────►  Pimlico bundler (api.pimlico.io/v2/84532/rpc?apikey=…)
        │                     │  paymaster: true → pm_getPaymasterStubData +
        │                     │  pm_getPaymasterData (Pimlico sponsors gas)
        │                     │  eth_sendUserOperation
        │                     │
        │                     └────────►  Base Sepolia (sepolia.base.org)
        │                                  │  EntryPoint v0.7 validates both sigs,
        │                                  │  factory deploys the kernel,
        │                                  │  permission plugin installed.
        │
        │  7. POST /wallet_bindings/:id/install_attestation {status: submitted}
        │  8. SDK waits for receipt → POST install_attestation {status: confirmed,
        │       tx_hash, block_number}
        │
   Phoenix worker: Bank.Runtime.Workers.VerifyInstallOnchain
        │  reads SA bytecode (eth_getCode); confirms deployed.
        │  (validation_config selector check is gated by
        │   :validation_id_check — :skip until kernel selector lands;
        │   bundler-accepted UserOp is the actual install proof.)
        │
        └─ flips delegation :pending → :active.
```

The session-signer key never crosses the Phoenix↔browser boundary.
The MetaMask popup only signs the sudo enable typed-data; nothing
else.

---

## Canonical env + config

### `chain_adapter/.env` (sourced into the Phoenix shell at boot)

| Var | Value (dev) | Used by |
|---|---|---|
| `BUNDLER_RPC_URL` | `https://api.pimlico.io/v2/84532/rpc?apikey=<KEY>` | Browser bundler transport (sponsored). Pimlico key needs `Bundler methods` + `Verifying paymaster` enabled. |
| `BASE_RPC_URL` | `https://sepolia.base.org` | publicClient transport for `getSenderAddress`-style `eth_call`s. **Must** be a generic chain RPC, not a bundler-only endpoint. |
| `DELEGATION_SIGNER_KEY` | `0x<priv-key>` | Operator session signer. **Never leaves the adapter process.** Signs the permission-validator portion of install UserOps via `POST /install/sign_session_portion`. |
| `OPERATOR_ADDRESS` | `0x19AB05bb…` | Used by Phoenix kernel-account-collision preflight only. |
| `SESSION_SIGNER_ADDRESS` | `0x0C9C012E…` (derived from `DELEGATION_SIGNER_KEY`) | Phoenix embeds this in the install envelope; the browser shows it in the consistency check. |
| `ADAPTER_DISPATCH_SECRET` | `dev-adapter-dispatch-secret` | Phoenix→adapter Bearer secret. Browser never sees it. |

### Phoenix runtime env

| Var | Value (dev) | Notes |
|---|---|---|
| `BROWSER_KERNEL_ACCOUNT_INDEX` | `1` | Browser kernel CREATE2 salt. **Must differ from the operator's `KERNEL_ACCOUNT_INDEX`** when the demo wallet imports `OPERATOR_PRIVATE_KEY`. Collision is blocked by `:kernel_account_collision`. |
| `KERNEL_ACCOUNT_INDEX` | `0` | Operator (chain_adapter) kernel index. |
| `BASE_SEPOLIA_RPC_URL` | (optional) | Highest-precedence alias for chain RPC; fallback chain: `BASE_SEPOLIA_RPC` → `BASE_RPC_URL` → `https://sepolia.base.org`. |
| `BASE_SEPOLIA_BUNDLER_RPC` | (optional) | Highest-precedence alias for bundler URL; fallback chain: `BUNDLER_URL` → `BUNDLER_RPC_URL`. |

### Phoenix config slots (`config/dev.exs`)

```elixir
config :bank, Bank.SessionPermissions.BrowserInstall,
  bundler_rpc_url:            "from $BASE_SEPOLIA_BUNDLER_RPC | $BUNDLER_URL | $BUNDLER_RPC_URL",
  chain_rpc_url:              "from $BASE_SEPOLIA_RPC_URL | … | https://sepolia.base.org",
  session_signer_address:     "from $SESSION_SIGNER_ADDRESS",
  operator_kernel_account_index: "from $KERNEL_ACCOUNT_INDEX (default 0)",
  kernel_account_index:          "from $BROWSER_KERNEL_ACCOUNT_INDEX (default 1)",
  operator_eoa_address:       "from $OPERATOR_ADDRESS"

config :bank, Bank.Chains.KernelVerifier,
  rpc_url:               "(same alias chain as chain_rpc_url)",
  validation_id_check:   :skip      # default in dev, see TODO below
```

### Wire-allowlisted failure categories

`Bank.SessionPermissions.BrowserInstall.failure_categories/0`:

```
user_rejected | bundler_rejected | bundler_unavailable |
bundler_not_configured | chain_id_mismatch | insufficient_funds |
userop_reverted | attestation_timeout | wallet_not_connected |
account_mismatch | kernel_account_collision |
session_signer_unavailable | session_signer_refused | unknown
```

Anything outside the allowlist collapses to `:unknown`.
Operator-facing copy lives in `permission_card.ex`'s
`failure_reason_label/1` clauses.

---

## Known-good simulator

Drives the entire pipeline **without a browser or MetaMask**. Use
this to determine whether the install path is alive before asking
a user to click anything.

```bash
# chain_adapter must already be running (npm run dev)
mix bank.browser_install.e2e
```

Or the raw Node entrypoint (same code path):

```bash
cd chain_adapter
set -a; source .env; set +a
export BASE_SEPOLIA_BUNDLER_RPC="$BUNDLER_RPC_URL"
npx tsx scripts/install-e2e-simulator.ts
```

Expected output (each step prefixed `[install-sim:<step>]`):

```
config              adapter_url, chain_rpc_host, bundler_rpc_host, …
user_eoa            0x… (fresh test EOA per run)
signerToEcdsaValidator
toECDSASigner
toPermissionValidator
createKernelAccount address: 0x…
createKernelAccountClient paymaster: enabled (Pimlico)
encodeCalls
session_sign:request   hash_prefix
session_sign:response  sig_prefix
sendUserOperation   userop_hash
waitForUserOperationReceipt tx_hash, block_number   ← ON CHAIN
done                smart_account_address
```

Exit 0 = end-to-end works. Exit 1 = printed step is the regression.

---

## Diagnostic ladder (when "install fails")

1. **Does `mix bank.browser_install.e2e` pass?**
   - If **yes**: the Phoenix↔adapter↔bundler↔chain pipeline is fine.
     The browser-only piece (preflight, MetaMask popup, envelope
     fetch) is the regression. Inspect the JS console
     `[browser-install:<step>] raw object: …` log lines.
   - If **no**: the printed step locates the layer that broke.

2. **Does `mix bank.browser_install.smoke` pass with the chain_adapter
   running on :4100?**
   - Reports per-env-var status, alias resolution, and Pimlico bundler
   reachability. Pre-flight only — no UserOp.

3. **`Application.get_env(:bank, Bank.Chains.KernelVerifier)`**
   - Must include `rpc_url: <base-sepolia URL>` AND
     `validation_id_check: :skip` (dev) or `:enforce` (prod).
   - Empty `rpc_url` → `onchain_verification_unreachable`.

4. **Phoenix logs at `[debug] HANDLE EVENT "session_permission_install:…"`**
   - `awaiting` → click reached the FE state machine.
   - `submitted` → UserOp accepted by Pimlico.
   - `confirmed` → bundler receipt arrived.
   - `failed` → reason atom in `params["reason"]` — map to operator
     copy via `permission_card.ex`'s `failure_reason_label/1`.

5. **`Bank.Runtime.Workers.VerifyInstallOnchain` outcome**
   - Looks at `delegation.last_reason` (`browser_signed_install` on
     success, `onchain_verification_unreachable` / `onchain_state_mismatch`
     / `smart_account_not_deployed` on failure).
   - `onchain_verification_unreachable` after 5 retries usually
     means the `validationConfig` `eth_call` reverts (selector
     mismatch — see open TODO).

6. **On-chain confirmation**

   ```bash
   curl -sS -X POST https://sepolia.base.org \
     -H 'content-type: application/json' \
     -d '{"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":["0x<sa>","latest"]}'
   ```

   Non-`"0x"` `result` ⇒ smart account deployed. If deployed AND the
   bundler accepted the UserOp, the install IS on chain regardless
   of what the Phoenix verifier says.

---

## Open integration TODO

### Re-enable `validation_id_check: :enforce` in production

The verifier currently calls
`validationConfig(bytes21)` with selector `0x91244e98`. The deployed
Kernel v3.1 reverts on this call (`error.data: 0x7352d91c`). The
adapter-side `verify-installed-validator.ts` script flagged this:

> *No permission install state — no per-permission `permissionConfig`
> reads. … verifying [permission install state] presence is the
> integration TODO.*

Until the correct selector is identified and pinned with a contract
test, `:validation_id_check: :skip` synthesizes a non-zero result so
`assert_validation_installed/1` passes. Deployment + bundler-
confirmed UserOp + on-chain receipt status are the operative
guarantees.

When the integration ticket lands:
- compute the right selector from the actually-deployed kernel ABI;
- update `@validation_config_selector` in
  `lib/bank/chains/kernel_verifier.ex`;
- flip `validation_id_check: :enforce` in `config/dev.exs` (and
  any prod overrides);
- add a contract test pinning the call decode shape against a
  freshly-installed account on Base Sepolia.

### Rotate `BROWSER_KERNEL_ACCOUNT_INDEX` per workspace in production

In dev, every workspace shares index `1` (vs operator's `0`). In
production with multiple operators / workspaces, bump the index
per workspace (or derive deterministically from `workspace_id`)
so each workspace owns its own smart account.

---

## Test-pinned invariants

Tests below are CI-load-bearing for this flow. If you touch any of
these files, expect to touch a test from the same row.

| File | Pin |
|---|---|
| `lib/bank/session_permissions/browser_install.ex` (`@failure_categories`) | `test/bank/session_permissions/browser_install_test.exs#failure_categories/0 contract` |
| `lib/bank/chains/kernel_verifier.ex` (`validation_id_check`) | `test/bank/chains/kernel_verifier_test.exs` |
| `lib/bank_web/plugs/put_csp.ex` (`connect-src` widening) | `test/bank_web/plugs/put_csp_test.exs` |
| `lib/bank_web/controllers/wallet_bindings_install_controller.ex` (`sign_install_userop_hash` proxy) | `test/bank_web/controllers/wallet_bindings_install_controller_test.exs` |
| `chain_adapter/src/install/session_signer.ts` + `chain_adapter/src/app.ts` (`/install/sign_session_portion`) | `chain_adapter/test/install-sign-session-portion.test.ts` |
| `assets/js/hooks/install_zerodev_client.js` (paymaster, kernel index, session-sign proxy) | `assets/js/hooks/__tests__/install_zerodev_client.test.js` |
| `config/dev.exs` (`chain_rpc_url` + kernel index alias chains) | source-level regex pins in `test/bank/session_permissions/browser_install_test.exs` |

Run `mix test` + `cd chain_adapter && npm test` + `cd assets && npx vitest run` for the full pin sweep.
