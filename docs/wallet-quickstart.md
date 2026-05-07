# Wallet quickstart — connect, bind, install, revoke

Operator-facing walkthrough for the MVP browser wallet flow on **Base
Sepolia**. From a fresh clone to a verified EOA binding and a scoped
session permission install in under five minutes — without ever
pasting a private key into the browser or Phoenix.

If you are a partner trying this for the first time, this is the
right entry point. The deeper architecture lives in
[`docs/wallet-connect.md`](wallet-connect.md); the live-adapter
smoke runbook lives in [`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md).

## Scope

- Base Sepolia (chain id `84532`) only. Base mainnet (8453) is
  post-MVP and surfaces as wrong-chain.
- Browser wallet — MetaMask, Rabby, or any EIP-1193 provider.
  Mobile WalletConnect is out of scope for the MVP.
- Single active delegation per workspace. Multi-account selection
  is deferred.
- The session permission scope is fixed: USDC transfer (Phoenix
  policy gated), 0x swap routes on Base Sepolia, and a deposit
  into the single allowlisted Morpho USDC vault. Withdraw / redeem,
  arbitrary calldata, unlimited approvals, borrow / leverage, and
  mainnet are explicitly denied — see the **Permission scope**
  section below for the plain-language rendering.
- The MVP browser flow signs **both** the EIP-191 binding challenge
  AND the install UserOperation in the browser via the user's
  connected EOA wallet. `OPERATOR_PRIVATE_KEY` is **not** involved
  in the normal install path — Phoenix marks the delegation
  `:active` only after `Bank.Runtime.Workers.VerifyInstallOnchain`
  reads the kernel and confirms the validator is installed (#474).
  See [`docs/runbooks/browser-signed-install-smoke.md`](runbooks/browser-signed-install-smoke.md)
  for the reviewer-ready smoke runbook and
  [`docs/design/browser-signed-install.md`](design/browser-signed-install.md)
  for the architecture.

## Before you start

- A browser with an EIP-1193 wallet extension (MetaMask, Rabby,
  Frame). Mobile-only wallets are not supported in the MVP.
- A Base Sepolia EOA you control. The MVP **never** asks you to
  paste the private key into the browser or into Phoenix; ownership
  is proven through `personal_sign`.
- Some Base Sepolia ETH on that EOA for gas — about **0.005 ETH**
  is plenty for one full install + revoke loop. Use a public
  faucet (Alchemy, Coinbase, QuickNode) and send to your EOA.
- The smart account itself is funded by you; the MVP does **not**
  promise a paymaster or sponsored gas.
- Phoenix and the chain adapter both running locally (or against a
  staging stack):

```sh
mix phx.server
# in chain_adapter/
npm run dev
```

If you are running the live-adapter smoke for the first time, the
adapter `.env` setup lives in
[`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md) §Prereqs.

## Walkthrough

### 1. Open the connection page

Navigate to `http://localhost:4000/`. The first card on the right is
the **Browser wallet** card (`#wallet-status-card`). On a fresh
session it shows `#wallet-status-disconnected` with a single
**Connect wallet** button.

### 2. Connect

Click **Connect wallet** (`#wallet-connect-btn`). Your wallet will
prompt you to expose accounts; the prompt fires only after the
explicit click — Phoenix never invokes `eth_requestAccounts`
unsolicited.

If your wallet is already on Base Sepolia, the card transitions to
`#wallet-status-awaiting-signature`. If it is on Base mainnet
(or any other chain), the card transitions to
`#wallet-status-wrong-chain` with copy "Switch to Base Sepolia
(84532) to continue" — switch networks in your wallet and reconnect.

### 3. Sign the binding challenge

Phoenix issues a short-lived (5-minute) EIP-191 challenge that names
your address, the workspace, and a server-issued nonce. Your wallet
will pop a sign request showing the human-readable message; the
hook only ever invokes `personal_sign` (no typed-data signing, no
transaction signing). The exact text starts with "CryptoBank wants
to bind your wallet for an MVP delegation install."

When you sign, the hook pushes the signature back. Phoenix runs
secp256k1 ECDSA recovery (`Bank.WalletBindings.Signature.verify_eip191/3`)
and stamps the binding row. The card transitions to
`#wallet-status-bound` with a Verified-at timestamp and a
**Disconnect** button.

### 4. Review the permission scope

A second card appears: **Session permission**
(`#session-permission-card`). The permission summary lists the
allowed and denied actions, sourced from
`Bank.SessionPermissions.Scope.default/0`. Read each line — this is
the agent's full authority on Base Sepolia for the duration of the
delegation.

### 5. Install (browser-signed)

Click **Install session permission**
(`#session-permission-browser-install-btn`). The browser-driven
flow (epic #471) takes over:

1. Phoenix returns the canonical install envelope from
   `GET /v1/wallet_bindings/:id/install_envelope` — scope JSON,
   `scope_hash`, kernel + permissions package version, and the
   browser-tier bundler RPC URL.
2. The JS hook checks the wallet is on Base Sepolia (84532); any
   other chain pushes `session_permission_install:wrong_chain`
   without invoking `eth_requestAccounts`.
3. Your wallet pops a `personal_sign` prompt over the
   server-issued scope-bound message. Sign it.
4. The browser builds and submits the install UserOperation through
   the public-tier bundler — **your EOA is the signer**.
   `OPERATOR_PRIVATE_KEY` is not involved.
5. The browser POSTs each lifecycle step to
   `POST /v1/wallet_bindings/:id/install_attestation`
   (`submitted`, then `confirmed` with the bundler `tx_hash` +
   `block_number`). On `confirmed`, Phoenix enqueues
   `Bank.Runtime.Workers.VerifyInstallOnchain` — it does **not**
   mark the delegation `:active` from the browser report alone.
6. The verifier worker reads the kernel's installed validator set
   via `eth_call`. Only after the on-chain check passes does the
   delegation row flip to `:active`.

While the install is in flight the card shows
`#session-permission-installing` ("Installing — awaiting on-chain
verification…"). When the verifier passes, the
**Smart Account Delegation** card on the left flips to **Active**
with the on-chain tx hash and an emitted
`delegation.install_confirmed_onchain` audit event.

> **Path A vs Path B.** The reviewer-grade smoke runbook
> [`docs/runbooks/browser-signed-install-smoke.md`](runbooks/browser-signed-install-smoke.md)
> documents two paths to a verified `:active` delegation:
> **Path A** is the real automated browser flow once the
> launch-lane PRs (#500 backend session-auth + receipt poller, #501
> frontend ZeroDev SDK + bundler) are merged on `main`; **Path B**
> is the manual `cast` / dev-console SDK fallback that always works
> and remains documented as the reviewer escape hatch. Either path
> writes the same Phoenix-side audit lifecycle and the verifier
> worker is the sole writer of `:active`.

### 6. Run an intent

Submit a transfer intent against your bound smart account; the
runtime will auto-execute under policy. The
[`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md) §Transfer
section walks the curl form.

### 7. Revoke

When you are done, click **Revoke delegation**
(`#revoke-btn`) on the delegation card. Phoenix calls
`Bank.Security.revoke_delegation/2`. The revoke worker
(`Bank.Runtime.Workers.RevokeDelegation`) branches on the row's
`root_validator_owner` (#475):

- **Operator-rooted (legacy)** — adapter signs
  `Kernel.uninstallValidation(...)` with `OPERATOR_PRIVATE_KEY`.
  Card flips to **Revoking** then **Revoked**.
- **User-rooted (browser-signed)** — operator EOA cannot
  cryptographically uninstall a user-rooted kernel. v0.1 ships the
  **sentinel audit anchor** (no-op `execute(self, 0, 0x)` UserOp)
  as the operator-emergency revoke posture. The user-signed
  cryptographic revoke flow is a v0.2 follow-up — see
  [`docs/design/browser-signed-install.md`](design/browser-signed-install.md)
  § 6.

Either path: any follow-up intent for that smart account is held /
blocked by the runtime decision pipeline.

## Permission scope

What the agent **is allowed** to do on your bound smart account:

| Kind                    | Plain language                                            | Gate                              |
| ----------------------- | --------------------------------------------------------- | --------------------------------- |
| `usdc_transfer`         | Transfer USDC to addresses your policy allows.           | Phoenix decision pipeline.        |
| `zero_x_swap`           | Execute 0x-routed swaps on Base Sepolia under policy.    | Quote source + slippage gate.     |
| `morpho_4626_deposit`   | Deposit USDC into the single allowlisted Morpho vault.   | Single-vault allowlist + policy.  |

What the agent **cannot** do:

| Kind                     | Plain language                                            |
| ------------------------ | --------------------------------------------------------- |
| `withdraw_redeem`        | Withdraw or redeem from any vault — operator-only path.  |
| `arbitrary_calldata`     | Call arbitrary contracts with arbitrary calldata.        |
| `unlimited_approvals`    | Issue unlimited token approvals.                          |
| `borrow_leverage`        | Borrow, take leverage, or run looping strategies.        |
| `mainnet`                | Execute anything on mainnet (Base or Ethereum).          |

The same scope summary lives on the delegation row's `scope` JSON
column and in the audit event's `after_ref`. Anything you don't see
in the **Allowed** table is denied at the runtime decision layer.

## Troubleshooting

| Symptom                                             | What you'll see                                           | Fix                                                                                                                       |
| --------------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| No wallet extension installed                       | `#wallet-status-not-installed` with install guidance.    | Install MetaMask / Rabby / Frame, reload.                                                                                 |
| Wallet on wrong chain (e.g. Base mainnet)           | `#wallet-status-wrong-chain` with the actual chain id.   | Switch the wallet to **Base Sepolia (84532)**. Mainnet is post-MVP.                                                        |
| User rejected the binding signature                 | `#wallet-status-bind-failed` "Wallet rejected the signing prompt." | Click **Try again** to re-issue the challenge.                                                                            |
| Install request rejected (paused runtime)           | Flash: "Runtime is paused. Resume before installing."    | Resume from the **Runtime** card, then click **Install** again.                                                            |
| Install request rejected (workspace paused)         | Flash: "Workspace agent keys are paused. Unpause before installing." | Unpause the workspace from `/security`, then retry.                                                                       |
| Install request rejected (already pending / active) | Flash: "An install is already pending / active."         | Wait for the in-flight install to complete or revoke the active delegation, then retry.                                    |
| Adapter / bundler failure during install            | `delegation.grant_failed` audit event; no delegation row created. | Check the adapter logs for the precise reason (`operator_key_missing`, `permission_install_failed`, `chain_id_mismatch`, `permission_serialization_failed`). Fix the adapter env, then click Install again. |
| Revoke attempt fails on chain                       | Delegation card shows **Revoke failed** with `last_reason` and a `#delegation-revoke-failure-banner`. | Click **Retry revoke** (`#revoke-retry-btn`). The on-chain delegation is still live until a revoke succeeds; the runtime stays fail-closed in the meantime. |
| Delegation is revoked or expired                    | Delegation card disappears (terminal state).             | Reconnect your wallet and click **Install session permission** to start a fresh delegation.                                 |

If a step blocks for more than ~30 seconds, check
`http://localhost:4000/audit` for the most recent
`session_permission.install_requested`,
`delegation.connect_requested`, `delegation.grant_failed`, or
`delegation.state_changed` event.

## Security guarantees

- **No private-key paste**, ever. The browser hook signs the
  server-issued binding message AND the install UserOperation via
  the user's EOA (`personal_sign` for the binding,
  EIP-4337-compliant signature for the install). Phoenix never
  receives or stores key material. `OPERATOR_PRIVATE_KEY` is NOT
  involved in the normal install path — it remains the legacy
  cryptographic-revoke key for `:operator`-rooted delegations and
  is sourced from the operator's secrets manager (see
  [`docs/operator-secrets-checklist.md`](operator-secrets-checklist.md)).
- **No signing surface beyond `personal_sign`** in the browser hook.
  `eth_sign`, `eth_signTransaction`, `eth_signTypedData*`, and any
  broadcast method are forbidden by source-level guard
  (`test/bank_web/live/wallet_connect_hook_safety_test.exs`).
- **No nonces, signatures, or message bodies in audit logs.** Audit
  events for binding and install carry only address, chain id,
  workspace id, scope summary, and timestamps. Pinned by
  `Bank.WalletBindingsTest` and `Bank.SessionPermissionsTest`.
- **No mainnet, paymaster, multi-account, or arbitrary-contract
  claims.** The UI wording is pinned by
  `BankWeb.ControlLiveTest`'s connection page copy guard, and the
  scope summary explicitly denies these capabilities.

## Local mocked smoke

The full happy path — bind → install request → granted callback →
active delegation → revoke → revoked callback → blocked intent —
runs as a single ExUnit test against the in-process Phoenix stack
with no chain calls and no adapter network IO:

```sh
mix test test/bank/smoke/wallet_delegation_smoke_test.exs
```

The test is structured as a numbered checklist mirroring the
walkthrough above; run it after any change in `Bank.WalletBindings`,
`Bank.SessionPermissions`, or `Bank.Delegations` to confirm the MVP
contract still holds end-to-end. CI runs it as part of
`mix precommit`.

## Live Base Sepolia smoke

When you want to validate the full flow against a real bundler /
operator key on Base Sepolia, follow
[`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md). The browser
walkthrough above replaces the curl-driven §Grant section with the
Connect → Bind → Install path; everything else (transfer, revoke,
verification) is identical.

## CLI / headless setup is a dev fallback only

Operators **must** use the browser flow for the MVP self-serve
experience. The curl-based grant in `docs/mvp-smoke-runbook.md` is
preserved as a development fallback for adapter integration tests
and for unblocking partners when the browser flow itself is the
thing being debugged. It is **not** a primary onboarding path —
specifically, it does not show the operator the permission scope
before signing, and it requires manually-supplied
`smart_account_id` + EOA values that the browser flow derives
automatically.

When in doubt, use the browser flow. Reach for the curl form only
to bypass a UI bug while you are fixing it.
