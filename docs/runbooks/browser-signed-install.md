# Browser-signed install smoke runbook (Base Sepolia)

> Status: MVP launch runbook (#476). Sits on top of the implementation
> from #473 (frontend ZeroDev hook), #474 (Phoenix attestation +
> on-chain verifier), and #475 (revoke parity). Backed by the design
> note in [`docs/design/browser-signed-install.md`](../design/browser-signed-install.md).

A reviewer reproduces the **non-custodial** install path on **Base
Sepolia** and verifies — by audit trail and `/v1/wallet_bindings/:id/install_status`
— that the user's wallet (not any server key) signed the install
UserOperation, that Phoenix only marks the delegation `:active` after
on-chain verification, and that each documented failure mode surfaces
visibly. **No mainnet step exists in this runbook.**

The smoke is intentionally annoying to fake-pass:

- Every step has an **expected audit event** name (`Bank.Audit.replay/1`
  is the source of truth, not the LiveView).
- The four **must-fail** scenarios at the end (wrong-chain, user
  rejection, missing on-chain verification, malicious browser) each
  have a deterministic visible-failure check the reviewer signs off
  on.
- `OPERATOR_PRIVATE_KEY` does not appear in any expected log line for
  this path — if it does, the install is on the legacy server-signed
  path and the smoke has not been run.

---

## 0. Prereqs

- Phoenix dev stack reachable (`mix phx.server`, default
  `http://localhost:4000`). The chain adapter does **not** participate
  in this path.
- Base Sepolia RPC reachable from Phoenix. The verifier worker reads
  `eth_call` only; configure it in `config/runtime.exs` or the
  workspace settings, otherwise the verifier surfaces
  `onchain_verification_unreachable` and you cannot complete the
  smoke.
- A browser EOA on **Base Sepolia (chain id `84532`)** with at least
  **0.005 ETH** for the install + first transfer. Use a public faucet
  (Alchemy, Coinbase, QuickNode).
- A wallet extension that exposes `eth_requestAccounts` +
  `personal_sign` — MetaMask, Rabby, or Frame. Mobile-only wallets are
  out of scope for the MVP.
- Browser developer tools open. The runbook expects you to read
  network requests against `/v1/wallet_bindings/:id/install_envelope`,
  `/install_attestation`, and `/install_status`.

If any of those is missing, **stop**. The smoke is not "skip the
prereq and call it green."

---

## 1. Connect wallet (browser)

1. Navigate to `http://localhost:4000/`.
2. Click **Connect wallet** (`#wallet-connect-btn`).
3. Approve the wallet's `eth_requestAccounts` prompt.

**Expected UI**: card transitions to `#wallet-status-awaiting-signature`.
If you see `#wallet-status-wrong-chain`, switch your wallet to Base
Sepolia (84532) and reconnect.

**Expected audit**:

```
event_type           subject_type  notes
delegation.connect_requested wallet_binding wallet address + chain
```

**Visible-fail check**: if you skip Base Sepolia and stay on Base
mainnet (8453), the card MUST surface `#wallet-status-wrong-chain`
with copy "Switch to Base Sepolia (84532) to continue". The runbook
fails this step — you cannot proceed to install on mainnet.

---

## 2. Sign the binding challenge

1. Phoenix issues a 5-minute EIP-191 challenge naming your address,
   the workspace, and a server-issued nonce.
2. Approve the wallet's `personal_sign` prompt. The hook only ever
   invokes `personal_sign` — never `eth_sign`, never typed-data,
   never any transaction-signing method (pinned by
   `test/bank_web/live/wallet_connect_hook_safety_test.exs`).
3. Phoenix runs secp256k1 ECDSA recovery via
   `Bank.WalletBindings.Signature.verify_eip191/3` and stamps the
   binding row.

**Expected UI**: card transitions to `#wallet-status-bound` with a
Verified-at timestamp.

**Expected audit** (filtering by the binding id as
`correlation_id`):

```
event_type                       subject_type
delegation.connect_requested     wallet_binding
delegation.identity_bound        wallet_binding
```

The audit row payload contains the address, chain id, workspace id,
and timestamps — **never** the nonce, signature bytes, or any
session-signer secret.

---

## 3. Review the permission scope

A second card appears: **Session permission**
(`#session-permission-card`). The summary lists every allowed and
denied action sourced from `Bank.SessionPermissions.Scope.default/0`.

Read each row before clicking install. The plain-language scope is:

- **Allowed**: USDC transfer (Phoenix policy gated), 0x swap routes
  on Base Sepolia under policy, deposit into the single allowlisted
  Morpho USDC vault.
- **Denied**: withdraw / redeem from any vault, arbitrary calldata,
  unlimited approvals, borrow / leverage, mainnet (Base or
  Ethereum).

If the scope summary differs from `Bank.SessionPermissions.Scope.default/0`
(check
`http://localhost:4000/audit/replay/<binding_id>` after step 4),
**stop**. The browser is rendering a different scope than Phoenix
canonicalised — that is exactly the malicious-browser scenario the
on-chain verifier (§ 6) catches.

---

## 4. Install — the user's wallet signs the install UserOp

> **This is the load-bearing step.** No server key participates. The
> wallet signs the install UserOp; the browser submits to the bundler;
> Phoenix observes the submission via attestation and verifies on
> chain.

1. Click **Install session permission**
   (`#install-session-permission-btn`).
2. The browser fetches `GET /v1/wallet_bindings/:id/install_envelope`
   from Phoenix. The envelope carries the canonical scope JSON, the
   smart-account address, the chain id (`84532`), the EntryPoint v0.7
   address, the kernel version, the permissions package version, and
   a SHA-256 `scope_hash` over the canonical scope JSON.
3. The ZeroDev SDK in the browser builds the install UserOperation
   against the envelope's scope, **byte-for-byte**, and prompts your
   wallet to sign. The wallet is the **only** signer of this UserOp.
4. The browser submits the signed UserOp to the bundler RPC and
   reports back to Phoenix:
   - On submission: `POST /v1/wallet_bindings/:id/install_attestation`
     with `status: "submitted"`, the install UserOp hash, the
     `permission_id` (4 bytes), and the `validation_id` (21 bytes).
     Phoenix inserts a `:pending` delegation row keyed by
     `(binding_id, install_userop_hash)` and stamps
     `delegation.install_signed_by_user`.
   - On bundler confirmation:
     `POST /v1/wallet_bindings/:id/install_attestation` with
     `status: "confirmed"`, the bundler `tx_hash`, and
     `block_number`. Phoenix stamps
     `delegation.install_broadcast` and enqueues
     `Bank.Runtime.Workers.VerifyInstallOnchain`.

**Expected audit (in order)**:

```
delegation.install_envelope_issued  wallet_binding
delegation.install_signed_by_user   delegation
delegation.install_broadcast        delegation
```

**Polling check** (use a second terminal):

```sh
curl -s -H "Authorization: Bearer $CRYPTOBANK_API_KEY" \
  http://localhost:4000/v1/wallet_bindings/<binding_id>/install_status \
  | jq .
# expect:  { "state": "submitted", ... }   then  { "state": "verifying", ... }
```

The state surface walks `awaiting → submitted → verifying`. The
`:active` transition is **not yet** written here — that is § 5.

**Visible-fail check (user rejection)**: at step 3, click
**Reject** in the wallet's signature prompt. The browser MUST
surface `#session-permission-failed` with the operator-facing copy
"Wallet rejected the signing prompt." The audit MUST contain
`delegation.install_failed` with `reason: "user_rejected"` (one of
the eight categories in
`Bank.SessionPermissions.BrowserInstall.failure_categories/0`). If
the audit row carries any free-form upstream string instead of one
of the eight allowlist categories, the smoke fails — file a P1.

---

## 5. On-chain verification — Phoenix is the gate

The verifier worker (`Bank.Runtime.Workers.VerifyInstallOnchain`) is
the **sole writer** of the `:active` transition. It reads the user's
smart-account state via `Bank.Chains.KernelVerifier.verify/2`
(`eth_call` only — no chain writes) and asserts that the
`validation_id` Phoenix expected matches the on-chain reality.

1. Wait ~5–15 seconds for the worker to run (it's bounded; max 5
   attempts with exponential backoff).
2. Poll `install_status` again:

```sh
curl -s -H "Authorization: Bearer $CRYPTOBANK_API_KEY" \
  http://localhost:4000/v1/wallet_bindings/<binding_id>/install_status \
  | jq .
# expect:  { "state": "active", "delegation": { ... } }
```

3. Inspect the audit replay for the binding:

```sh
curl -s -H "Authorization: Bearer $CRYPTOBANK_API_KEY" \
  http://localhost:4000/v1/intents/<not-applicable-use-audit-search> \
  # or in the operator UI: http://localhost:4000/audit
```

**Expected audit (final tail)**:

```
delegation.install_envelope_issued
delegation.install_signed_by_user
delegation.install_broadcast
delegation.install_confirmed_onchain   <-- written by VerifyInstallOnchain
```

The `:active` state on the delegation row, plus
`delegation.install_confirmed_onchain` in the audit trail, are the
**only** evidence the smoke accepts as a pass for this step. A
`:pending` row with no on-chain confirmation is **not** a pass —
move to the failure section below.

**Visible-fail check (missing on-chain verification)**:
temporarily point the verifier at an RPC that returns
`(0x, "method not supported")` (or set
`BASE_SEPOLIA_RPC_URL` to an empty string in `config/runtime.exs`
and restart). Re-run the install. The verifier MUST exhaust its
five attempts and write `delegation.install_failed` with
`reason: :unknown` and the worker log line
`onchain_verification_unreachable`. The delegation MUST NOT flip
to `:active`. If the delegation flips to `:active` without the
verifier running, **stop the smoke** and file a P0 — the
non-custodial guarantee is broken.

**Visible-fail check (malicious browser)**: in browser dev
tools, intercept the install attestation `POST` and replace
`validation_id` with arbitrary 21 bytes. Re-submit. The verifier
worker calls `KernelVerifier.verify/2` with the spoofed
`validation_id`, observes that the on-chain validator does not
match, and writes `delegation.install_failed` with
`reason: :unknown` and the worker log line
`onchain_state_mismatch`. The delegation MUST NOT flip to
`:active`. (Pinned by
`test/bank/runtime/workers/verify_install_onchain_test.exs`.)

---

## 6. First intent against the verified delegation

Submit a transfer intent against the bound smart account. The
runtime decision pipeline auto-executes if policy allows.

```sh
curl -s -X POST -H "Authorization: Bearer $CRYPTOBANK_API_KEY" \
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
  }' | jq .
```

The intent should reach `:executed` (or `:approval_required` if the
policy chain demands it — that is **success**, not failure; see
[`docs/api/sdk-surface.md`](../api/sdk-surface.md)). If the runtime
holds with `delegation_not_active` the verifier hasn't completed —
re-check § 5.

---

## 7. Revoke

Click **Revoke delegation** (`#revoke-btn`) on the delegation card.
Browser-signed delegations carry `root_validator_owner: "user"`,
so the revoke worker (`Bank.Runtime.Workers.RevokeDelegation`)
takes the **sentinel-revoke path** for this row — see
[`docs/design/browser-signed-install.md`](../design/browser-signed-install.md)
§ 6 and `lib/bank/runtime/workers/revoke_delegation.ex`. The
delegation row transitions
`:active → :revoking → :revoked`; subsequent intents against the
same smart account are held / blocked by the runtime decision
pipeline.

**Expected audit (tail)**:

```
security.revoke_requested  delegation
delegation.state_changed   delegation       state=revoked
```

For legacy operator-signed delegations
(`root_validator_owner: "operator"`), the revoke path is the
cryptographic `Kernel.uninstallValidation(...)` call through the
adapter — **that** path uses `OPERATOR_PRIVATE_KEY`, by design, for
operator-emergency revoke only. Browser-signed installs do NOT
share that path.

---

## Failure-mode reference (must-fail allowlist)

If the operator does not see the delegation move to `:active` after
~30 seconds, the install is in one of these documented states. Match
the audit `reason` to the row below; do **not** invent a recovery
that bypasses the verifier.

| `reason` (audit row) | What happened | Operator recovery |
| -------------------- | ------------- | ----------------- |
| `user_rejected`      | The user clicked Reject in their wallet's signature prompt. No UserOp was broadcast. | Click **Install** again to re-issue the envelope. The prior `:install_failed` row stays in audit as evidence. |
| `bundler_rejected`   | The bundler refused the signed UserOp (e.g. invalid initCode + callData combination, fee market drift). No on-chain submission. | Refresh and click **Install** again. If repeated, capture the bundler RPC response and file an incident — the runbook intentionally does not auto-retry. |
| `bundler_unavailable`| Bundler RPC unreachable from the browser. | Confirm bundler URL on the configured workspace; click **Install** again once it returns. |
| `chain_id_mismatch`  | Wallet switched chains between scope review and signature. | Switch the wallet back to Base Sepolia (84532) and click **Install** again. |
| `insufficient_funds` | EOA had less than the threshold ETH at signature time (default 0.005 ETH). | Top up from a public faucet, refresh, click **Install** again. |
| `userop_reverted`    | The bundler accepted the UserOp but it reverted on chain (e.g. EntryPoint refused initCode because the smart account was already deployed). | Inspect the tx on a Base Sepolia explorer using the audit row's `install_userop_hash`. File an incident. |
| `attestation_timeout`| Browser never reported a terminal status within the timeout window. | Refresh; the operator UI will show `awaiting`. Click **Install** again. |
| `unknown` + worker log `onchain_verification_unreachable` | Verifier worker exhausted retries against the configured RPC. | **Do not** mark this install as live. Fix RPC config first; re-running the smoke is the only acceptance signal. |
| `unknown` + worker log `onchain_state_mismatch` | The validator the browser claimed to install does not exist on chain. | Stop the smoke. This is the malicious-browser path — the verifier caught it. File a P0 if it occurred against an honest browser. |
| `unknown` + worker log `smart_account_not_deployed` | The bundler reported a tx hash but the smart account is not deployed at the expected CREATE2 address. | Stop the smoke. Either the deployed address is wrong (config drift) or the deployment race window hasn't closed — re-poll the verifier; if it still fails, file an incident. |

The eight `reason` atoms above are the canonical allowlist
(`Bank.SessionPermissions.BrowserInstall.failure_categories/0`).
Anything else collapses to `:unknown` — the audit row never carries
a free-form upstream string.

## Audit-replay evidence summary

The smoke is **valid only if** the audit replay for the binding
contains, in order:

```
delegation.connect_requested
delegation.identity_bound
delegation.install_envelope_issued
delegation.install_signed_by_user
delegation.install_broadcast
delegation.install_confirmed_onchain
```

If the trail is missing
`delegation.install_confirmed_onchain`, the install is **not**
verified on chain — the delegation stays `:pending` or
`:install_failed`. There is no path to `:active` that bypasses the
verifier worker, by design (§ 5).

If the trail contains `delegation.dispatched` /
`delegation.state_changed{state: "granted"}` but not
`delegation.install_signed_by_user`, the install ran on the
**legacy server-signed path** through the chain adapter
(`Bank.Runtime.Workers.GrantDelegation`). The smoke for **this
runbook** has not been run — re-run from § 4 against a fresh
binding.

## Recovery guidance

- **`:install_failed` with a documented `reason`** — refresh the
  install card and click **Install** again. The verifier guarantees
  the failed row stays in audit as evidence; no manual cleanup.
- **`:pending` for >30 seconds with `delegation.install_broadcast`
  but no `delegation.install_confirmed_onchain`** — the verifier is
  retrying. If `install_status` returns `state: "verifying"` for
  >2 minutes, check the verifier RPC config and the worker log for
  `onchain_verification_unreachable`. Do not manually flip the row.
- **`:active` row that you do not recognise** — read the audit
  trail for the binding (operator console `/audit` filtered by the
  binding id). Every browser-signed install carries
  `delegation.install_signed_by_user` in its trail; if missing, the
  row was created by a legacy path and revoke must be performed
  through the cryptographic operator path.
- **Chain RPC outage** — the verifier marks affected installs
  `:install_failed` with `onchain_verification_unreachable` after
  five attempts. Re-running the smoke against a healthy RPC creates
  a fresh delegation row; the failed row remains in audit.

## What this runbook is not

- It is **not** a mainnet runbook. There is no Base mainnet step.
  The MVP launch posture is Sepolia-only; mainnet is post-MVP and
  surfaces as `wrong_chain` everywhere.
- It is **not** the legacy operator-signed install runbook. That
  path lives in [`docs/mvp-smoke-runbook.md`](../mvp-smoke-runbook.md)
  and is preserved as a development fallback. New users are expected
  to use the browser-signed path documented here.
- It is **not** a substitute for the unit tests. Pre-merge gates
  belong to `test/bank/session_permissions/browser_install_test.exs`,
  `test/bank/runtime/workers/verify_install_onchain_test.exs`,
  `test/bank_web/controllers/api/v1/wallet_bindings_install_controller_test.exs`,
  and `test/bank_web/live/session_permission_install_hook_safety_test.exs`.
  Run those before this smoke; the smoke is for live-environment
  verification.
