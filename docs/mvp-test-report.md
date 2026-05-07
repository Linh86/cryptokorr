# MVP Test Report

Date: 2026-05-07
Commit: `7f2ec79` (`Pin public intent kind vocabulary at /v1/intents (MVP test plan) (#509)`)
Branch: `main` (verified from isolated worktree at `/private/tmp/cryptobank-d-mvp-baseline-docs`)

## Summary Recommendation

**Ship the demo**, subject to the manual-only owner checks listed below.

The repository matches the documented private-alpha / showcase MVP scope for the agent control plane on Base Sepolia. Every automated baseline, SDK/MCP smoke, and docs-honesty gate passes on `main`. The browser-signed install path went end-to-end shipped this week (#500 backend + #501 frontend + #502 docs/preflight + #506 launch-status cleanup), and the shipped paths for the agent intent API, USDC transfer, MVP 0x exact-input swap, allowlisted Morpho USDC deposit, and operator-emergency revoke all hold up under their existing test suites. No `production-ready` / `audited` / `insured` / `mainnet-ready` / `custody-grade` / "full CCTP" / "full 1inch" / "full Jupiter" / `autonomous withdrawals` claims survive in `README.md` or `docs/`.

Two cosmetic items remain (a docs-vs-code worker-name drift was found and is pinned by an extended hygiene test in this PR; one operator checklist item — bundler RPC key rotation — is not yet documented in `docs/operator-secrets-checklist.md`). Neither blocks the demo.

The owner's required step is the live Base Sepolia walkthrough enumerated under "Manual-Only Checks For Owner" — there is no automated substitute for a real wallet pop-up.

## Checks Run

| Area | Command | Result | Notes |
| --- | --- | --- | --- |
| Phoenix precommit | `mix precommit` | **4070 / 4070 PASS** | Includes compile / `deps.unlock --unused` / format / test / `openapi.check`. No warnings-as-errors hit. |
| Phoenix format | `mix format --check-formatted` | clean | |
| OpenAPI check | `mix openapi.check` | clean | `priv/openapi/openapi.json` matches the code-first spec. |
| Chain adapter | `cd chain_adapter && npm ci && npm run typecheck && npm run typecheck:scripts && npm test` | **274 / 274 PASS** in 22 vitest files | Includes dispatch auth, transfer, swap, Morpho deposit/withdraw, callback signature, kernel verifier, health. |
| Frontend assets | `cd assets && npm ci && npm test` | **43 / 43 PASS** (vitest) | `install_envelope_client.test.js` (17) + `install_zerodev_client.test.js` (26). The browser ZeroDev SDK + bundler integration. |
| TypeScript SDK | `cd sdks/typescript && npm ci && npm run typecheck && npm test && npm run build` | **80 / 80 PASS** + clean build | Transport, retry posture, redaction, error mapping, operator namespace. |
| Python SDK | `cd sdks/python && python -m unittest discover` | **(no test suite present)** | Package ships under `sdks/python/`; `pyproject.toml` lists `pytest` as a dev-extra but `tests/` is empty. SDK code itself is exercised indirectly through MCP server tests + examples hygiene. Python smoke is owner-deferred unless we want to add a test scaffold. |
| MCP server (stdio) | `cd sdks/mcp && python -m unittest discover -s tests -t .` | **82 / 82 PASS** | stdlib-only; covers `initialize`, `tools/list`, `tools/call`, error mapping, role probing, console-script entry, request signing. |
| Examples hygiene | `python -m unittest examples/test/test_examples_hygiene.py` | **9 / 9 PASS** | Pins no real keys committed, Base Sepolia only, `approval_required` documented as success in every example README. |
| Vercel AI SDK example | `cd examples/vercel-ai-sdk && npm ci && npm test` | **8 / 8 PASS** | `tools.ts` builds against the public `/v1` surface using `cryptobank` Python SDK ToolDefinitions; pinned to wire `kind: "allocate_idle_capital"` (#477 / #497). |
| Docs honesty grep | `rg -nE "production-ready\|audited\|insured\|mainnet ready\|mainnet-ready\|custody-grade\|full CCTP\|full 1inch\|full Jupiter\|autonomous withdrawals\|supports all\|complete routing" README.md docs` | clean (5 hits, all legitimate uses of "audited" as a verb) | No overclaim. |
| GH open issues | `gh issue list --state open --limit 200` | **0 open** | The MVP work tree converged to a clean post-launch state. |
| GH open PRs | `gh pr list --state open --limit 100` | **0 open** | |

Total automated test surface: **~4566 tests** across Phoenix, the chain adapter, the assets bundle, the TypeScript SDK, the stdio MCP server, the examples hygiene, and the Vercel AI SDK example. **Zero failures.**

## Product Capabilities Verified

The capabilities below are pinned by tests on `origin/main` at `7f2ec79` and verified by this lane plus the Worker A and Worker B MVP-test-lane reports under `control-tower/worker-reports/`.

### Browser wallet + scoped delegation install (Phases 3 + 4)

Pinned by Worker A's #508 audit and the existing `Bank.SessionPermissions.BrowserInstall`, `Bank.Runtime.Workers.VerifyInstallOnchain`, `Bank.Runtime.Workers.PollInstallReceipt`, `Bank.Runtime.Workers.RevokeDelegation`, and `BankWeb.API.V1.WalletBindingsInstallController` test suites:

- The user's connected EOA wallet on Base Sepolia signs the install UserOperation directly via the ZeroDev SDK in the browser; **no operator/server key signs the normal install** (pinned by the hook-safety test refusing `setTimeout` / `SYNTHETIC_CONFIRMATION_MS` / typed-data signing in the production hook source).
- Phoenix marks the delegation `:active` only after `Bank.Runtime.Workers.VerifyInstallOnchain` reads the kernel's installed validator set via `eth_call` and confirms the permission validator is present. The verifier worker is the **sole writer** of the `:active` transition.
- Tab-close mid-poll is handled by `Bank.Runtime.Workers.PollInstallReceipt` (#500), enqueued in the same `Repo.transaction/1` as the row insert. Idempotent against the browser fast-path.
- Delegation states `:revoking`, `:revoked`, and `:expired` all close `Delegations.executable?/1` (Worker A's #508 pins all three; the partial unique index forbids two non-terminal rows per smart account).
- Failure-category allowlist `Bank.SessionPermissions.BrowserInstall.failure_categories/0` collapses any free-form upstream string to `:unknown`; raw RPC errors never reach `last_reason`.
- Cross-workspace `binding_id` returns `404 not_found` (no existence leak; pinned by both `/v1` and browser-session controller tests).
- Revoke posture (#475) branches on `delegations.root_validator_owner`: legacy `:operator` rows take the cryptographic `Kernel.uninstallValidation(...)` path through `OPERATOR_PRIVATE_KEY`; new `:user` rows take the v0.1 sentinel audit anchor.

### Agent intent API + USDC transfer (Phases 5 + 6)

Pinned by Worker B's #509 audit:

- `POST /v1/intents` and `GET /v1/intents/:id` under the `:api_authenticated, :api_operator` pipeline.
- Public `kind` vocabulary closed-set: `transfer`, `swap`, `scheduled_transfer`, `allocate_idle_capital`. Unknown kinds (e.g. `buy_token`) → 422 `invalid_body` with no `EvaluateIntent` enqueue.
- Idempotency: same body + same key → existing intent returned with `idempotent_replay: true`; same key + different body → 409 conflict.
- Target validation: missing target / both-set / label-without-counterparty / cross-workspace counterparty / cross-workspace label all rejected before the intent reaches evaluation.
- USDC transfer execution gates: trusted-counterparty auto-exec; blocked recipient via trust/policy; over-limit via policy; unsupported asset; adapter unavailable; adapter validation failure; pending → executed/failed transition; audit/replay carries decision + execution.

### MVP 0x exact-input swap (Phase 7)

Pinned by `swap_route_test.exs`, `swap_dispatch_safety_test.exs`, `swap_route_artifacts_test.exs`, `execution_plan_swap_test.exs`, and `chain_adapter/test/dispatch-swap.test.ts`:

- Quote path via `Bank.Quotes.preview/2` + `mix bank.quotes.smoke` (#177).
- Allowlist on `swap_type`: only `:exact_input` accepted; `:exact_output`, uppercase variants, integers, empty all rejected.
- `:allowed_assets` policy gate; `:swap_asset_not_supported` on out-of-allowlist tokens.
- Amount mismatch between `route.input_amount` and `intent.amount` → `:swap_amount_mismatch_with_intent`.
- Stale deadline → `:swap_deadline_expired`.
- Native value > 0 → `:swap_native_value_disallowed` (v0.1 ERC20→ERC20 only).
- Adapter 422 / unavailable handling pinned at the chain adapter and Phoenix callback layers.
- Audit/replay carries `swap_route_evidence`.
- Mainnet rejection closed at three layers (safety gate test + adapter test + `BASE_CHAIN_ID` env contract).
- `mix bank.swap.smoke` ships green (10 / 10).

### Stablecoin routing + provider claims (Phase 8)

| Provider | Status | Evidence |
| --- | --- | --- |
| 0x | Wired and tested for live execution on Base Sepolia | `lib/bank/stablecoins/providers/zero_x.ex`, `chain_adapter/src/chains/base/swap.ts`, `mix bank.swap.smoke`, `docs/runbooks/swap-dispatch.md` |
| 1inch | **Quote / planning only** | `lib/bank/stablecoins/providers/one_inch.ex` calls `/v6.1/quote` only; `docs/runbooks/swap-dispatch.md:285` reaffirms |
| CCTP | **Quote / planning only** | `lib/bank/stablecoins/providers/circle_cctp.ex` moduledoc: "Execution flow (not performed by this adapter)" |
| Jupiter | **Quote / planning only** (Solana out of scope) | `lib/bank/stablecoins/providers/jupiter.ex` moduledoc explicitly defers execution |
| Bridges (general) | **Quote / planning only via CCTP**; no other bridges | `docs/runbooks/swap-dispatch.md:285-291` + `docs/mvp-readiness.md:127-128` |

The honesty grep confirmed no `production-ready` / `full CCTP` / `full 1inch` / `full Jupiter` / `complete routing` / `autonomous withdrawals` overclaim.

### Allowlisted Morpho USDC deposit (Phase 9)

Pinned by `morpho_dispatch_safety_test.exs`, `execution_plan_morpho_test.exs`, the `Bank.SessionPermissions.Scope.default/0` `morpho_4626_deposit` capability, and `chain_adapter/test/dispatch-morpho.test.ts`:

- Single allowlisted Morpho USDC vault per workspace; `:morpho_vault_not_allowlisted` on unknown vault.
- Deposit calldata pinned in adapter; deposit-only (withdraw via session signer is **not** wired and is operator-emergency only).
- `mix bank.morpho.smoke` and `mix bank.morpho.deposit_smoke` ship green.

### Morpho withdraw boundary (Phase 10)

Withdraw is intentionally NOT a session-permitted capability for v0.1: `Bank.SessionPermissions.Scope.default/0` documents it under denied actions, and the chain adapter's session-permission install does not encode it on chain. Operator-emergency withdraw goes through the legacy operator-rooted cryptographic path; user-rooted browser-signed delegations cannot withdraw via session signer. Pinned by `Bank.SessionPermissions.ScopeTest`'s denied-actions assertions.

### Operator console + audit + replay (Phase 11)

Pinned by the LiveView test suite under `test/bank_web/live/`:

- `BankWeb.ControlLive` (`/`) — wallet binding + session-permission install card with full state machine: `idle → awaiting_signature → signing → submitted → verifying → active | failed`.
- `BankWeb.DashboardLive` (`/dashboard`) — runtime / delegation / approvals / executions stat cards, recent decisions, execution-readiness checklist.
- `BankWeb.QueueLive` (`/queue`) — pending approvals, active executions, held actions, blocked actions; approve/reject is wire-tested.
- `BankWeb.SecurityLive` (`/security`) — pause/resume + delegation revoke (sentinel for `:user`-rooted, cryptographic for `:operator`-rooted).
- `BankWeb.AuditLive` (`/audit`) + `BankWeb.IntentReplayLive` (`/audit/replay/:intent_id`) — append-only log + per-intent replay bundle (intent → trust → simulation → decision → execution → policy snapshot → swap/Morpho route evidence).
- Telegram operator alerts + signed-button approval (alerting only; no command dispatch beyond pause/resume).

### SDK / MCP surface (Phase 12)

- `cryptobank` (Python SDK, `sdks/python/`) — sync + async clients, full method surface (intents, decisions, audit, operator namespace), typed exception hierarchy keyed off the wire `error.code`. Bundle smoke: `pip install` from sdist + import surface check passed.
- `@cryptobank/sdk` (TypeScript SDK, `sdks/typescript/`) — Node 18+, native `fetch` + `globalThis.crypto`, no runtime deps. 80 / 80 vitest. ESM + types build under `dist/`. CHANGELOG packed.
- `cryptobank-mcp` (stdio MCP server, `sdks/mcp/`) — stdlib-only. 82 / 82 unittest. Console script `cryptobank-mcp` round-trips `initialize` JSON-RPC against a clean-venv install.
- Examples (`examples/`) — Claude Desktop config, LangGraph Python agent, Vercel AI SDK Node tools. All three pinned to Base Sepolia, env-var-supplied API keys, `approval_required` documented as success not failure, no real keys committed.
- Path-A / Path-B reviewer smoke runbook: `docs/runbooks/browser-signed-install-smoke.md`.
- Reviewer preflight: `mix bank.browser_install.smoke` (preflight only — refuses `--confirm` / `--broadcast` / `--send` / `--sign` / `--execute` with exit code 2; redacts API keys to `cb_<first8>***`).
- Publishing: `sdks/PUBLISHING.md` (build/dry-run commands, publish commands marked authorization-gated, license-discrepancy checklist, MCP community-directory submission). **No publish has been run.**

## Failed Checks

None.

## MVP Blockers

**None automatable; the demo is automation-green.**

## Non-Blocking Polish

P2 follow-ups carried over from prior worker reports + this lane's audit. None blocks the demo:

- **Bundler RPC key rotation is not documented in `docs/operator-secrets-checklist.md`** (Worker D audit, this run). The checklist covers initial acquisition of `BUNDLER_RPC_URL` (lines 150-157 EN, mirrored in `-cs.md`) but does not name a rotation cadence or operator responsibility for refreshing the public-tier API key. The bundler URL is a low-trust credential surfaced viewer-tier on the install envelope — acceptable for private alpha, but worth a one-paragraph rotation note.
- **Browser-signed cryptographic revoke** (Worker A's report; design note `docs/design/browser-signed-install.md` § 6) — v0.1 ships the sentinel audit anchor for `:user`-rooted rows; the user-signed cryptographic revoke flow is a v0.2 follow-up.
- **Per-policy on-chain ZeroDev policy encoding** (Worker A's report, Worker C's #501 closeout) — v0.1 ships `toSudoPolicy({})` to mirror the legacy adapter; encoding `Bank.SessionPermissions.Scope.default()` as a real policy array is a v0.2 follow-up.
- **Wallet-provider error-code corpus** (Worker C's report) — `classifySendError` and `classifyReceiptError` cover EIP-1193 4001 plus viem's typical message shapes; per-provider fixture corpora (Coinbase Wallet, Phantom-EVM) are a v0.2 hardening pass. MetaMask, Rabby, and Frame are smoke-tested.
- **`bundler_rpc_url` doubles as the read RPC** (Worker C's report) — Pimlico endpoints serve generic JSON-RPC alongside bundler-specific methods so this works today; if a bundler without generic-RPC support is ever swapped in, Phoenix would need to expose a separate `read_rpc_url` in the envelope.
- **Test-isolation flake exposed in #500** (Worker C's report) — a one-line `Bank.Security.PauseState.reset/0` setup landed in `wallet_bindings_install_controller_test.exs` to fix `runtime_paused` bleed from a sibling test. A more complete fix (eliminating any test that mutates global PauseState without an `on_exit` reset) is worth a pass when someone next rotates onto the install lane.
- **Python SDK has no `tests/` directory.** `sdks/python/pyproject.toml` lists `pytest>=7.0` as a dev-extra but the directory is empty. The SDK code is exercised indirectly through the MCP server's HTTP-client tests and the examples hygiene. Adding even a small mocked-transport test scaffold would close the parity gap with the TypeScript SDK's 80-test suite.

## Docs And Code Mismatches

**Fixed in this PR (#502 / Phase 13 lane):**

- **`Bank.Runtime.Workers.PollInstallUserOpReceipt` → `Bank.Runtime.Workers.PollInstallReceipt`.** The actual implementation module is `lib/bank/runtime/workers/poll_install_receipt.ex` (defmodule `Bank.Runtime.Workers.PollInstallReceipt`). The docs carried over the design-note name `PollInstallUserOpReceipt` from `docs/design/browser-signed-install.md` instead of the implementation name. Three locations updated: `docs/mvp-readiness.md:213`, `docs/runbooks/browser-signed-install-smoke.md:232`, `docs/runbooks/browser-signed-install-smoke.md:426`. Pinned by two new assertions in `test/docs/browser_signed_install_docs_hygiene_test.exs` (one per affected doc) so future edits cannot reintroduce the design-note name.

**No other docs/code drift surfaced by the honesty grep or by reading the runbooks against the current source.** Worker B's report explicitly lane-checked the swap and provider runbooks; Worker A's report explicitly lane-checked the browser install runbook; this lane added the missing module-name pin.

## Manual-Only Checks For Owner

These are the only items left where a human must drive a real wallet on Base Sepolia. There is no automated substitute for the wallet pop-up.

1. **Connect a real browser wallet on Base Sepolia (84532)** at `http://localhost:4000/`.
2. **Sign the EIP-191 binding challenge** in your wallet's `personal_sign` prompt; confirm the card flips to `#wallet-status-bound` with a `verified_at` timestamp.
3. **Click "Install session permission"** and approve the EIP-712 install signature in your wallet. Verify the wallet popup shows the kernel address + enable selector + permission id matching the operator-consent UI string before approving.
4. **Confirm the Smart Account Delegation card flips to "Active"** within ~10–30 s of the bundler receipt.
5. **Submit a real transfer intent** against the bound smart account (operator API key + curl form in `docs/mvp-smoke-runbook.md` §Transfer); confirm execution reaches `:executed` and the on-chain receipt is visible in `/audit/replay/<intent_id>`.
6. **Submit a real 0x swap intent** (USDC → USDC or USDC → USDT/ETH on Base Sepolia); confirm the queue / replay UI shows route, expected_output, minimum_output, slippage_bps, deadline, and the post-broadcast `actual_output_amount`.
7. **Submit a real Morpho deposit intent** against the workspace's allowlisted vault; confirm execution + replay carry the `morpho_evidence` slice.
8. **Revoke the delegation** from the `/security` page; confirm the row transitions `:active → :revoking → :revoked` and that any follow-up intent is held / blocked by the runtime decision pipeline (`delegation_not_active` / `revoked` / `expired` are all closed by `Delegations.executable?/1`).
9. **Confirm execution is blocked after revoke** by re-submitting an intent and observing the auto-dispatch refusal in the audit trail.
10. **Review the demo video / GIF** before showing it to a partner. The demo script lives at `docs/mvp-demo-script.md`; the wallet quickstart at `docs/wallet-quickstart.md`.

## Final Notes

- Product framing on `main` matches the test plan's allowed positioning: private-alpha / showcase MVP, policy-gated agent control plane, browser-signed scoped delegation, Base Sepolia execution path, operator-only preview, **not** audited, **not** insured, **not** custody-grade, **not** mainnet-ready, **not** a complete bridge / CCTP / 1inch / Jupiter platform, **not** a complete autonomous treasury product.
- Three runbooks describe the reviewer-grade smokes:
  - `docs/runbooks/browser-signed-install-smoke.md` (Path A real automated, Path B manual escape hatch)
  - `docs/runbooks/swap-dispatch.md` (operator dispatch + rollback)
  - `docs/runbooks/morpho-deposits.md` (allowlisted USDC deposit)
- `mix bank.browser_install.smoke` is the env / config preflight a reviewer can run before walking the manual steps. It refuses to sign or broadcast under any flag.
- No private keys, seed phrases, or signed transactions were used in any phase of this verification. No real funds were moved. No claim of manual-only-pass is made — those steps are owner work.
- Worker reports synthesized into this report:
  - `control-tower/worker-reports/worker-a.md` — Worker A's #506 (launch docs cleanup) + #508 (MVP test lane delegation gate pin) closeouts.
  - `control-tower/worker-reports/worker-b.md` — Worker B's MVP test lane (Phases 5–8) + #509 (intent-kind controller pins) closeout.
  - `control-tower/worker-reports/worker-c.md` — Worker C's #501 (frontend ZeroDev SDK + bundler) closeout. **No standalone Worker C MVP-test-lane report file** for Phases 9–11 is present; Phase 9–11 surfaces are covered by the existing test suites which pass under `mix precommit` (4070 / 4070).
- The shared worktree at `/Users/linhnguyen/dev/CryptoBank` carries five tracked dirty files plus several untracked `docs/` and `control-tower/` paths. None were modified by this lane — the verification ran from an isolated worktree at `/private/tmp/cryptobank-d-mvp-baseline-docs` per the test plan's safety rule.
