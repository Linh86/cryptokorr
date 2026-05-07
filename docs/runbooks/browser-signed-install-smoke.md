# Browser-signed install smoke — Base Sepolia

Reviewer-ready smoke runbook for the browser-signed ZeroDev session
permission install on **Base Sepolia (84532) only**. Closes the epic
[#471](https://github.com/Linh86/cryptobank/issues/471) walkthrough
and references the launch-track child issues:

- [#472](https://github.com/Linh86/cryptobank/issues/472) — design note
  (`docs/design/browser-signed-install.md`)
- [#473](https://github.com/Linh86/cryptobank/issues/473) — frontend
  scaffold (LiveView + JS hook)
- [#474](https://github.com/Linh86/cryptobank/issues/474) — Phoenix
  attestation endpoints + on-chain verifier worker
- [#475](https://github.com/Linh86/cryptobank/issues/475) — revoke
  parity (sentinel for `:user`-rooted rows)
- [#476](https://github.com/Linh86/cryptobank/issues/476) — initial
  reviewer-ready smoke runbook
- [#500](https://github.com/Linh86/cryptobank/issues/500) — browser
  session-authenticated install routes + server-side receipt
  recovery (backend launch lane)
- [#501](https://github.com/Linh86/cryptobank/issues/501) — frontend
  ZeroDev SDK + bundler submission (frontend launch lane)
- [#502](https://github.com/Linh86/cryptobank/issues/502) — this
  runbook + docs hygiene + preflight Mix task

**Hard guarantees this runbook exercises:**

- The install UserOperation is signed by **the operator's connected
  browser wallet (EOA)**. `OPERATOR_PRIVATE_KEY` is NOT involved in
  the normal install path. No server-side signing fallback exists.
- Phoenix marks the delegation `:active` only after
  `Bank.Runtime.Workers.VerifyInstallOnchain` reads the kernel's
  installed validator set and confirms the permission validator is
  present.
- Base Sepolia (`chain_id = 84532`) only at every layer: envelope,
  attestation, verifier, and the JS hook's wrong-chain refusal. Base
  mainnet (8453) is out of scope and surfaces as wrong-chain.
- No server / operator private key signs the normal install. No
  secrets in audit, logs, UI, or fixtures.

> **Implementation status (read this first).** Path A below assumes
> the launch-lane PRs from [#500](https://github.com/Linh86/cryptobank/issues/500)
> (backend browser-session install routes + server-side receipt
> recovery) and [#501](https://github.com/Linh86/cryptobank/issues/501)
> (frontend ZeroDev SDK + bundler submission) are merged on `main`.
> If either is still open, the JS hook ships the #473 scaffold and
> the only path to a real `:active` row is **Path B** (manual
> reviewer escape hatch). The shipped Phoenix-side state machine
> (#474) is the same regardless of which path drives the
> attestations — that is by design: the runbook's audit / recovery /
> failure-mode contract holds end-to-end.

---

## Quick preflight

Before starting any path, run the preflight Mix task. It does **not**
sign or broadcast anything; it only verifies env, config, and the
reviewer checklist:

```sh
mix bank.browser_install.smoke
```

The task fails loudly if any required env var is missing or
malformed (`BASE_RPC_URL`, `BUNDLER_RPC_URL`, `BANK_ENDPOINT`,
`OPERATOR_API_KEY`, etc.) and prints a redacted summary plus the
reviewer step list. It refuses to do anything chain-affecting; if
you ask it to broadcast it will exit with a clear refusal. See §
"Preflight task" at the bottom of this runbook for the full
contract.

---

## API surface

The browser-signed install lifecycle uses three endpoints under
`/v1/wallet_bindings/:id/`. After [#500](https://github.com/Linh86/cryptobank/issues/500)
lands, the same three paths are also reachable on the
browser-session pipeline (`/wallet_bindings/:id/install_*`) so the
in-LiveView hook can hit them with the operator's session cookie
+ CSRF token instead of an API key:

| Method | Path                                                  | Auth tier       | Notes                                                                 |
| ------ | ----------------------------------------------------- | --------------- | --------------------------------------------------------------------- |
| GET    | `GET /v1/wallet_bindings/:id/install_envelope`        | viewer (API)    | The canonical scope source-of-truth; always available.                |
| POST   | `POST /v1/wallet_bindings/:id/install_attestation`    | operator (API)  | API-key route used by Path B (`curl`) and any external automation.    |
| GET    | `GET /v1/wallet_bindings/:id/install_status`          | viewer (API)    | Polled by Path B and reviewer scripts.                                |
| GET    | `GET /wallet_bindings/:id/install_envelope`           | session viewer  | Browser-session route Path A uses (#500). Same payload as the API.    |
| POST   | `POST /wallet_bindings/:id/install_attestation`       | session operator + CSRF | Browser-session route Path A uses (#500).                     |
| GET    | `GET /wallet_bindings/:id/install_status`             | session viewer  | Browser-session polling path Path A uses (#500).                      |

Cross-workspace `:id` returns `404 not_found` on every variant (no
existence leak; pinned by controller tests).

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
- A reachable Base Sepolia RPC (`BASE_RPC_URL`) — the verifier
  worker uses it for `eth_call` only, never for writes.
- A reachable Base Sepolia ERC-4337 v0.7 bundler endpoint
  (`BUNDLER_RPC_URL`). Path A needs the same URL surfaced on the
  install envelope (`bundler_rpc_url`); Path B uses it directly.
- An operator API key for the `:api_operator` tier — required for
  Path B's `POST install_attestation` and useful for inspecting
  audit / status from `curl`. Path A uses your logged-in operator
  session cookie + the `<meta name="csrf-token">` value Phoenix
  embeds in the layout.

> **Never paste a private key into the browser, Phoenix, or any
> document.** Wallet ownership is proven through `personal_sign`
> for the binding challenge and through ZeroDev SDK's wallet
> integration for the install UserOperation. Phoenix never
> receives or stores key material.

---

## Path A — Real automated browser install

This is the launch path. Requires the merged PRs for
[#500](https://github.com/Linh86/cryptobank/issues/500) and
[#501](https://github.com/Linh86/cryptobank/issues/501).
End-to-end the reviewer never leaves the browser; the wallet pop-up
for the EIP-712 install signature is the only manual moment.

### A.1 Bind the wallet

1. Open `http://localhost:4000/`.
2. Click **Connect wallet** (`#wallet-connect-btn`). Approve the
   account-exposure prompt.
3. Switch to Base Sepolia in your wallet if prompted; the card
   transitions to `#wallet-status-wrong-chain` if you are on any
   other chain (mainnet `8453` included).
4. Sign the EIP-191 binding challenge (`personal_sign`). The card
   transitions to `#wallet-status-bound` with a `verified_at`
   timestamp.

**Audit evidence to verify** at `/audit`:
- `wallet_binding.connect_requested`
- `wallet_binding.verified` with `chain_id: 84532`

**Visible-fail checks**:
- Stay on Base mainnet → card surfaces `#wallet-status-wrong-chain`
  with copy "Switch to Base Sepolia (84532) to continue". No
  envelope is fetched, no audit row is created. The smoke fails
  this step — do **not** proceed on mainnet.
- Reject the `personal_sign` prompt → card surfaces
  `#wallet-status-bind-failed`. Click **Try again** to re-issue.

### A.2 Click "Install session permission"

The session-permission card (`#session-permission-card`) appears
after binding. The plain-language scope summary is sourced from
`Bank.SessionPermissions.Scope.default/0` and rendered before the
install button — read it.

Click **Install session permission**
(`#install-session-permission-btn`). The hook does the following
without operator intervention:

1. Pre-flight check: `eth_chainId` MUST return `84532`.
2. Pre-flight check: `eth_getBalance` MUST be ≥ 0.005 ETH on the
   bound EOA. If either pre-flight fails the wallet popup never
   fires; the card surfaces `#session-permission-failed` with a
   copy block matching the failure category.
3. The hook fetches the canonical install envelope from Phoenix
   via `GET /wallet_bindings/:id/install_envelope` (the
   browser-session route — operator session cookie, no API key in
   the browser bundle).

**Expected envelope fields:**
- `chain_id: 84532` (any other value → bug)
- `scope_hash` is `sha256:<64-hex-char-digest>` over the canonical
  scope JSON — the audit anchor for the operator-consented scope
- `scope` JSON contains the canonical permissions package
- `kernel_version`, `permissions_package_version`, and
  `entry_point_address` are populated
- `bundler_rpc_url` is the browser-tier Base Sepolia bundler URL
  (operator-rotated, distinct from the adapter's bundler key)

**Audit evidence:** `delegation.install_envelope_issued` with
`correlation_id == binding_id`.

### A.3 Sign the install UserOperation in the wallet

The hook builds the install UserOperation locally with the ZeroDev
SDK (mirroring `chain_adapter/src/chains/base/grant.ts` byte-for-byte
with the user EOA replacing the operator EOA) and asks the wallet
to sign the EIP-712 enable signature. The wallet popup shows the
kernel address, the enable selector, and the permission id — verify
these match the operator-consent UI string before approving.

**Visible-fail checks:**
- Reject the wallet popup → POST
  `install_attestation { status: "user_rejected" }` →
  `delegation.install_failed { reason: "user_rejected" }` audit;
  no `:pending` row is created.
- Wallet on the wrong chain at signature time (rare; usually caught
  earlier) → POST
  `install_attestation { status: "bundler_rejected", reason: "chain_id_mismatch" }`.

### A.4 Bundler submission + Phoenix attestation

1. The hook submits the signed UserOp to the Base Sepolia bundler
   at `envelope.bundler_rpc_url` directly.
2. As soon as `eth_sendUserOperation` returns a hash, the hook POSTs
   `install_attestation { status: "submitted", install_userop_hash,
   permission_id, validation_id }` to the browser-session route.
   Phoenix persists a `:pending` `Delegation` row with
   `root_validator_owner: "user"`, idempotent on
   `(binding_id, install_userop_hash)`. **Audit evidence**:
   `delegation.install_signed_by_user`.
3. Phoenix simultaneously enqueues the receipt poller from
   [#500](https://github.com/Linh86/cryptobank/issues/500)
   (`Bank.Runtime.Workers.PollInstallUserOpReceipt`). The poller
   carries the row to a verdict regardless of browser tab state —
   if the operator closes the tab here, the install still
   completes (or terminates with an honest reason) on its own.
4. The hook calls `waitForUserOperationReceipt` (45 s wall-clock
   cap). On a non-null receipt with `success: true`, it POSTs
   `install_attestation { status: "confirmed", tx_hash, block_number }`.
   Phoenix audits `delegation.install_broadcast` and enqueues
   `Bank.Runtime.Workers.VerifyInstallOnchain`. The poller's next
   run sees the row already mid-verification and short-circuits
   (idempotency on `delegation_id`).

> **Critical invariant**: the row is **NOT** flipped to `:active`
> here. Phoenix only enqueues the verifier worker. Pinned by
> `BankWeb.API.V1.WalletBindingsInstallControllerTest`'s "confirmed
> enqueues VerifyInstallOnchain but does NOT mark `:active`" case.

While the install is in flight the card shows
`#session-permission-installing` ("Installing — awaiting on-chain
verification…"). The browser polls
`GET /wallet_bindings/:id/install_status` (browser-session viewer)
through the lifecycle:
`awaiting → submitted → verifying → active | failed`.

### A.5 On-chain verification

`Bank.Runtime.Workers.VerifyInstallOnchain` reads the kernel's
installed validator set via `Bank.Chains.KernelVerifier.verify/2`
(`eth_call` only) and asserts the `validation_id` Phoenix expected
matches the on-chain reality.

- Match → row flips to `:active`,
  `last_reason: "browser_signed_install"`, `granted_at`,
  `installed_at_block`, and `install_tx_hash` set. **Audit
  evidence**: `delegation.install_confirmed_onchain`.
- Mismatch → row stays out of `:active`,
  `last_reason: "install_failed:onchain_state_mismatch"`. **Audit
  evidence**: `delegation.install_failed { reason: "unknown" }`.
- RPC unreachable (after 5 retries) → row marked `:install_failed`,
  `last_reason: "install_failed:onchain_verification_unreachable"`.
- Smart account not deployed → row marked `:install_failed`,
  `last_reason: "install_failed:smart_account_not_deployed"`.

**Expected (within ~10–30 s of the bundler receipt):**

```sh
curl -s \
  -H "Authorization: Bearer $OPERATOR_API_KEY" \
  http://localhost:4000/v1/wallet_bindings/<binding_id>/install_status \
  | jq
```
```json
{ "state": "active", "delegation_id": "<uuid>", "last_reason": "browser_signed_install" }
```

The **Smart Account Delegation** card on the left flips to
**Active** with the on-chain tx hash.

**Visible-fail check (malicious browser)**: in browser dev tools,
intercept the install attestation `POST` and replace `validation_id`
with arbitrary 21 bytes. Re-submit. The verifier worker calls
`KernelVerifier.verify/2` with the spoofed id, observes the on-chain
validator does not match, and writes
`delegation.install_failed { reason: "unknown",
last_reason: "install_failed:onchain_state_mismatch" }`. The
delegation MUST NOT flip to `:active`. Pinned by
`Bank.Runtime.Workers.VerifyInstallOnchainTest`'s
"malicious validation_id" case.

### A.6 First intent against the verified delegation

```sh
curl -s -X POST \
  -H "Authorization: Bearer $OPERATOR_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  http://localhost:4000/v1/intents \
  -d '{
    "kind": "transfer",
    "agent_id": "smoke-reviewer",
    "asset": "USDC",
    "chain": "base-sepolia",
    "amount": "1.00",
    "target": { "raw_address": "0x..." },
    "source": "smoke",
    "idempotency_key": "<uuid>"
  }' | jq
```

Reaches `:executed` (or `:approval_required`, which is a
**successful** response, not a failure — the agent should hand off
to the operator instead of looping).

### A.7 Revoke

Click **Revoke delegation** (`#revoke-btn`) on the delegation card.
Browser-signed delegations carry `root_validator_owner: "user"`,
so the revoke worker (`Bank.Runtime.Workers.RevokeDelegation`)
takes the **sentinel-revoke path** for this row — see
[`docs/design/browser-signed-install.md`](../design/browser-signed-install.md)
§ 6 and the implementation under [#475](https://github.com/Linh86/cryptobank/issues/475).
The delegation row transitions
`:active → :revoking → :revoked`; subsequent intents against the
same smart account are held / blocked by the runtime decision
pipeline.

For legacy operator-signed delegations
(`root_validator_owner: "operator"`), the revoke path is the
cryptographic `Kernel.uninstallValidation(...)` call through the
adapter — that path uses `OPERATOR_PRIVATE_KEY` for
operator-emergency revoke only. Browser-signed installs do NOT
share that path.

---

## Path B — Manual on-chain end-to-end (escape hatch)

Path B is the manual reviewer route to a real `:active` outcome. It
is the **only** path to a real on-chain pass while
[#500](https://github.com/Linh86/cryptobank/issues/500) /
[#501](https://github.com/Linh86/cryptobank/issues/501) are still
open, and it remains the documented fallback after they land
(useful for debugging, integration tests, or unblocking partners).

### B.1 Inject a real bundler call from the JS console

While the install LiveView is open and you have just signed the
binding (state `signing` / `submitted`):

1. Open the browser dev tools console.
2. Build a real UserOperation against the kernel's
   `installValidation(...)` selector using `viem` or the ZeroDev
   SDK (whichever your operator side has bundled). Sign it with the
   same EOA the binding row is anchored to.
3. Submit to the public-tier bundler RPC URL surfaced in the
   install envelope (`bundler_rpc_url`).
4. Wait for `eth_getUserOperationReceipt` to return a non-null
   receipt.
5. POST a real `confirmed` attestation through the API
   (`POST /v1/wallet_bindings/:id/install_attestation` with
   `Authorization: Bearer $OPERATOR_API_KEY`) carrying the **real**
   `install_userop_hash`, `tx_hash`, and `block_number`.

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

Every documented failure surfaces as a category atom from
`Bank.SessionPermissions.BrowserInstall.failure_categories/0`.
Free-form upstream strings collapse to `unknown`.

| Trigger                                  | Where it fails                                                                                 | What you'll see                                                                                                                  |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Wallet on Base mainnet (8453)            | JS hook (`SUPPORTED_CHAIN_IDS`)                                                                | LiveView pushes `session_permission_install:wrong_chain`; no envelope ever fetched.                                              |
| Wallet on any other chain                | JS hook                                                                                        | Same as above.                                                                                                                   |
| EOA balance below 0.005 ETH              | JS hook (`eth_getBalance` pre-flight)                                                          | Card surfaces `#session-permission-failed` with `reason: "insufficient_funds"`; no wallet popup fires; no audit row.             |
| User rejects EIP-712 install signature   | ZeroDev SDK throws (EIP-1193 `4001`)                                                           | POST `install_attestation status: "user_rejected"` → audit `delegation.install_failed reason: "user_rejected"`; no row created.   |
| Bundler 4xx / validation revert          | `sendUserOperation` throws non-4001                                                            | POST `bundler_rejected` → audit `delegation.install_failed reason: "bundler_rejected"`.                                          |
| Bundler 5xx / unreachable                | `sendUserOperation` throws fetch error                                                         | POST `bundler_unavailable` → audit `delegation.install_failed reason: "bundler_unavailable"`; pending row (if any) → `:install_failed`. |
| UserOp accepted, receipt reverts on chain| `waitForUserOperationReceipt` returns `success: false`                                         | POST `reverted` with `reason: "userop_reverted"` → row → `:install_failed reason: "userop_reverted"`.                            |
| Hook timeout (45 s)                      | Hook wall-clock                                                                                | POST `reverted` with `reason: "attestation_timeout"` → row → `:install_failed reason: "attestation_timeout"`.                    |
| Tab closed mid-poll                      | Server-side `Bank.Runtime.Workers.PollInstallUserOpReceipt` (#500)                             | Poller advances the row to `:install_failed reason: "attestation_timeout"` after the wall-clock deadline OR enqueues the verifier on a real receipt. Browser is non-critical-path. |
| On-chain validator not installed         | Verifier worker (`Bank.Chains.KernelVerifier`)                                                 | Maps `:not_installed` → `:install_failed`, `last_reason: "install_failed:onchain_state_mismatch"`.                                |
| Smart account never deployed             | Verifier worker                                                                                | Maps `:not_deployed` → `last_reason: "install_failed:smart_account_not_deployed"`.                                                |
| Phoenix RPC not configured               | Verifier worker                                                                                | Maps `:rpc_not_configured` → `last_reason: "install_failed:onchain_verification_unreachable"`.                                    |
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

## Recovery guidance

The smoke is **valid only if** every observed terminal state matches
this matrix. Operators do not invent a recovery that bypasses the
verifier.

| Observed state                                   | Recoverable? | How                                                                                                  |
| ------------------------------------------------ | ------------ | ---------------------------------------------------------------------------------------------------- |
| `:active` after `delegation.install_confirmed_onchain` | (success) | —                                                                                                    |
| `:install_failed` with documented `reason`       | Yes          | Refresh the install card and click **Install** again. The failed row stays in audit as evidence; no manual cleanup. |
| `:pending` for >30 s with `delegation.install_broadcast` but no `delegation.install_confirmed_onchain` | Wait | Verifier is retrying. If `install_status` returns `state: "verifying"` for >2 minutes, check the verifier RPC config and the worker log for `onchain_verification_unreachable`. Do not manually flip the row. |
| `:pending` for >5 minutes with no `install_broadcast` | Wait, then re-run | Receipt poller (#500) carries the row to `:install_failed reason: "attestation_timeout"` after the configured wall-clock deadline. Re-bind and re-install when ready. |
| Chain RPC outage                                 | Wait, then re-run | Verifier marks affected installs `:install_failed reason: "unknown"` with `last_reason: "install_failed:onchain_verification_unreachable"` after five attempts. Re-running against a healthy RPC creates a fresh delegation row; the failed row remains in audit. |
| `:active` row you do not recognise               | Audit it     | Read the audit trail for the binding (`/audit` filtered by binding id). Every browser-signed install carries `delegation.install_signed_by_user` in its trail; if missing, the row was created by a legacy path — operator-emergency cryptographic revoke (legacy `:operator` rows) goes through the adapter, never the browser session. |

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

`correlation_id` on every event equals the `binding_id`. The smoke
is **valid only if** the trail above appears in order for a
successful run; the absence of `delegation.install_confirmed_onchain`
means the install is **not** verified on chain regardless of any UI
or attestation claim.

---

## Preflight task

`mix bank.browser_install.smoke` is the reviewer's preflight. It is
**preflight-only by default** — it does not sign, broadcast, or
modify chain state, regardless of arguments. Behaviour:

- Reads env from the parent process (`System.get_env/0`); no `.env`
  sourcing.
- Validates required vars: `BANK_ENDPOINT`, `OPERATOR_API_KEY`,
  `BASE_RPC_URL`, `BUNDLER_RPC_URL`. Optional:
  `BASE_SEPOLIA_CHAIN_ID` (defaults to `84532`; the task refuses
  any other value).
- Pings the configured Phoenix endpoint and the install envelope
  controller for a known-bad `binding_id` to confirm the route is
  wired (expected `404 not_found`); does NOT call the bundler or
  Base RPC.
- Prints a redacted summary (no full secrets, no full URLs with
  embedded keys) and a numbered reviewer checklist mirroring this
  runbook.
- Refuses any `--confirm` / `--broadcast` style arg with a clear
  error message: signing and broadcasting belong to the browser
  hook (Path A) or to the reviewer's `cast` / SDK call (Path B),
  never to a Mix task.
- Exits non-zero if any required env is missing or the chain id
  resolves to anything other than `84532`.

```sh
$ mix bank.browser_install.smoke
Browser ZeroDev install smoke — preflight only
  BANK_ENDPOINT:        http://localhost:4000  ok
  OPERATOR_API_KEY:     cb_********…  ok
  BASE_RPC_URL:         (configured)  ok
  BUNDLER_RPC_URL:      (configured)  ok
  BASE_SEPOLIA_CHAIN_ID: 84532  ok
  install routes wired: 404 on probe binding  ok

Reviewer checklist:
  1. Connect wallet on Base Sepolia (84532) at http://localhost:4000/
  2. Sign the EIP-191 binding challenge (personal_sign).
  3. Click "Install session permission" and approve the
     EIP-712 install signature in your wallet.
  4. Wait for "Smart Account Delegation" to flip to Active
     (~10–30 s after the bundler receipt).
  5. Confirm the audit trail shows
     install_envelope_issued → install_signed_by_user →
     install_broadcast → install_confirmed_onchain.

This task did not sign or broadcast anything.
```

---

## Out of scope

- **v0.2 browser-signed cryptographic revoke.** v0.1 ships the
  sentinel audit anchor for `:user`-rooted rows; the user-signed
  uninstall flow is a follow-up.
- **Base mainnet.** No mainnet enablement is in this runbook; the
  install path refuses any `chain_id != 84532`.
- **Paymaster / sponsored gas.** The user EOA pays gas in Base
  Sepolia testnet ETH.
- **Per-policy on-chain encoding.** v0.1 ships `toSudoPolicy({})`
  on chain (matches the legacy adapter); per-policy encoding from
  `Bank.SessionPermissions.Scope.default()` is a v0.2 ticket. The
  Phoenix outer decision pipeline gates every transfer
  authorization independently of on-chain scope, so the sudo plugin
  is the conservative v0.1 default.
