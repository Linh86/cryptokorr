# MVP readiness — closure audit (post PR #132)

Snapshot taken 2026-04-28 on `main` after PR #132 (`dfc56b6`).
GitHub reports 0 open issues / 0 open PRs, so this file inventories
the open work that still lives inside the codebase. Operator-facing,
no marketing language. Update as items land.

References to issue numbers (#NN) are kept for archival traceability
even though the tracker is now empty.

## Done (live, with proof)

- Cryptographic grant + revoke wired end-to-end on Base Sepolia.
  Operator-supplied artifacts: install tx `0xbbb3a2e8…`, revoke tx
  `0xf81c969d…`, block `40820243`. Code: `chain_adapter/src/chains/base/grant.ts`,
  `chain_adapter/src/chains/base/revoke.ts`,
  `chain_adapter/src/chains/base/uninstall_validation.ts`,
  `lib/bank/runtime/workers/grant_delegation.ex` (PR #130 + #132).
- Kernel v3.1 smart-account provisioning runbook + scripts on Base
  Sepolia. SA `0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C`, deploy tx
  `0xe6ad5263…`. `chain_adapter/scripts/provision-kernel.ts`,
  `chain_adapter/scripts/verify-installed-validator.ts` (#84).
- ZeroDev permission pin + tripwire test:
  `chain_adapter/src/chains/base/permission_validator.ts`,
  `chain_adapter/test/permission-validator-pin.test.ts` (#83).
- ERC-4337 v0.7 transfer dispatch + callback lifecycle (Base + USDC):
  `chain_adapter/src/chains/base/transfer.ts`,
  `lib/bank/runtime/workers/run_execution.ex`,
  `lib/bank/runtime/workers/confirm_execution.ex`,
  `priv/adapter/contract.md` (#30, #32).
- Sentinel revoke path retained as fallback when no `permission`
  block is supplied: `chain_adapter/src/chains/base/revoke.ts`.
- Stablecoin route selector, fee engine, provider scoring, and 4
  provider adapters (0x, 1inch, Jupiter, Circle CCTP):
  `lib/bank/stablecoins/`, `lib/bank/stablecoins/providers/` (#61–#67).
- Operator console LiveViews: dashboard, security, queue,
  counterparties, policies, audit, intent replay
  (`lib/bank_web/live/`).
- Telegram operator bot: webhook, alerts, commands, signed
  callback tokens, security controls (`lib/bank/telegram/`,
  `lib/bank_web/controllers/internal/telegram_webhook_controller.ex`).
- OpenAPI spec, adapter↔Phoenix bearer auth, audit replay endpoint
  (`/v1/intents/:id/replay`), staging Dockerfile + compose.

## Open — must close before demo (MVP blockers)

These let autonomous execution misbehave with real funds, or break
operator visibility / safe revoke. They block any usable demo to a
real user.

- **Intent engines are not wired.** `Bank.Runtime.Workers.EvaluateIntent`
  (`lib/bank/runtime/workers/evaluate_intent.ex:49`) and
  `Bank.Runtime.Workers.ReevaluateIntent`
  (`lib/bank/runtime/workers/reevaluate_intent.ex:47`) cancel every
  job with `:engines_pending`. The `Bank.TrustEngine`,
  `Bank.Autonomy`, and `Bank.Policies.Evaluation` modules exist as
  libraries but no worker calls them. Until this is wired, the
  runtime cannot route an intent to `auto_exec` / `hold` /
  `approval_required`. (Was #7–#9.)
- **Agent intent submission API returns 501.** Four of five
  `/v1/intents` endpoints are stubbed:
  `lib/bank_web/controllers/api/v1/intent_controller.ex:62, 80, 101, 122`.
  Only `GET /v1/intents/:id/replay` is live. Without `POST /v1/intents`
  no agent can submit work; the only way to seed an intent is via
  Elixir code or smoke task.
- **Agent API auth is a placeholder.** `lib/bank_web/open_api/security_schemes.ex:30, 64`
  declare `operator_bearer` and `agent_api_key` as documentation
  placeholders, and `lib/bank_web/controllers/api/v1/counterparty_controller.ex:421`
  attributes every manual write to `:user` with no actor id —
  "Auth wiring is deferred to the operator-auth issue". `docs/security.md:154`
  says "API-key authentication is expected; the pipeline is scaffolded
  but key issuance is tracked separately."
- **Mainnet not proven.** Only Base Sepolia revoke + grant has
  confirmed on chain. `docs/base-sepolia-execution-day.md:188` and
  `docs/zerodev-permissions-integration.md` say "Do NOT promote to
  Base mainnet until Sepolia is green end-to-end AND the
  cryptographic revoke has shipped against Sepolia. Mainnet re-rolls
  burn real ETH." Mainnet re-run + verify pass is required before any
  user holds funds.

## Open — must close before alpha (alpha blockers)

These don't break the core runtime but block self-onboarding or
first paying customer.

- **Browser wallet connect is a stub.** `assets/js/hooks/wallet_connect.js:61`
  pushes `wallet_connect:stub`; `lib/bank_web/live/control_live.ex:129`
  shows the toast "Signing flow is scaffolded — see docs/wallet-connect.md".
  Server-side connect endpoint + grant flow are real (PR #130), but
  the JS hook needs wagmi/viem or WalletConnect picked, installed,
  and wired to actually sign a delegation payload. Until this lands,
  partners must hand the team their smart-account id out of band.
  (Was #43.)
- **Cloud staging blocked on credentials.** `docs/staging.md:97` and
  `docs/staging.md:142`: code-side ready, but provider, Postgres,
  bundler keys, paymaster keys, DNS, smoke run all manual. (Was #35
  remainder.)
- **Deployment-receipt validator is deferred.** `lib/bank/delegations/provisioning.ex:148`
  always returns `{:error, ...}` with reason "deployment-receipt
  validator was wrong-model and has been deferred". Operators have
  no automated check that a deploy journal matches the kernel they
  intend to bind.
- **Failed-revoke incident response not documented.** `docs/base-sepolia-execution-day.md:197`
  defers incident response for failed cryptographic revokes (was
  #38). `lib/bank/delegations.ex` already exposes the
  `:revoke_failed` state and operator retry; the missing piece is
  the runbook.

## Deferred — post-MVP (acceptable to ship without)

- **Swap dispatch is scaffolded.** `chain_adapter/src/dispatch/swap.ts:60`
  validates the request and immediately emits `execution.aborted`
  with `swap_not_implemented`. Routing layer (`route_selector.ex`) is
  built but the execution leg is not. Fail-closed today; not a
  footgun. Onboarding doc already tells users "Transfers only — no
  swaps".
- **Operator UI gaps.** `docs/onboarding.md:188-197` lists known
  alpha limitations: control-tower has no intent submission page
  (was #44), no multi-account support (was #46), audit pagination
  lacks date-range filter (was #45 — `lib/bank_web/live/audit_live.ex:16`),
  approvals UI is minimal (was #47).
- **Telegram bot is alerting + signed-button approval; no command
  dispatch beyond pause/resume.** `lib/bank_web/router.ex:127`:
  "command / approval dispatch lands in later sub-issues of epic #54."
  The currently-live surface is sufficient for an operator on call.
- **Quote provider stub.** `lib/bank/quotes/stub_provider.ex` is a
  test/dev provider returning provider id `"stub"`. Real providers
  exist under `lib/bank/stablecoins/providers/`; the stub is for
  local dev and decision-flow tests.
- **Paymaster / sponsored gas not wired.** `priv/adapter/contract.md:262`:
  "Paymaster support itself is not yet wired in v0.1; reserved for
  when sponsored flow ships." Smart account funds its own gas today.
- **Documentation drift.** Several in-repo docs still describe #58
  and #31 as open: `priv/adapter/contract.md:26`,
  `priv/adapter/contract.md:155`, `chain_adapter/README.md:340`,
  `chain_adapter/src/chains/base/revoke.ts:4`,
  `docs/incident-runbook.md:347`, `docs/zerodev-permissions-integration.md:272`,
  `docs/wallet-connect.md:150`. Should be reconciled to "closed by
  PR #132 + Base Sepolia run on 2026-04-28" but does not block use.
