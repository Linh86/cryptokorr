# Browser-signed install smoke — Base Sepolia

Reviewer-ready smoke runbook for the browser-signed ZeroDev session
permission install on **Base Sepolia (84532) only**. Closes the epic
[#471](https://github.com/Linh86/cryptobank/issues/471) walkthrough
and references the four shipped child issues:

- [#472](https://github.com/Linh86/cryptobank/issues/472) — design note
  (`docs/design/browser-signed-install.md`)
- [#473](https://github.com/Linh86/cryptobank/issues/473) — frontend
  scaffold (LiveView + JS hook)
- [#474](https://github.com/Linh86/cryptobank/issues/474) — Phoenix
  attestation endpoints + on-chain verifier worker
- [#475](https://github.com/Linh86/cryptobank/issues/475) — revoke
  parity (sentinel for `:user`-rooted rows)

**Hard guarantees this runbook exercises:**

- The install UserOperation is signed by **the operator's connected
  browser wallet (EOA)**. `OPERATOR_PRIVATE_KEY` is NOT involved in
  the normal install path.
- Phoenix marks the delegation `:active` only after
  `Bank.Runtime.Workers.VerifyInstallOnchain` reads the kernel's
  installed validator set and confirms the permission validator is
  present.
- Base Sepolia (`chain_id = 84532`) only at every layer: envelope,
  attestation, verifier, and the JS hook's wrong-chain refusal. Base
  mainnet (8453) is out of scope and surfaces as wrong-chain.
- No server / operator private key signs the normal install. No
  secrets in audit, logs, UI, or fixtures.

> **Honest gap:** the JS hook from #473 still synthesises the
> bundler `submitted → confirmed` transition with a
> `window.setTimeout` stand-in. Real ZeroDev SDK + bundler wiring is
> tracked as a v0.2 follow-up. **Path B (real on-chain end-to-end)**
> below documents how to drive the install with a real UserOp until
> the SDK lands; **Path A** exercises the Phoenix-side state machine
> end-to-end without leaving the browser.

## API surface

The browser-signed install lifecycle uses three endpoints under
`/v1/wallet_bindings/:id/`:

| Method | Path                                                  | Auth tier        |
| ------ | ----------------------------------------------------- | ---------------- |
| GET    | `GET /v1/wallet_bindings/:id/install_envelope`        | viewer           |
| POST   | `POST /v1/wallet_bindings/:id/install_attestation`    | operator         |
| GET    | `GET /v1/wallet_bindings/:id/install_status`          | viewer           |

Cross-workspace `:id` returns `404 not_found` (no existence leak).

---

## Prereqs

- A browser with an EIP-1193 wallet (MetaMask, Rabby, Frame, …) on
  **Base Sepolia (84532)**. Mobile-only wallets are out of scope.
- A Base Sepolia EOA you control with **at least 0.005 ETH** in
  testnet ETH for the install gas. Faucets:
  - <https://www.alchemy.com/faucets/base-sepolia>
  - <https://faucet.quicknode.com/base/sepolia>
- Phoenix and the chain adapter running locally (or against a
  staging stack):
  ```sh
  mix phx.server                       # Phoenix on :4000
  cd chain_adapter && npm run dev      # Adapter on :4100
  ```
- An operator API key for the `:api_operator` tier (POST attestation
  is operator-tier; envelope + status reads are viewer-tier). See
  `docs/operator-secrets-checklist.md` for issuing one.

> **Never paste a private key into the browser, Phoenix, or any
> document.** Wallet ownership is proven through `personal_sign`
> only.

---

## Path A — Phoenix-side state machine smoke

Exercises every Phoenix endpoint and the on-chain verifier worker
**without** leaving the browser. The goal is to confirm Phoenix
correctly accepts the lifecycle attestations, enqueues the verifier,
and transitions the delegation row through every state — including
the deliberate `:install_failed` outcome when no real UserOp was
submitted to the bundler.

### A.1 Bind the wallet

1. Open `http://localhost:4000/`.
2. Click **Connect wallet** (`#wallet-connect-btn`). Approve the
   account-exposure prompt.
3. Switch to Base Sepolia in your wallet if prompted; the card
   transitions to `#wallet-status-wrong-chain` if you are on any
   other chain.
4. Sign the EIP-191 binding challenge (`personal_sign`). The card
   transitions to `#wallet-status-bound` with a `verified_at`
   timestamp.

**Audit evidence to verify** at `/audit`:
- `wallet_binding.connect_requested`
- `wallet_binding.verified` with `chain_id: 84532`

### A.2 Fetch the install envelope

```sh
curl -s \
  -H "Authorization: Bearer $OPERATOR_API_KEY" \
  http://localhost:4000/v1/wallet_bindings/<binding_id>/install_envelope \
  | jq
```

**Expected response (200):**
- `chain_id: 84532` (any other value → bug)
- `scope_hash` starts with `sha256:` and is a 64-hex-char digest
- `scope` JSON contains the canonical permissions package
- `kernel_version`, `permissions_package_version`, and
  `entry_point_address` are populated
- `bundler_rpc_url` is the browser-tier RPC URL (operator-rotated)

**Audit evidence:** `delegation.install_envelope_issued`.

### A.3 POST `submitted` attestation

Hand-craft a synthetic `submitted` with a fake userop hash to
exercise the `:pending` row creation:

```sh
curl -s -X POST \
  -H "Authorization: Bearer $OPERATOR_API_KEY" \
  -H "Content-Type: application/json" \
  http://localhost:4000/v1/wallet_bindings/<binding_id>/install_attestation \
  -d '{
    "status": "submitted",
    "install_userop_hash": "0xdeadbeef...",
    "permission_id": "0xa1b2c3d4",
    "validation_id": "0x02a1b2c3d400000000000000000000000000000000"
  }' \
  | jq
```

**Expected response (202):**
```json
{ "state": "submitted", "delegation_id": "<uuid>" }
```

**State transition:** the delegation row is created with
`state: :pending` and `root_validator_owner: "user"`.

**Audit evidence:** `delegation.install_signed_by_user`.

### A.4 POST `confirmed` attestation

```sh
curl -s -X POST \
  -H "Authorization: Bearer $OPERATOR_API_KEY" \
  -H "Content-Type: application/json" \
  http://localhost:4000/v1/wallet_bindings/<binding_id>/install_attestation \
  -d '{
    "status": "confirmed",
    "install_userop_hash": "0xdeadbeef...",
    "tx_hash": "0xabcd...",
    "block_number": 12345678
  }' \
  | jq
```

**Expected response (202):**
```json
{ "state": "verifying", "delegation_id": "<uuid>" }
```

**Critical invariant:** the row is **NOT** marked `:active` here.
Phoenix only enqueues `Bank.Runtime.Workers.VerifyInstallOnchain`.
Pinned by
`BankWeb.API.V1.WalletBindingsInstallControllerTest`'s
"confirmed enqueues VerifyInstallOnchain but does NOT mark :active".

**Audit evidence:** `delegation.install_broadcast` with `tx_hash` +
`block_number`.

### A.5 Observe the verifier worker

The worker calls `eth_call` against the kernel's
`validationConfig(bytes21)` selector to confirm the permission
validator is installed. Without a real UserOp on chain, the
validator IS NOT installed → the worker's verdict is
`:not_installed` → the row flips to `:install_failed` with
`last_reason: "install_failed:onchain_state_mismatch"`.

**Poll for the verdict:**
```sh
curl -s \
  -H "Authorization: Bearer $OPERATOR_API_KEY" \
  http://localhost:4000/v1/wallet_bindings/<binding_id>/install_status \
  | jq
```

**Expected (within ~10 s, or after a manual verifier run):**
```json
{
  "state": "failed",
  "delegation_id": "<uuid>",
  "last_reason": "install_failed:onchain_state_mismatch"
}
```

**Audit evidence:** `delegation.install_failed` with the same
sanitised reason category. **No raw RPC error string** is allowed
through — pinned by the failure-category allowlist in
`Bank.SessionPermissions.BrowserInstall.failure_categories/0`.

> **This is the correct outcome for Path A.** Phoenix refused to
> mark `:active` because no real validator is installed on chain.
> If you see `state: "active"` here without having submitted a real
> UserOp, that's a bug — Phoenix should never trust browser
> attestations alone.

### A.6 Verify revoke posture (#475)

Even though the row is in a terminal `:install_failed`, you can
verify the v0.1 revoke posture by inspecting a `:user`-rooted
delegation in `/security`:

- Each delegation row carries a `revoke: cryptographic` or
  `revoke: sentinel` badge (from `revoke_method/1`).
- Browser-signed (`root_validator_owner: "user"`) rows MUST show
  `sentinel` — operator EOA cryptographic uninstall is unavailable
  for user-rooted kernels until the v0.2 browser-signed revoke
  flow ships.

---

## Path B — Real on-chain end-to-end

Drive a real UserOperation against Base Sepolia until the JS hook's
synthetic confirmation is replaced with the ZeroDev SDK call. Two
approaches:

### B.1 Inject a real bundler call from the JS console

While the install LiveView is open and you have just signed the
scope message (state `signing` / `submitted`):

1. Open the browser dev tools console.
2. Build a real UserOperation against the kernel's
   `installValidation(...)` selector using `viem` or the ZeroDev
   SDK (whichever your operator side has bundled). Sign it with the
   same EOA the binding row is anchored to.
3. Submit to the public-tier bundler RPC URL surfaced in the
   install envelope (`bundler_rpc_url`).
4. Wait for `eth_getUserOperationReceipt` to return a non-null
   receipt.
5. POST a real `confirmed` attestation with the **real**
   `install_userop_hash`, `tx_hash`, and `block_number` (replacing
   the JS hook's synthetic ones).

**Expected outcome:** Phoenix's verifier worker reads the kernel
state, sees the validation_id installed, and flips the delegation
to `:active` with `last_reason: "browser_signed_install"` and an
emitted `delegation.install_confirmed_onchain` audit event.

### B.2 Use `cast` from foundry

A pure-CLI alternative for reviewers without the SDK assembled:

```sh
# Replace placeholders before running
cast send <kernel_address> \
  "installValidation(bytes21,address,bytes,bytes)" \
  <validation_id> <signer> <validation_data> 0x \
  --rpc-url <base_sepolia_rpc_url> \
  --private-key <user_eoa_key>
```

**Never paste this private key into Phoenix or the browser.** It is
only used by `cast` to sign a single transaction the user EOA already
controls.

After the tx confirms, POST a real `confirmed` attestation through
the API and observe the same `:active` outcome as B.1.

---

## Failure modes the smoke MUST surface

| Trigger                                  | Where it fails                                                                                 | What you'll see                                                                                                                  |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Wallet on Base mainnet (8453)            | JS hook (`SUPPORTED_CHAIN_IDS`)                                                                | LiveView pushes `session_permission_install:wrong_chain`; no envelope ever fetched.                                              |
| Wallet on any other chain                | JS hook                                                                                        | Same as above.                                                                                                                   |
| User rejects `personal_sign`             | JS hook (`classifyError`)                                                                      | POST `install_attestation status: "user_rejected"` → audit `delegation.install_failed reason: "user_rejected"`; no row created.   |
| Bundler 5xx / unreachable                | JS hook OR external                                                                            | POST `bundler_rejected` or `bundler_unavailable` → audit `delegation.install_failed`; pending row (if any) → `:install_failed`. |
| UserOp reverts on chain                  | Verifier worker (`Bank.Chains.KernelVerifier`)                                                 | Worker maps `:not_installed` → row `:install_failed`, `last_reason: "install_failed:onchain_state_mismatch"`.                    |
| Smart account never deployed             | Verifier worker                                                                                | Maps `:not_deployed` → `last_reason: "install_failed:smart_account_not_deployed"`.                                                |
| Phoenix RPC URL not configured           | Verifier worker                                                                                | Maps `:rpc_not_configured` → `last_reason: "install_failed:onchain_verification_unreachable"`.                                    |
| Cross-workspace `binding_id`             | Controller (`load_binding/2`)                                                                  | `404 not_found` (no existence leak; pinned by controller test).                                                                   |
| Free-form upstream error string          | `BrowserInstall.normalize_reason/1`                                                            | Collapses to `unknown` on the audit row; no raw string ever reaches `last_reason`.                                                |

### Pinned failure-category allowlist

`Bank.SessionPermissions.BrowserInstall.failure_categories/0`
returns the only set of values that may appear on the audit row's
`reason` field or on the delegation row's `last_reason` column for
the install path:

```
user_rejected | bundler_rejected | bundler_unavailable
| chain_id_mismatch | insufficient_funds | userop_reverted
| attestation_timeout | unknown
```

Any string outside this set MUST collapse to `unknown` — pinned
by the controller test suite and the
`Docs.BrowserSignedInstallDocsHygieneTest` doc-hygiene guard.

If a failure mode does NOT surface as documented above, flag it as
a regression — **the smoke is the contract**.

---

## Audit / replay evidence checklist

A reviewer can prove every step by inspecting `/audit` or the
`audit_events` table:

| Step                              | Event type                              | Required `after_ref` keys                              |
| --------------------------------- | --------------------------------------- | ------------------------------------------------------ |
| Envelope returned                 | `delegation.install_envelope_issued`    | `binding_id`, `chain_id`, `scope_hash`                |
| Browser reported `submitted`      | `delegation.install_signed_by_user`     | `binding_id`, `install_userop_hash`, `permission_id`  |
| Browser reported `confirmed`      | `delegation.install_broadcast`          | `binding_id`, `install_userop_hash`, `tx_hash`, `block_number` |
| On-chain verifier flipped active  | `delegation.install_confirmed_onchain`  | `binding_id`, `delegation_id`                          |
| Terminal failure                  | `delegation.install_failed`             | `binding_id`, `reason` (from the pinned allowlist)     |

`correlation_id` on every event equals the `binding_id`.

---

## Out of scope

- **v0.2 browser-signed cryptographic revoke.** v0.1 ships the
  sentinel audit anchor for `:user`-rooted rows; the user-signed
  uninstall flow is a follow-up.
- **Base mainnet.** No mainnet enablement is in this runbook; the
  install path refuses any `chain_id != 84532`.
- **Paymaster / sponsored gas.** The user EOA pays gas in Base
  Sepolia testnet ETH.
- **Real ZeroDev SDK wiring inside the browser hook.** Until that
  ships, Path B is the manual reviewer route to a real `:active`
  outcome.
