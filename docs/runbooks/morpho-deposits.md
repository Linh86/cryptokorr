# Morpho deposits — operator runbook

This runbook is the operator-facing reference for Morpho vault risk explanation and the read-only ERC-4626 yield-deposit decision pipeline (issues [#199](https://github.com/Linh86/cryptobank/issues/199), [#201](https://github.com/Linh86/cryptobank/issues/201), [#202](https://github.com/Linh86/cryptobank/issues/202), [#203](https://github.com/Linh86/cryptobank/issues/203), [#208](https://github.com/Linh86/cryptobank/issues/208), and [#209](https://github.com/Linh86/cryptobank/issues/209)). It tells a fresh reviewer what Morpho is in CryptoBank's model, what is and is not implemented today, and how to verify the surfaces locally without secrets, without `.env`, without any chain broadcast, and without calling Morpho's GraphQL API.

> **Audience.** Operators, alpha reviewers, and anyone wiring Morpho yield actions into the runtime. The Morpho surface today is **read-only risk + decision** — *not* execution dispatch (that lives in [#206](https://github.com/Linh86/cryptobank/issues/206) deposit / [#207](https://github.com/Linh86/cryptobank/issues/207) withdraw), *not* a yield aggregator, *not* a Morpho UI ([#204](https://github.com/Linh86/cryptobank/issues/204)).

The detailed risk model, dimension definitions, severity mappings, and operator UI copy live in the design doc [`docs/morpho-risk-explanation.md`](../morpho-risk-explanation.md). This runbook is the operational counterpart: it explains how to drive the surfaces locally and how to read the operator-visible output.

## What Morpho is in CryptoBank's model

Morpho is **not** one global trusted venue with one global risk score. CryptoBank models Morpho as **lending infrastructure plus a curation layer**:

- **Morpho markets** are isolated lending markets with their own loan asset, collateral asset, oracle, interest-rate model, LLTV, liquidity, and caps.
- **Morpho Vaults** are ERC-4626 vaults that accept one loan asset and allocate deposits across one or more Morpho markets.
- **Curators and allocators** manage market eligibility and allocation within vault constraints — Morpho itself is not the asset manager.

The runtime therefore displays a **CryptoBank-owned risk explanation** that takes Morpho's API + on-chain data as **input**, never as a final decision. The design doc covers the full vocabulary; this runbook documents the implementation surface.

## First supported workflow: USDC deposit into an allowlisted Morpho vault

The conservative MVP workflow is **Base Sepolia only**:

1. The agent submits a `kind: "allocate_idle_capital"` intent whose `target_raw_address` is the allowlisted Morpho vault address and whose `chain` is `"base-sepolia"`. `chain: "base"` (mainnet) is **rejected at the HTTP boundary** for this kind regardless of the workspace's mainnet opt-in (#203 P2). Mainnet support is post-MVP — see *Mainnet boundary (post-MVP)* at the bottom.
2. [`Bank.Intents.normalize/1`](../../lib/bank/intents.ex) maps the public `"allocate_idle_capital"` string to the internal atom `:defi_yield_deposit` and persists the `AgentIntent` row. The internal name is not part of the public vocabulary; the API response renders it back as `"allocate_idle_capital"`.
3. The decision pipeline ([`Bank.Decisions.evaluate_intent/2`](../../lib/bank/decisions.ex)) dispatches to [`Bank.Decisions.MorphoEvaluator`](../../lib/bank/decisions/morpho_evaluator.ex) on the internal `kind`.
4. The evaluator resolves the persisted vault snapshot via [`Bank.DefiVenues.Morpho.Snapshots.get_current/2`](../../lib/bank/defi_venues/morpho/snapshots.ex), compiles the workspace's active Morpho rules into a [`%Bank.DefiVenues.Morpho.PolicyInput{}`](../../lib/bank/defi_venues/morpho/policy_input.ex) via [`Bank.Policies.Morpho.RulesCompiler.compile/2`](../../lib/bank/policies/morpho/rules_compiler.ex), and runs [`Bank.DefiVenues.Morpho.RiskExplanation.explain/3`](../../lib/bank/defi_venues/morpho/risk_explanation.ex).
5. The resulting explanation map is embedded in the new `DecisionEnvelope`'s `reasons.items[0].details.morpho_risk_explanation`, the matched rule ids land in `policy_snapshot_ref`, and three Morpho-specific audit events fire alongside `decision.decided` (see *Audit & replay surface* below).

> **Withdraw / redeem is operator-only and never agent-initiated.** Agents may submit only `allocate_idle_capital` (deposit). Any withdraw, redeem, borrow, leverage, or looping path is operator-only safety work tracked in [#207](https://github.com/Linh86/cryptobank/issues/207) and is **never** reachable through the public agent HTTP surface.

> **`allocate_idle_capital` is a public intent kind on `POST /v1/intents`.** The OpenAPI `kind` enum accepts `transfer | swap | scheduled_transfer | allocate_idle_capital`. The internal atom is `:defi_yield_deposit`; the request → internal mapping happens in `Bank.Intents.normalize/1` and the response renders the internal atom back as the public string. Submitting `kind: "defi_yield_deposit"` (the internal name) is rejected as `{:invalid, :kind}`.

## Why MVP deposits always require operator approval

Even when every risk dimension passes cleanly, a Morpho deposit will route to **`:approval_required`** in the MVP. This is enforced by `Bank.DefiVenues.Morpho.RiskExplanation.explain/3` via the `mvp_morpho_deposit` `:approval` reason: the engine always emits it, so the aggregator never produces `:auto_exec` for a Morpho deposit. The four documented MVP outcomes are therefore:

| Risk explanation `decision` | Envelope `outcome` | Envelope `risk_tier` |
|---|---|---|
| (default — every reason ≤ approval) | `:approval_required` | `:low` or `:moderate` |
| any `:approval`-severity reason | `:approval_required` | `:moderate` |
| any `:hold`-severity reason | `:hold` | `:elevated` |
| any `:block`-severity reason | `:block` | `:severe` |

A future "auto-exec for tightly-bounded vaults" path is explicit follow-up work and is **not** part of #209's scope. Until that work lands, treat any `:auto_exec` outcome on a Morpho intent as a regression worth investigating.

## Risk dimensions

The risk explanation (see [`Bank.DefiVenues.Morpho.RiskExplanation`](../../lib/bank/defi_venues/morpho/risk_explanation.ex)) computes ten risk dimensions in fixed order. The full check list lives in the source; the operator-visible summary table is below. The detailed rule narrative for each is in [`docs/morpho-risk-explanation.md`](../morpho-risk-explanation.md).

| # | Dimension | Sample check codes |
|---|---|---|
| 1 | Protocol | `protocol_known`, `mvp_morpho_deposit` |
| 2 | Vault identity | `vault_listed`, `vault_allowlist`, `asset_match` |
| 3 | Curator / roles | `curator_allowlist` |
| 4 | Underlying markets | `max_market_lltv`, `collateral_allowlist` |
| 5 | Oracle | `oracle_allowlist` |
| 6 | Liquidity / withdrawal | (covered by `pending_caps` + future allocation freshness) |
| 7 | Concentration | `exposure_cap` |
| 8 | APY anomaly | `apy_anomaly` |
| 9 | Change velocity | `pending_caps`, `freshness_*` |
| 10 | Incident & external context | `incident` |

Each check returns a `status` (`pass` / `warn` / `fail` / `missing`) and zero or more `primary_reasons` carrying a fixed `severity` vocabulary: `info`, `warn`, `approval`, `hold`, `block`. Severities aggregate: any `block` ⇒ `block`; any `hold` ⇒ `hold`; any `approval` ⇒ `approval_required`; otherwise `approval_required` (the MVP floor).

## Outcome routing

The evaluator maps the explanation's `decision` string onto the `DecisionEnvelope` outcome enum:

- `"approval_required"` → `:approval_required`
- `"hold"` → `:hold`
- `"block"` → `:block`
- `"auto_exec"` → also `:approval_required` (belt-and-suspenders MVP cap; today unreachable because of the `mvp_morpho_deposit` rule, but the code defends against a future engine change)

When the outcome is `:block`, the intent moves to state `:blocked`. For the other three outcomes the intent moves to state `:decided`. The Morpho path **never** creates an `ExecutionPlan` and **never** enqueues `RunExecution` — execution dispatch is owned by [#206](https://github.com/Linh86/cryptobank/issues/206) (deposit) and [#207](https://github.com/Linh86/cryptobank/issues/207) (withdraw).

## Audit & replay surface

Three Morpho-specific audit events fire on every Morpho decision (#208), in this order:

| Event type | When | `subject_type` | `after_ref` keys |
|---|---|---|---|
| `morpho.risk_explained` | every Morpho decision (any outcome) | `agent_intent` | `morpho_risk_explanation`, `snapshot`, `policy_rule_ids`, `proposed_amount` |
| `morpho.snapshot_stale` | snapshot has any `:stale` or `:expired` field | `morpho_vault_snapshot` | `vault_address`, `chain_id`, `fetched_at`, `stale_fields` |
| `morpho.policy_blocked` | outcome is `:block` | `agent_intent` | `vault_address`, `chain_id`, `block_reason_codes`, `summary`, `policy_rule_ids` |

All three carry `correlation_id == intent.id` and stamp `intent.workspace_id`. Emission order inside one decision is deterministic:

```
morpho.risk_explained
  → morpho.snapshot_stale  (only if any field is stale/expired)
  → morpho.policy_blocked   (only if outcome is :block)
  → decision.decided
  → intent.state_changed    (only if state changed)
```

[`Bank.Audit.replay/1`](../../lib/bank/audit.ex) returns these on the bundle's `morpho_evidence` slice (filtered by `event_type` prefix `morpho.`). The slice projects each row to `{event_type, subject_type, subject_id, ts, after_ref}` so a replay reader can render the Morpho narrative without re-walking the full audit list.

> **Snapshot reference is a tight allowlist.** The `snapshot` map in `morpho.risk_explained.after_ref` is built from a private helper that exposes only the public identity fields (`id`, `chain_id`, `vault_address`, `payload_hash`, `fetched_at`, `source_name`, `source_schema_version`). It deliberately omits `source_warnings`, the upstream URL, and any provider secret. The hardcoded key list is the load-bearing redaction; a planted canary in `source.source_warnings` is verified against every audit row by the smoke task (`secret_hygiene` check).

Future Morpho events from execution work (`morpho.deposit_dispatched` / `morpho.deposit_confirmed` / `morpho.deposit_failed` / `morpho.withdraw_*`) will land in the same `morpho_evidence` slice automatically once #206/#207 emit them under the same prefix.

## Run the automated smoke

Run after `mix bank.demo.seed`:

```bash
mix bank.demo.seed
mix bank.morpho.smoke
```

The task ([`Mix.Tasks.Bank.Morpho.Smoke`](../../lib/mix/tasks/bank.morpho.smoke.ex)) wraps the runner ([`Bank.DefiVenues.Morpho.Smoke`](../../lib/bank/defi_venues/morpho/smoke.ex)) and exits 0 on PASS, 1 on FAIL.

The runner exercises nine checks in fixed order. Operators read top-to-bottom; the runbook lists them so the documentation cannot drift away from the runner.

| # | Check | What it proves |
|---|---|---|
| 1 | `vault_snapshot_persistence` | A fresh in-process `%VaultSnapshot{}` round-trips through `Snapshots.persist/2` and `Snapshots.get_current/2`; `freshness_summary/2` returns `:fresh` for every field. |
| 2 | `risk_explanation_safe_vault` | `RiskExplanation.explain/3` against the safe vault produces `decision: "approval_required"`, tier `low`/`moderate`, no block-severity reasons, and includes the `mvp_morpho_deposit` MVP-floor reason. |
| 3 | `risk_explanation_unknown_vault` | An empty `vault_allowlist` plus a non-allowlisted vault produces `decision: "block"`, tier `severe`, and a `vault_not_allowlisted` block reason (the #202 P2 fail-closed posture). |
| 4 | `risk_explanation_stale_snapshot` | A snapshot whose allocation TTL is expired produces `decision: "hold"` with a `freshness_*` `:hold` reason. |
| 5 | `decision_pipeline_approval` | End-to-end `Decisions.evaluate_intent/2` with the safe snapshot writes a `DecisionEnvelope` with `outcome: :approval_required`, embeds the explanation in `reasons.items[0].details.morpho_risk_explanation`, and creates no `ExecutionPlan`. |
| 6 | `decision_pipeline_block` | The unallowlisted vault path writes a `DecisionEnvelope` with `outcome: :block`, tier `:severe`, and creates no `ExecutionPlan`. |
| 7 | `decision_pipeline_hold_stale` | The stale-snapshot path writes a `DecisionEnvelope` with `outcome: :hold` and surfaces a `freshness_*` reason in the explanation. |
| 8 | `replay_carries_morpho_evidence` | `Bank.Audit.replay/1` for the freshly-written intent surfaces the `morpho.risk_explained` event in the bundle's `morpho_evidence` slice. |
| 9 | `secret_hygiene` | Every `morpho.*` audit row written by the smoke is scanned against the secret-marker family (Authorization headers, Bearer tokens, PEM private-key markers, `private_key`, tokenized Morpho URLs). |

Re-running the smoke is safe: snapshot persistence demotes the prior current row via the partial unique index; intent inserts use a fresh idempotency key per run; the decision pipeline supersedes any prior current envelope; policy rules are upserted via a `morpho_smoke` scope sentinel.

## Optional: testnet deposit smoke

A live Base Sepolia ERC-4626 deposit smoke is **not** part of this runbook. It depends on the execution adapter from [#206](https://github.com/Linh86/cryptobank/issues/206) and the workspace's mainnet eligibility plumbing from [#178](https://github.com/Linh86/cryptobank/issues/178). When it lands, it will live as a separate Mix task with explicit operator confirmation and recorded public artifacts (transaction hash, block number, receipt).

> **Mainnet boundary (post-MVP).** Base mainnet for `allocate_idle_capital` is **out of v0.1 scope**. The HTTP boundary fails closed: a public submission with `chain: "base"` is rejected with `morpho_chain_not_supported` regardless of the workspace's `mainnet_enabled` flag (#203 P2). When mainnet support arrives, it requires [#166](https://github.com/Linh86/cryptobank/issues/166) (mainnet operational policy), [#178](https://github.com/Linh86/cryptobank/issues/178) (workspace mainnet eligibility), and the post-MVP exposure / concentration engine that is explicitly tracked outside the MVP plan (#205 was closed post-MVP).

## Troubleshooting

### `morpho.risk_explained` did not land in the audit log

1. Confirm the intent's `kind` is exactly `:defi_yield_deposit`. Other kinds bypass the Morpho path entirely.
2. Confirm `Bank.Decisions.evaluate_intent/2` returned `{:ok, _}`. The audit emission is post-commit; a transaction failure means no event was written.
3. Check `Bank.Audit.AuditEvent` rows for the intent's `correlation_id` — the row will be there even if the operator UI hasn't refreshed.

### Decision routed to `:auto_exec` for a Morpho deposit

This is a regression. The MVP rule (`mvp_morpho_deposit` `:approval` reason) should make `:auto_exec` unreachable. File an issue and check that `Bank.DefiVenues.Morpho.RiskExplanation.explain/3` still emits the `mvp_morpho_deposit` reason on every call.

### `vault_not_allowlisted` block on a vault you expected to allow

The vault allowlist is **most-restrictive intersection** across rules ([#202 P2](https://github.com/Linh86/cryptobank/issues/202)). An empty or malformed `:allowed_vault` rule collapses the intersection to `[]`. Inspect the workspace's active Morpho rules:

```elixir
Bank.Policies.list_rules(%{rule_type: :allowed_vault}, workspace_id: ws.id)
```

### `morpho.snapshot_stale` keeps firing

The persisted snapshot's `fetched_at` is more than the per-field TTL old. Refresh the snapshot via the ingestion path (or, in a smoke / test, persist a fresh snapshot via `Bank.DefiVenues.Morpho.Snapshots.persist/2`).

### Smoke task fails at the `seed` check

The runner requires the demo workspace from `mix bank.demo.seed`. Run that first; the smoke does not create its own workspace.

## Limitations and provenance

What this surface does **not** do (today):

- No deposit / withdraw / borrow / leverage / looping execution. The decision is a `DecisionEnvelope`; the on-chain action lives in [#206](https://github.com/Linh86/cryptobank/issues/206) / [#207](https://github.com/Linh86/cryptobank/issues/207).
- No mainnet `allocate_idle_capital`. Base Sepolia only at the HTTP boundary; mainnet is post-MVP and gated on #166/#178.
- No agent-initiated withdraw / redeem. Operator-only, tracked in #207.
- No public launch docs, no external SIEM integration, no analytics dashboard.
- Morpho data is **input** to CryptoBank's policy, not the policy itself. APY is **never** treated as a safety signal.

Provenance:

- Snapshot ingestion: [#199](https://github.com/Linh86/cryptobank/issues/199) (`Bank.DefiVenues.Morpho.Snapshots`, `PersistedVaultSnapshot`, `VaultSnapshot`)
- Risk explanation: [#201](https://github.com/Linh86/cryptobank/issues/201) (`Bank.DefiVenues.Morpho.RiskExplanation`)
- Policy rules + compiler: [#202](https://github.com/Linh86/cryptobank/issues/202) (`Bank.Policies.Morpho.RulesCompiler`, the 16 Morpho `PolicyRule` types, fail-closed empty-allowlist posture)
- Decision pipeline integration: [#203](https://github.com/Linh86/cryptobank/issues/203) (`Bank.Decisions.MorphoEvaluator`, `evaluate_intent/2` dispatch on `kind: :defi_yield_deposit`)
- Audit & replay evidence: [#208](https://github.com/Linh86/cryptobank/issues/208) (`morpho.risk_explained`, `morpho.snapshot_stale`, `morpho.policy_blocked` event types; `morpho_evidence` replay slice)
- Docs + smoke (this runbook): [#209](https://github.com/Linh86/cryptobank/issues/209)
- Design doc: [`docs/morpho-risk-explanation.md`](../morpho-risk-explanation.md)
