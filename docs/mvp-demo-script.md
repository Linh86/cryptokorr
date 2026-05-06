# CryptoBank MVP demo (5 minutes)

Script for a 5-minute walkthrough of the MVP. Audience: a technical
reviewer outside the team. Goal: show what the runtime does, who it
is for, and what is intentionally not in scope.

Pairs with [decision memo](bank-v0.1-decision-memo.md),
[runtime-flow-and-api](bank-v0.1-runtime-flow-and-api.md),
[zerodev-permissions-integration](zerodev-permissions-integration.md),
and [smart-account-and-revoke-design](smart-account-and-revoke-design.md).

## What CryptoBank is

- A non-custodial AI treasury runtime. The user keeps the smart
  account; CryptoBank acts inside scoped permissions the user grants.
- Phoenix is the decision authority. An agent submits a structured
  `AgentIntent`; the runtime evaluates policy + trust + simulation,
  decides `auto_exec` / `approval_required` / `hold` / `block`, then
  drives the TypeScript chain adapter to sign + broadcast.
- Each delegation is a ZeroDev permission installed on a Kernel v3.1
  smart account, identified by a 4-byte `permissionId`. Revoke is a
  `Kernel.uninstallValidation(...)` UserOp on the account itself.
- Today: Base only, USDC only, Sepolia is the proven chain.

## Who it's for

- Founders and individuals who want an AI treasury agent without
  surrendering custody of their account.
- Operators who want autonomous payments with policy + trust + audit
  enforced on every action.
- Not for: high-throughput trading, cross-chain bridging, custodial
  flows, free-form agent-driven contract interaction.

## What's running today

Code-complete, exercised by tests:

- Smart account: ZeroDev Kernel v3.1 modular account on Base. The
  Sepolia deployment at `0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C`
  is verified against pinned factory/implementation/root-validator
  addresses (deploy tx
  `0xe6ad5263ed7023ee6b5f7dd2c529efda27ccb4cebce449c52a58a882c9fe4724`).
- Cryptographic grant: `executeGrant` builds a `PermissionPlugin`
  via `toPermissionValidator(...)`, installs via a sudo-signed
  UserOp, serializes the account *keyless*, persists
  `permission_blob`, `permission_id`, `validation_id`,
  `kernel_version`, `permission_package_version`,
  `installed_at_block`, `install_tx_hash`, and
  `session_signer_address` on `Bank.Delegations`. (PRs #129, #130.)
- Cryptographic revoke: `executeCryptographicRevoke` reconstructs
  the plugin from the persisted blob, validates against
  `KERNEL_PERMISSION_PIN`, and dispatches
  `Kernel.uninstallValidation(...)` through ZeroDev's
  `uninstallPlugin` action, signed by `OPERATOR_PRIVATE_KEY`.
  (PRs #58, #132.)
- Phoenix control plane: append-only audit, supersession-versioned
  policies, intent / decision / execution state machines, Oban
  workers, PubSub realtime, operator console, Telegram bot.
- Intent Execution MVP (epic #134, closed by PRs #142–#148):
  `POST /v1/intents` accepts an agent intent and enqueues
  `EvaluateIntent`; the worker calls `Bank.Decisions.evaluate_intent/2`,
  which composes the trust engine, policy evaluator, simulation
  preview, and autonomy router into a single deterministic
  pipeline that writes the `TrustAssessment` /
  `SimulationReport` / `DecisionEnvelope` rows in one
  `Ecto.Multi`. `:auto_exec` decisions auto-dispatch via
  `Bank.Decisions.dispatch_auto_exec/3` (single-active-delegation
  fallback); `:approval_required` decisions enqueue
  `ExpireApproval` at the TTL and surface in `GET /v1/approvals`,
  where `approve` records the decision AND attempts dispatch
  (`dispatched` / `held` / `no_dispatch`); `:hold` and `:block`
  surface in the queue without dispatch. `POST
  /v1/intents/:id/simulate` produces fresh `SimulationReport`s
  (`pre_submit_dry_run`, `refresh`, `operator_inspection`).
  `POST /v1/intents/:id/cancel` withdraws pre-execution intents.
  `GET /v1/intents/:id/replay` returns the full deterministic
  bundle for any intent.
- Adapter: ERC-4337 v0.7 transfer / grant / revoke through a pinned
  bundler; failure taxonomy (`userop_build_failed`,
  `bundler_rejected`, `bundler_hash_mismatch`,
  `confirmation_failed`, chain revert) wired end-to-end.

Honest qualifier (per the `dfc56b6` commit message): the
cryptographic grant + revoke broadcast paths still need to confirm
on Base Sepolia with public artifacts. The encoder + executor +
persistence is landed; the public-tx-hash run is the
operator-runbook step that closes #58 / #31. Until then,
`docs/base-sepolia-execution-day.md` keeps the adapter in
`mode: sentinel-era (awaiting ZeroDev SDK integration)` for
end-to-end smokes.

## What is intentionally not in MVP

- Mainnet. Only Base Sepolia is exercised; mainnet would need a
  separate readiness pass (paymaster, gas budget, key custody).
- Multi-chain. Only Base. Runtime rejects anything else at the API
  boundary.
- Multi-asset. Only USDC has whitelisted automation policy.
- Multi-tenant smart-account binding. `Bank.Decisions.resolve_executable_account/0`
  uses a single-active-delegation fallback for v0.1: dispatch
  proceeds when exactly one delegation is currently executable;
  otherwise the runtime emits `intent.auto_exec_held` with a
  machine-readable `held_reason` and the operator dispatches
  manually via `POST /v1/decisions/{id}/execute`. Multi-tenant
  deployments will need an explicit `smart_account_id` on the
  intent contract.
- Browser-native wallet connect, EOA identity binding, and scoped
  session install ship under #168/#169/#171: operators connect on
  Base Sepolia, sign an EIP-191 challenge (verified by
  `Bank.WalletBindings`), see the canonical scope summary (USDC
  transfer / 0x swap / allowlisted Morpho deposit; no withdraw,
  no arbitrary calldata, no mainnet), and click Install to enqueue
  the existing `GrantDelegation` worker. Browser-native signing of
  the install UserOp itself remains scaffolded; v0.1 install
  signing flows through the adapter's operator key. (See
  `docs/wallet-connect.md`.)
- Wallet-risk intelligence (sanctions, scam feeds, attribution).
  Counterparties are hand-curated; epic #55 is the future track.
- Swap. `/dispatch/swap` validates the request, then sends a
  deterministic `execution.aborted` callback with reason
  `swap_not_implemented` (`chain_adapter/src/dispatch/swap.ts`).
- Multi-operator / multi-tenant. Single-operator alpha. SSO and
  per-tenant isolation are deferred (per `docs/security.md`).
- HSM/KMS for `OPERATOR_PRIVATE_KEY`. Today the operator key is an
  env var validated at startup (placeholder rejection +
  derived-address match). HSM/KMS migration is a hardening
  follow-up (`docs/zerodev-permissions-integration.md` blocker (2)
  and `docs/security.md`).
- Integrity anchoring for the audit trail. `payload_hash` is
  computed today; chain anchoring is deferred.

## How to demo (5 minutes)

The demo runs against the seeded development dataset. For a real
Sepolia round-trip, follow `docs/base-sepolia-execution-day.md`
first.

### 0. Pre-state (30s)

```sh
mix bank.demo.seed
mix phx.server
```

Open `http://localhost:4000/dashboard`. Show the four stat cards and
the readiness checklist. The seed contains the four scenarios from
`docs/demo.md` (`payroll-confirmed`, `partner-x-approved`,
`unknown-blocked`, `treasury-executing`).

For a clean active-delegation slate, check
`Bank.Delegations.list_active/0` from `iex -S mix`.

> **Live agent intake.** All five `/v1/intents` actions are live as
> of epic #134 (PRs #142–#148): submit, show, simulate, cancel,
> replay. A real demo can curl-submit a fresh intent and watch it
> evaluate, dispatch, and execute end-to-end against the seeded
> delegation. See `docs/mvp-smoke-runbook.md §6 Intent lifecycle`
> for curl recipes.

### 1. Connect (1 min)

POST to the connect endpoint:

```sh
curl -X POST http://localhost:4000/v1/connect/smart_account \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: <your-key>" \
  -d '{
    "smart_account_address": "0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C",
    "session_signer_address": "<your-session-signer-eoa>",
    "chain_id": 84532
  }'
```

Expect `202 accepted`. The controller writes an
`intent-to-connect` audit event and enqueues
`Bank.Runtime.Workers.GrantDelegation`, which calls the adapter's
`POST /dispatch/grant_delegation`. `executeGrant` installs the
permission, then emits
`delegation.state_changed{state: "granted"}` with a populated
`permission` block; Phoenix promotes the row to `:active` and the
console refreshes via PubSub.

Show: the audit row on `/audit`; the `delegations` row populated
with `permission_id`, `validation_id`, `permission_blob`,
`kernel_version`, `installed_at_block`, `install_tx_hash`,
`session_signer_address`; and the delegation card flipping to
`:active`.

### 2. Autonomous transfer (2 min)

Open `/audit/replay/<intent_id>` for the seeded `payroll-confirmed`
intent and walk:

- `intent.submitted` — agent gave the runtime the transfer.
- `decision.recorded` with `outcome: :auto_exec`,
  `risk_tier: :low` — policy passed, trust was `trusted`,
  simulation healthy.
- `execution.broadcast` — adapter built and submitted the ERC-4337
  v0.7 UserOp through the bundler.
- `execution.confirmed` — chain inclusion; `tx_refs` carries the
  Sepolia hash + block number.

Point at: the reasons list on the decision envelope (concrete rule
references); the `policy_snapshot_ref` (exact rule versions at
decision time, so replay is deterministic across later edits); and
the actor column (runtime decided, adapter signed, no human in the
loop).

### 3. Cryptographic revoke (1 min)

```sh
curl -X POST http://localhost:4000/v1/security/revoke_delegation \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: <your-key>" \
  -d '{
    "smart_account_id": "<smart_account_id>",
    "reason": "demo"
  }'
```

The path:

1. `Bank.Security.revoke_delegation/2` records `:revoke_requested`
   on the delegation. `Bank.Delegations.executable?/1` returns
   `false` from this moment on — Phoenix is fail-closed on the row
   before the adapter has built a UserOp.
2. `Bank.Runtime.Workers.RevokeDelegation` dispatches to the
   adapter's `POST /dispatch/revoke_delegation` with the
   `permission` block carrying `permission_blob` + `validation_id`.
3. The adapter reconstructs the plugin via
   `deserializePermissionAccount`, validates against
   `KERNEL_PERMISSION_PIN`, and submits
   `Kernel.uninstallValidation(...)` as a sudo-signed UserOp.
4. On confirmation the adapter emits
   `delegation.state_changed{state: "revoked", tx_refs: [...]}`;
   Phoenix transitions the row to `:revoked`.

Show the dashboard moving through `:active → :revoking → :revoked`
and the audit chain capturing each step. Try another transfer; the
worker refuses because `executable?/1` is `false`.

If you are on real Sepolia and the adapter is in sentinel-era mode,
`state: revoked` means "on-chain anchored, trust downgraded" — not
"cryptographically impossible".
`docs/base-sepolia-execution-day.md` documents this distinction.

### 4. Wrap-up (30s)

- Tail `/audit` for the demo correlation ids; show that every
  state-affecting transition emitted an event.
- For a real Sepolia run, open the revoke tx on Basescan via the
  `tx_refs` hash on the terminal `delegation.state_changed`
  callback. (The seeded dataset has no on-chain receipts.)

## Risks and caveats

- Sepolia only. Mainnet is not proven; deferred behind a separate
  hardening pass.
- `OPERATOR_PRIVATE_KEY` lives in the adapter env. Validated at
  startup (placeholder rejection + derived-address match), but no
  HSM/KMS yet.
- Live smoke today depends on the operator's adapter terminal to
  capture logs. Without a tee, failure-mode triage is harder.
- Browser-native wallet connect is scaffolded; the demo above is
  operator-driven through `/v1/connect/smart_account`.
- Single-operator alpha. No SSO, no rate limits on `/v1/`, no
  multi-tenant isolation.
- The Telegram bot is a convenience surface for alerting +
  approve/reject — not an independent control plane.
- The cryptographic grant + revoke broadcast paths are wired and
  unit-tested via mocks. The first end-to-end on-chain confirmation
  on Base Sepolia is the step that closes #58 / #31. Until then
  any environment running the adapter in sentinel-era mode treats
  `:revoked` as trust-downgrade-only.
- Smart-account binding for auto-exec dispatch is a single-active-
  delegation fallback in v0.1. Deployments with zero or two-or-more
  executable delegations get an `intent.auto_exec_held` audit row
  and a `held` HTTP response; the operator dispatches manually via
  `POST /v1/decisions/{id}/execute`. Multi-tenant deployments will
  require an explicit `smart_account_id` on the intent contract.
- Live preview is `Bank.Quotes.StubProvider` by default
  (deterministic, side-effect free). Real provider integration for
  on-chain preview is a follow-up; the runtime's fail-closed
  posture (provider error → `:hold`) is unaffected.

## What to look at after the demo

- [decision memo](bank-v0.1-decision-memo.md) — the product thesis.
- [runtime-flow-and-api](bank-v0.1-runtime-flow-and-api.md) — the
  runtime contract.
- [zerodev-permissions-integration](zerodev-permissions-integration.md)
  — the cryptographic-revoke story.
- [smart-account-and-revoke-design](smart-account-and-revoke-design.md)
  — the architectural decision for Kernel v3 + ERC-7579.
- [security](security.md) — trust boundaries and secrets inventory.
- [base-sepolia-execution-day](base-sepolia-execution-day.md) — the
  operator runbook for a real Sepolia round-trip.
- [adapter contract](../priv/adapter/contract.md) — the Phoenix ↔
  adapter wire contract.
- PRs #129 (Kernel provisioning), #130 (grant flow emits permission
  artifacts), #132 (Sepolia grant/revoke fixes + allowlist
  enforcement) for the cryptographic round-trip code path.
