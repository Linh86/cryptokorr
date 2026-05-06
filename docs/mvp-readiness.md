# MVP readiness — closure audit (post epic #134)

Snapshot taken 2026-04-29 on `main` after PR #148 (`7f12c4a`).
Epic [#134](https://github.com/Linh86/cryptobank/issues/134) is the
"Intent Execution MVP" tracker; PRs #142 (#135), #145 (#136), #144
(#139), #146 (#137), #147 (#138), and #148 (#140) closed every
technical sub-issue. PR #141 (this file) is the docs-polish closer.

This file inventories what's live, what's intentionally limited
to v0.1, and what's deferred. Operator-facing, no marketing
language. Update as items land.

References to issue numbers (#NN) are kept for archival
traceability.

## Done — Intent Execution MVP (live, with proof)

### Cryptographic delegation lifecycle (pre-epic, kept here for context)

- Cryptographic grant + revoke wired end-to-end on Base Sepolia.
  Operator-supplied artifacts: install tx `0xbbb3a2e8…`, revoke tx
  `0xf81c969d…`, block `40820243`. Code:
  `chain_adapter/src/chains/base/grant.ts`,
  `chain_adapter/src/chains/base/revoke.ts`,
  `chain_adapter/src/chains/base/uninstall_validation.ts`,
  `lib/bank/runtime/workers/grant_delegation.ex` (PR #130 + #132).
- Kernel v3.1 smart-account provisioning runbook + scripts on Base
  Sepolia. SA `0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C`, deploy
  tx `0xe6ad5263…` (#84).
- ZeroDev permission pin + tripwire test:
  `chain_adapter/src/chains/base/permission_validator.ts`,
  `chain_adapter/test/permission-validator-pin.test.ts` (#83).
- ERC-4337 v0.7 transfer dispatch + callback lifecycle (Base + USDC):
  `chain_adapter/src/chains/base/transfer.ts`,
  `lib/bank/runtime/workers/run_execution.ex`,
  `lib/bank/runtime/workers/confirm_execution.ex`,
  `priv/adapter/contract.md` (#30, #32).
- Stablecoin route selector, fee engine, provider scoring, and 4
  provider adapters (0x, 1inch, Jupiter, Circle CCTP):
  `lib/bank/stablecoins/`, `lib/bank/stablecoins/providers/` (#61–#67).
- Operator console LiveViews: dashboard, security, queue,
  counterparties, policies, audit, intent replay
  (`lib/bank_web/live/`).
- Telegram operator bot: webhook, alerts, commands, signed
  callback tokens, security controls.

### Intent Execution MVP (epic #134)

- **#135 — `/v1/intents` create + show live.** `POST /v1/intents`
  persists an `%AgentIntent{}` in `:submitted` with deterministic
  payload-hash idempotency on `(agent_id, idempotency_key)`,
  audits `intent.submitted`, and enqueues `EvaluateIntent`. `GET
  /v1/intents/:id` returns the intent record with cached
  current-pointer ids for trust / simulation / decision /
  execution plan. Live since PR #142 (commit `cad5c46`).
- **#136 — `EvaluateIntent` / `ReevaluateIntent` real pipeline.**
  Replaces the prior `:engines_pending` stub with
  `Bank.Decisions.evaluate_intent/2`, a single deterministic
  facade that composes `Bank.TrustEngine.classify/2`,
  `Bank.Quotes.preview/2` (defaults to `Bank.Quotes.StubProvider`
  — no chain calls), `Bank.Policies.evaluate/2`, and
  `Bank.Autonomy.route/2`. Inside one `Ecto.Multi` it demotes the
  prior current `TrustAssessment` / `SimulationReport` /
  `DecisionEnvelope`, inserts the new ones with `supersedes_id`,
  and updates the intent's `current_*_id` pointers and `state`.
  `:approval_required` envelopes also enqueue `ExpireApproval` at
  `approval_expires_at` so the TTL clock actually runs. Live since
  PR #145 (commit `1e96963`).
- **#137 — auto-exec → `ExecutionPlan` + `RunExecution` enqueue.**
  `Bank.Decisions.dispatch_auto_exec/3` is the runtime-driven
  counterpart to `request_manual_execution/3`; it reuses every
  gate from the manual path (current envelope, no active plan, no
  active plan for the intent, stablecoin adapter ready, runtime
  not paused, delegation `:active`). When `evaluate_intent/2`
  produces `:auto_exec`, the runtime resolves a smart account via
  the documented v0.1 single-active-delegation fallback
  (`resolve_executable_account/0`) and dispatches; otherwise it
  emits an `intent.auto_exec_held` audit event with a machine-
  readable reason and leaves the envelope current as `:auto_exec`
  for manual `/execute`. Live since PR #146 (commit `97a33fd`).
- **#138 — `POST /v1/intents/:id/simulate` live.** Three reason
  semantics: `pre_submit_dry_run` (writes `current: false`, no
  pointer change), `refresh` (supersedes prior current and
  advances intent pointer in one Multi), `operator_inspection`
  (history-only). Reuses `Bank.Decisions.simulation_attrs_from_preview/3`
  so the SimulationReport row has the same shape as evaluation
  produces. Live since PR #147 (commit `7bcd85a`).
- **#139 — `POST /v1/intents/:id/cancel` live.** Allows
  cancellation in `:submitted` / `:evaluating` / `:decided`;
  re-cancelling an already-`:cancelled` intent is idempotent;
  in-flight (`:executing`) and other terminal states return 409.
  State transition + `intent.cancelled` audit row run inside one
  `Ecto.Multi`, then realtime fan-out via `Notifier.audit_stream/1`.
  Live since PR #144 (commit `610dc6e`).
- **#140 — operator approval path live.** `POST
  /v1/approvals/{id}/approve` writes the `:auto_exec` successor
  AND attempts dispatch via `dispatch_auto_exec/3`. Three
  outcomes: `dispatched` (plan + `RunExecution` enqueued; one
  delegation executable), `held` (successor recorded, dispatch
  withheld with a machine-readable `held_reason`), `no_dispatch`
  (reject path; never dispatches even with delegation present).
  TTL expiry via `Bank.Runtime.Workers.ExpireApproval` was already
  live; #136 wired the enqueue. Live since PR #148 (commit `7f12c4a`).

### OpenAPI

- `priv/openapi/openapi.json` is regenerated through every PR via
  `mix openapi.gen`; `mix openapi.check` is a precommit gate. The
  artifact reflects the live endpoints, including the new
  `IntentSubmitResponse` / `IntentShowResponse` /
  `IntentCancelResponse` / `IntentSimulationResponse` /
  `ApprovalActionResponse` shapes. No `/v1/intents/*` endpoint
  documents `501` any more. The spec test file
  `test/bank_web/open_api_core_endpoints_test.exs` pins the
  liveness of every action.

### Replay

- `Bank.Audit.replay/1` returns an intent's full bundle: the
  intent record, the policy snapshot, the trust assessment chain,
  the simulation chain, the decision envelope chain, the execution
  plan chain, the audit events, plus screening evidence and
  stablecoin route evidence captured during evaluation. Surfaced
  through `GET /v1/intents/:id/replay`. New audit event types
  (`simulation.requested`, `intent.auto_exec_held`,
  `execution.auto_dispatched`) are written by the new code paths
  and surface in replay automatically — no replay-side change was
  needed.

## Open — must close before mainnet (residual MVP-only choices)

These are intentional v0.1 simplifications, not bugs. Each has a
documented escape hatch.

- **Mainnet readiness is reviewed; broadcast is gated by canary caps.**
  Epic [#166](https://github.com/Linh86/cryptobank/issues/166) shipped
  the workspace `mainnet_enabled` flag (#178), the read-only preflight
  (#179), the no-broadcast rehearsal runbook (#180), the in-code
  capped canary (#181), and the formal go / no-go review (#182). The
  current verdict is **GO for the capped canary path** (Base / USDC /
  $10 per UserOp via `Bank.Chains.CanaryCaps`) and **NO-GO for broad
  mainnet usage** until #185 (account-aware routing) lands. See
  [`docs/runbooks/base-mainnet-go-no-go.md`](runbooks/base-mainnet-go-no-go.md)
  for the signed checklist + sign-off block, and
  [`docs/runbooks/base-mainnet-rehearsal.md`](runbooks/base-mainnet-rehearsal.md) /
  [`docs/runbooks/base-mainnet-canary.md`](runbooks/base-mainnet-canary.md)
  for the rehearsal and first-broadcast operator runbooks.
- **Single-active-delegation fallback.** `resolve_executable_account/0`
  dispatches when exactly one delegation is currently executable;
  zero / two-or-more / all-revoked deployments hold dispatch with
  a machine-readable reason. This is the v0.1 single-tenant deployment
  shape. Multi-tenant deployments will need an explicit
  `smart_account_id` field on the `AgentIntent` contract — not a
  v0.1 hardcode.
- **Agent API auth is a placeholder.** `lib/bank_web/open_api/security_schemes.ex`
  declares `operator_bearer` and `agent_api_key` as documentation
  placeholders; per-tenant key issuance is tracked separately
  (`docs/security.md`). Manual writes attribute to `:user` with
  no actor id.
- **Browser wallet identity binding (#169) + scoped session
  install request (#171) land.** The browser connects on Base
  Sepolia, signs an EIP-191 challenge via `personal_sign`
  (verified by `Bank.WalletBindings`), and once the EOA is bound
  the operator sees the canonical `Bank.SessionPermissions.Scope`
  summary (USDC transfer, 0x swap, allowlisted Morpho USDC
  deposit; withdraw / arbitrary calldata / unlimited approvals /
  leverage / mainnet explicitly denied) and clicks Install. The
  Phoenix-side context gates on a verified Sepolia binding,
  refuses while the runtime or workspace is paused, blocks
  duplicate installs, and dispatches through the existing
  `Bank.Runtime.Workers.GrantDelegation` worker. The install
  UserOp itself is still signed server-side by
  `OPERATOR_PRIVATE_KEY` (`chain_adapter/src/chains/base/grant.ts`)
  — browser-side delegation-payload signing remains blocked on
  the wagmi/viem (or WalletConnect) SDK choice and delegation
  type (ERC-7579 vs EntryPoint v0.7) tracked in
  `docs/wallet-connect.md`. (Was #43.)
- **Cloud staging blocked on credentials.** `docs/staging.md`:
  code-side ready, but provider, Postgres, bundler keys, paymaster
  keys, DNS, smoke run all manual. (Was #35 remainder.)
- **Deployment-receipt validator is deferred.**
  `lib/bank/delegations/provisioning.ex:148` always returns
  `{:error, ...}` with reason "deployment-receipt validator was
  wrong-model and has been deferred". Operators have no automated
  check that a deploy journal matches the kernel they intend to
  bind.

## Deferred — post-MVP (acceptable to ship without)

- **Swap dispatch is scaffolded.** `chain_adapter/src/dispatch/swap.ts`
  validates the request and immediately emits
  `execution.aborted{reason: "swap_not_implemented"}`. Routing
  layer (`route_selector.ex`) is built; the execution leg is not.
  Fail-closed today — not a footgun. Onboarding doc tells users
  "Transfers only — no swaps".
- **Operator UI gaps.** No intent submission page (operator
  manually `mix bank.demo.seed`s or curl-submits), no
  multi-account selector, audit pagination lacks date-range filter,
  approvals UI is functional but minimal. (Were #44, #46, #45,
  #47.) The `/queue` LiveView now renders `dispatched` and `held`
  flash hints from #140 but has no inline badge for the per-row
  dispatch state.
- **Telegram bot is alerting + signed-button approval; no command
  dispatch beyond pause/resume.**
- **Quote provider stub.** `lib/bank/quotes/stub_provider.ex` is a
  test/dev provider returning provider id `"stub"` — deterministic
  and side-effect free. It's what evaluation and simulate use in
  tests and local dev. Real providers exist under
  `lib/bank/stablecoins/providers/` for production routing
  decisions; the simulator-as-provider integration for live
  preview is a follow-up.
- **Paymaster / sponsored gas not wired.** `priv/adapter/contract.md`:
  "Paymaster support itself is not yet wired in v0.1; reserved for
  when sponsored flow ships." Smart account funds its own gas today.
- **Documentation drift.** A few stale tracker references remain
  in `priv/adapter/contract.md`, `chain_adapter/README.md`, and the
  `docs/zerodev-permissions-integration.md` history section. None
  block use; they will be reconciled during the post-epic doc pass.

## Demo happy path

Concrete five-minute walkthrough an operator can follow on local
or staging:

1. **Boot.** `mix bank.demo.seed && mix phx.server` (Phoenix on
   `:4000`) and `chain_adapter && npm run dev` (adapter on `:4100`).
2. **Grant a delegation.** `POST /v1/connect/smart_account` with
   the smart-account address, session signer, and `chain_id`;
   wait ~15s for the `delegation.state_changed{state: "granted"}`
   callback. `Bank.Delegations.executable?/1` flips to `true`.
3. **Submit an auto-exec intent.** `POST /v1/intents` with a
   trusted counterparty under threshold. Response is `202 Accepted`
   with `state: "submitted"` and `links.replay`. `EvaluateIntent`
   runs in milliseconds; the intent transitions to `:decided`,
   the runtime auto-dispatches via the single-active-delegation
   fallback, an `ExecutionPlan` is created, `RunExecution` is
   enqueued, and the adapter signs + broadcasts. Watch
   `/audit/replay/<intent_id>` for the full chain:
   `intent.submitted` → `trust.assessed` → `simulation.produced` →
   `decision.decided` → `execution.auto_dispatched` →
   `execution.broadcast` → `execution.confirmed` → intent `:executed`.
4. **Submit an approval-required intent.** Use a raw address
   under the approval ceiling. Decision is `:approval_required`
   with an `approval_expires_at`. `GET /v1/approvals` shows it in
   the queue. `POST /v1/approvals/{id}/approve` writes the
   `:auto_exec` successor and dispatches (or returns `held` with
   reason if the gate fails). Same execution lifecycle from there.
5. **Reject a different approval.** `POST /v1/approvals/{id}/reject`
   writes a `:block` successor; intent moves to `:blocked`. No
   plan, no enqueue.
6. **Cancel a pre-execution intent.** Submit one, then `POST
   /v1/intents/{id}/cancel` with a reason while still in
   `:submitted` / `:decided`. Intent moves to `:cancelled`,
   audited; re-cancelling is idempotent.
7. **Simulate.** `POST /v1/intents/{id}/simulate` with
   `reason: "pre_submit_dry_run"`, `"refresh"`, or
   `"operator_inspection"`. Refresh supersedes the prior current
   simulation and advances the intent pointer; the others are
   history-only.
8. **Revoke.** `POST /v1/security/revoke_delegation` triggers the
   cryptographic revoke flow on Base Sepolia (or sentinel-era
   fallback if `permission` block is absent).

The smoke runbook at `docs/mvp-smoke-runbook.md` carries the curl
recipes for every step.

## Known limitations / not production yet

- Base Sepolia only; mainnet not proven.
- Single-active-delegation fallback is the v0.1 dispatch resolver.
  Multi-tenant deployments need an explicit smart_account_id field
  on the intent contract.
- Agent API auth is documented but not enforced.
- Browser-native wallet connect UX is a stub — operator-driven
  flow only.
- Single-operator alpha; no SSO, no rate limits on `/v1/`, no
  per-tenant isolation.
- No HSM/KMS for `OPERATOR_PRIVATE_KEY` (env var with startup
  validation).
- No on-chain anchoring of audit `payload_hash` yet.
- Telegram bot is a convenience surface (alerts + approve/reject) —
  not an independent control plane.
