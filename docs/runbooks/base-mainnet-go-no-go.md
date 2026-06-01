# Base mainnet go / no-go review

Issue [#182](https://github.com/Linh86/cryptobank/issues/182) (epic [#166](https://github.com/Linh86/cryptobank/issues/166) — Base Mainnet Readiness Gate).

> **Audience.** Operator + workspace admin + repo maintainer signing off on the first Base mainnet broadcast on this deployment.
>
> **Posture.** This is the formal closure review for epic #166. It is **point-in-time** — it grades the state of `main` at the reviewed commit and produces an explicit GO / NO-GO verdict per scope. Mainnet stays disabled by default regardless of verdict; this review only authorizes the next operator step (the capped canary per [#181](https://github.com/Linh86/cryptobank/issues/181)), never broadcast itself.

## Reviewed commit

- Commit: `4a88386c86a3fe31ac2be02956e24329ca9b1129` (`main`)
- Date: 2026-05-05
- Env class: any deployment that has cleared the [no-broadcast rehearsal](base-mainnet-rehearsal.md) on this commit
- Reviewer: Worker C (CryptoKorr parallel-issue protocol; final operator sign-off below)

## Verdict

**GO** for the **capped canary** path defined by #181 — `Bank.Chains.CanaryCaps` (chain `base`, asset `USDC`, amount `$10` per UserOp) bounds the blast radius of every first mainnet broadcast. The two safety gates (`verify_mainnet_allowed/1` from #178 and `verify_canary_caps/1` from #181) are layered before any plan is claimed for dispatch and are pinned by automated tests.

**NO-GO** for **broad mainnet usage** (i.e. removing or raising the canary caps) until [#185](https://github.com/Linh86/cryptobank/issues/185) lands. The single-active-delegation fallback is acceptable while the canary cap holds amounts at $10 per UserOp; it is **not** acceptable for sustained mainnet usage across multiple smart accounts. Any edit that removes / weakens `Bank.Chains.CanaryCaps` re-opens this review.

## Scope

### In scope

- Workspace + chain capability gates (#178).
- Read-only deployment preflight (#179).
- No-broadcast rehearsal runbook (#180).
- Capped canary broadcast in code + runbook (#181).
- Adapter dispatch boundary (Phoenix ↔ TypeScript adapter), auth, callback contract.
- Pause / kill-switch (security pauses + workspace pause).
- Audit + replay evidence.
- Allowlists (chain, asset, vault, counterparty) and their fail-closed posture.
- Secret hygiene at every boundary above.
- Multi-tenant isolation **for the canary scope** (single workspace, single smart account).
- Auth/workspace gate (epic #153) as the human entry point.
- Operator runbook readiness for first broadcast and rollback.

### Explicitly deferred (not blocking this verdict)

- Morpho mainnet (epic #197) — Morpho deposits / withdraws are off-mainnet at this commit; Worker D is mid-flight.
- Token swap mainnet (epic #188) — swap dispatch + safety gates not on `main`.
- Public launch (no public signup, no marketing copy).
- Real-world incident drills against Base mainnet — zero; the runbook covers the procedure but not muscle memory.
- Broad multi-account mainnet usage — covered by #167 (multi-account routing epic) + #185 specifically.
- Real outbound channels for notifications (SMTP / webhook HTTP / Telegram) — operator-side stubs only on `main`.

## Go criteria checklist

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Workspace `mainnet_enabled` defaults `false` and is admin-flippable only | 🟢 | `lib/bank/workspaces/workspace.ex` field default `false`, `not null`; `mainnet_changeset/2` separate from user-editable changeset; migration adds `NOT NULL`. |
| 2 | Every dispatch path checks `Bank.Chains.mainnet_allowed_for?/2` | 🟢 | 5 call sites: `lib/bank/decisions.ex` (`create_execution_plan/3`), `lib/bank/intents.ex` (`require_chain/1`), `lib/bank/runtime/workers/run_execution.ex` (defense-in-depth), `lib/bank/runtime/workers/revoke_delegation.ex`, `lib/bank/security.ex` (`validate_mainnet_allowed_for_revoke/1`). |
| 3 | Read-only mainnet preflight is shipped and pinned | 🟢 | #179 (commit `8ed962a`); `Bank.Chains.MainnetPreflight` issues only `eth_chainId` / `eth_getCode` / `eth_getBalance`; pinned by `test/bank/chains/mainnet_preflight_test.exs` "no broadcast posture". |
| 4 | No-broadcast rehearsal runbook exists and matches code | 🟢 | #180 (commit `04c1655`); [`docs/runbooks/base-mainnet-rehearsal.md`](base-mainnet-rehearsal.md) walks the operator through 4 read-only steps. `test/bank/mainnet_gate_test.exs` pins `refute_receive :adapter_was_called` when the workspace flag is off. |
| 5 | Capped canary broadcast gate is enforced in code | 🟢 | #181 (commit `15d9a6c`); `Bank.Chains.CanaryCaps.default_caps/0` returns `%{chain: "base", asset: "USDC", amount: 10}`; `verify_canary_caps/1` runs in the dispatch worker before `Bank.AdapterClient` is reached. |
| 6 | Capped canary runbook exists and matches code | 🟢 | [`docs/runbooks/base-mainnet-canary.md`](base-mainnet-canary.md) (398 lines, shipped in #181). |
| 7 | Chain id allowlist is hardcoded; testnet vs mainnet split is explicit | 🟢 | `lib/bank/chains.ex`: `@mainnet_chains ~w(base ethereum)`, `@testnet_chains ~w(base-sepolia sepolia goerli)`; `classify/1` returns `:mainnet | :testnet | :unknown`. Hardcoded enum, not config-driven, so an operator cannot widen it without a code change + review. |
| 8 | Adapter dispatch is callback-driven and never auto-broadcasts | 🟢 | `lib/bank/adapter_client.ex` returns `{:adapter_rejected | :adapter_error | :adapter_unavailable}` only; chain-side broadcast happens inside the TypeScript adapter under `chain_adapter/`, gated by its own bearer + chain config. Phoenix never sends `eth_sendRawTransaction`. |
| 9 | Adapter ↔ Phoenix authentication uses two distinct rotated bearers | 🟢 | `ADAPTER_DISPATCH_SECRET` (Phoenix → adapter) and `ADAPTER_CALLBACK_SECRET` (adapter → Phoenix) configured in `:bank, Bank.AdapterClient`; `runtime.exs` raises on missing prod values; pinned by `Bank.AdapterConfigTest` and `BankWeb.Plugs.VerifyAdapterAuthTest`. |
| 10 | Pause / kill-switch is layered (per-workspace, per-chain, global) | 🟢 | `Bank.Security.Pauses.create_pause/4` (per-workspace + per-chain, durable); `Bank.Security.PauseState.pause/3` (global in-memory); workspace `agent_keys_paused_at` rejects API keys with `:workspace_paused`. Operator runbook in [`docs/incident-runbook.md`](../incident-runbook.md). |
| 11 | Critical allowlists fail closed when empty | 🟢 | #202 P2 (commit `788da54`): `Bank.Policies.Morpho.RulesCompiler` collapses an empty allowlist to `[]`, blocking the intent; pinned by `test/bank/policies/morpho/rules_compiler_test.exs`. |
| 12 | Audit log is append-only and replay-bundle-deterministic | 🟢 | `lib/bank/audit.ex`; DB trigger at `priv/repo/migrations/20260415170600_lock_audit_events.exs` blocks `UPDATE`/`DELETE` on `audit_events`. |
| 13 | Auth/workspace gate is shipped and documented | 🟢 | Epic #153 (#163 closed today, PR #433 / commit `4a88386`); [`docs/runbooks/auth-and-access.md`](auth-and-access.md). Browser + `/v1` plugs populate `current_scope`; `RequireRole` plug enforces minimum role. |
| 14 | API key auth is shipped, scoped per workspace, refuses paused / revoked / expired | 🟢 | `BankWeb.Plugs.VerifyAPIKey` returns 401 with closed-enum reasons (`:not_found`, `:revoked`, `:malformed`, `:expired`, `:workspace_paused`); pinned by `test/bank_web/api_v1_auth_rbac_test.exs`. |
| 15 | Secret hygiene: no raw OAuth tokens / API keys / private keys / Authorization headers / tokenized RPC URLs in logs or notifications | 🟢 | `Bank.Notifications.create/1` rejects rows containing `Authorization:`, `Bearer …`, `sk_(test|live)_…`, PEM markers, `private_key=…`; redaction enumerated in [`docs/runbooks/notifications.md`](notifications.md) and [`docs/runbooks/auth-and-access.md`](auth-and-access.md). Adapter secrets compared with `Plug.Crypto.secure_compare/2`. |
| 16 | Multi-tenant isolation is enforced at scope-resolution layer for the canary scope | 🟡 | `Bank.Workspaces.resolve_scope/1` resolves a single workspace per request; `current_scope` is the single source of truth. **Caveat:** query-layer isolation (every `Repo.get` checking `workspace_id`) is tracked in #158; today's posture is identity-level. The canary scope is one workspace + one smart account, so a single-workspace canary is unaffected. Re-evaluate before broad multi-workspace mainnet. |
| 17 | Rollback plan exists and is operator-runnable | 🟢 | `Bank.Security.Pauses.create_pause/4` halts new dispatches in seconds; `Bank.Decisions.cancel_pre_execution_intent/1` clears the queue; revoke-delegation worker reverses signing authority; [`docs/incident-runbook.md`](../incident-runbook.md) walks the procedure. The canary cap means rollback liability is bounded at $10 / UserOp. |
| 18 | Single-active-delegation fallback is **not** used for broad mainnet usage | 🟢 (conditional) | The canary cap from #181 (`amount=10` per UserOp) means broad usage is structurally impossible while the cap holds. The fallback's risk surface is the per-UserOp loss bound. **#185** (account-aware routing) is required before the cap can be raised. |
| 19 | Support / incident path is documented | 🟢 | [`docs/incident-runbook.md`](../incident-runbook.md): pause / resume / revoke; `docs/runbooks/notifications.md`: operator inbox + delivery preferences. |
| 20 | Residual limitations are documented | 🟢 | This document, plus runbook-level "Limitations" sections in `auth-and-access.md`, `notifications.md`, `base-mainnet-rehearsal.md`, `base-mainnet-canary.md`. |

## No-go list

If the verdict above were NO-GO, blockers would be opened as issues per #182's acceptance criteria. At this commit there are **no blockers** for the capped canary scope. Tracking issues that gate **broad mainnet usage** (out of scope for this verdict) are already open and named explicitly so a future review can re-grade row 18:

1. [#185](https://github.com/Linh86/cryptobank/issues/185) — replace single-active-delegation fallback with account-aware routing. Required before raising or removing canary caps.
2. [#158](https://github.com/Linh86/cryptobank/issues/158) — cross-workspace query-layer isolation. Required before multi-workspace mainnet.
3. [#167 children](https://github.com/Linh86/cryptobank/issues/167) — multi-account smart-account routing. Required for any deployment with more than one mainnet smart account.

These are tracking links, not blockers for the canary verdict above.

## Sign-off

The verdict is binding only when all three signatures are present on this document (or in the issue thread referencing this commit). Each signer attests to one specific scope:

| Role | Attests | Signature (PR comment / issue comment / GPG) |
|---|---|---|
| Operator (on-call) | The no-broadcast rehearsal ([#180](https://github.com/Linh86/cryptobank/issues/180)) was executed against this commit on the target deployment; the artifacts (preflight log, dispatch-worker `:mainnet_disabled` log, pause-state log) are attached to issue #182. | _pending_ |
| Workspace admin | The workspace eligibility list at this commit has been reviewed; only the workspaces explicitly intended for canary have `mainnet_enabled: true`; no other workspace was inadvertently flipped. | _pending_ |
| Repo maintainer | The reviewed commit SHA matches the deployed code; `mix precommit` is green; `mix openapi.check` is clean; the canary caps in `Bank.Chains.CanaryCaps` are unchanged from the values referenced in row 5. | _pending_ |

A NO-GO signature on any row converts the document's verdict to NO-GO; the dissenting signer must add a tracking issue with the specific concern and link it from this document.

## Appendices

### A1. Env vars touched by mainnet

These are operator-provisioned and never present in repo / logs. See [`docs/operator-secrets-checklist.md`](../operator-secrets-checklist.md) for the canonical list.

| Var | Purpose | Rotation trigger |
|---|---|---|
| `ADAPTER_BASE_URL` | Phoenix → TypeScript adapter base URL. | On hostname / VPC change. |
| `ADAPTER_DISPATCH_SECRET` | Phoenix → adapter bearer (256-bit). | On staff change. |
| `ADAPTER_CALLBACK_SECRET` | Adapter → Phoenix bearer (256-bit). | On staff change. |
| `BASE_MAINNET_RPC_URL` | Read + write JSON-RPC URL for Base mainnet. | On provider change. |
| `BUNDLER_RPC_URL` | ERC-4337 bundler endpoint. | On provider change. |
| `DELEGATION_SIGNER_KEY` | Adapter-side EOA private key for the delegation signer (single-active-delegation today). | On staff change AND before raising canary caps (gated on #185). |
| `OPERATOR_PRIVATE_KEY` | Adapter-side operator EOA, used for delegation grant / revoke. | On staff change. |
| `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET` / `_REDIRECT_URI` | Identity layer. | On staff change. |
| `BANK_ADMIN_EMAILS` | Bootstrap-admin allowlist. | On staff change. |

### A2. Allowlist snapshot at reviewed commit

Counts only — no PII.

| Allowlist | Source | Cardinality |
|---|---|---|
| Chain ids (mainnet) | `lib/bank/chains.ex` `@mainnet_chains` | 2 (`base`, `ethereum`) — only `base` is used in dispatch |
| Chain ids (testnet) | `lib/bank/chains.ex` `@testnet_chains` | 3 (`base-sepolia`, `sepolia`, `goerli`) |
| Stablecoin assets | `lib/bank/stablecoins/registry.ex` `@tokens` | USDC + USDT on EVM chains; USDC on Solana — registry hardcoded |
| Counterparties | `Bank.Counterparties` (DB, workspace-scoped) | per-workspace, operator-managed |
| Morpho vaults | `policy_rules` rows of type `:allowed_vault` (per workspace) | per-workspace, operator-managed via policy builder; **fails closed when empty** (#202) |

### A3. Open issues with mainnet impact (frozen at review time)

These do **not** block the canary verdict above; they gate broader mainnet usage as explicitly noted in row 18 / no-go list.

- #185 — replace single-active-delegation fallback with account-aware routing (gates raising the canary cap).
- #158 — cross-workspace query-layer isolation (gates multi-workspace mainnet).
- #167 + children — multi-account smart-account routing (gates multi-smart-account mainnet).
- #197 + children — Morpho vault risk + ERC-4626 yield actions (Morpho mainnet is out of scope).
- #188 + children — full swap dispatch (swap mainnet is out of scope).
- #422 / #423 — provider-health + Morpho-severe notifications (operator-quality, not gate).

### A4. Linked artifacts

When this verdict is signed, attach the following artifacts to issue #182 as comments:

- Output of the no-broadcast rehearsal (#180) walk on the target deployment.
- `Bank.Chains.MainnetPreflight` log against `BASE_MAINNET_RPC_URL` (read-only RPC; no sensitive values).
- `mix precommit` log line + commit SHA.
- `mix openapi.check` log line.
- Workspace eligibility list (`mainnet_enabled: true` rows) — slugs only.

## Re-review trigger

This verdict is invalidated and a fresh review is required if any of the following change before the canary cap is raised:

- `Bank.Chains.CanaryCaps.default_caps/0` is edited.
- Any of the 5 dispatch-path call sites of `mainnet_allowed_for?/2` (row 2) is removed or weakened.
- The audit `UPDATE`/`DELETE` lock at `priv/repo/migrations/20260415170600_lock_audit_events.exs` is bypassed.
- Two-bearer adapter auth (`ADAPTER_DISPATCH_SECRET` / `ADAPTER_CALLBACK_SECRET`) is collapsed to a single secret.
- The hardcoded mainnet chain enum at `lib/bank/chains.ex` is moved to runtime config.

A re-review at that point grades the new posture against the same rows above and either reaffirms or downgrades the verdict.
