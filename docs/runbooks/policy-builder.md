# Policy builder — configure, simulate, publish, and verify a safe policy

This runbook is the operator-facing reference for the workspace
**policy builder** (issues #223–#227). It walks a fresh reviewer
through the smallest safe policy a workspace can run with, the
simulator that previews changes before they go live, and the
evidence that proves the runtime decision pinned the published
version.

> **Audience.** Admins (write) and operator+ reviewers (read) of a
> workspace. Reviewers are new to the runtime and want to confirm a
> proposed policy is safe before publishing.

## Prerequisites

- A workspace where you have the `:admin` role. The builder is
  read-only for `:operator` and `:viewer`; mutating events
  (`open_draft`, `save_rule`, `remove_rule`, `publish_draft`,
  `run_simulation`) require `:admin` and surface an explicit flash
  if invoked otherwise.
- The dev server reachable and the user logged in. The builder
  lives at [`/policies/builder`](../../lib/bank_web/router.ex).
  No `.env`, no chain dispatch, and no broadcast is involved at
  any step in this walkthrough.

## What the policy builder is

The builder composes three modules:

1. **[`Bank.Policies`](../../lib/bank/policies.ex)** — the rule
   catalog. Rules are versioned by supersession; `revise_rule/3`
   inserts a new row and marks the prior `:superseded`, so a past
   decision's pinned rule id always resolves to the same row.
2. **[`Bank.Policies.Versions`](../../lib/bank/policies/versions.ex)** —
   the workspace-scoped draft / publish / rollback bundle layer.
   At most one `:published` `PolicyVersion` per workspace at a
   time, enforced by a partial unique index. `publish_draft/2`
   atomically supersedes the prior published row, promotes any
   `:draft` rules in the bundle to `:active`, and emits the
   `policy.version.published` audit event.
3. **[`Bank.Policies.Simulator`](../../lib/bank/policies/simulator.ex)** —
   a pure side-by-side comparison that runs a hypothetical
   intent against the workspace's current draft and current
   published bundle. It never writes anything: no `AgentIntent`,
   no `ExecutionPlan`, no `DecisionEnvelope`, no audit, no Oban
   job, no PubSub. Tests assert the no-side-effects contract end
   to end.

## Draft simulation vs live runtime — the contract

The two sides of the builder answer two different questions:

| Surface | What it answers | What it touches |
| --- | --- | --- |
| **Simulator** (`Run simulation` button) | "If I publish this draft, how would it decide *this hypothetical* intent?" | Reads `:active` + `:draft` rules referenced by the workspace's `:draft` `PolicyVersion`. Reads `:active` rules referenced by the current `:published` `PolicyVersion`. **No writes.** |
| **Runtime** (`Bank.Decisions.evaluate_intent/2`) | "What does the policy say about a *real* intent right now?" | Reads only `:active` rules referenced by the current `:published` `PolicyVersion` for the workspace (`Versions.snapshot_for_workspace/1`). Pins `policy_version_id` + `policy_version_number` into the `DecisionEnvelope.policy_snapshot_ref` so replay is deterministic. |

The contract a fresh reviewer should remember:

- **A draft never affects the runtime.** Editing the draft does
  not change which rules `Bank.Decisions.evaluate_intent/2` will
  consider for the next intent. The draft only changes the
  simulator's left-hand side.
- **Rules added to a draft are created with `state: :draft`.** They
  flip to `:active` only when the draft is published — and only
  for rules referenced by the published version's `rule_ids` list.
- **The simulator's "Draft" outcome is a preview, not a promise.**
  The full runtime decision (`Bank.Autonomy.route/2`) also
  considers trust, simulation/preview freshness, screening, and
  the runtime pause state. The simulator scopes itself to the
  policy evaluator alone — it is the smallest reproducible signal
  for "did my rule change do what I expected?".

## Walk-through — the safe-policy reviewer path

The example policy in this section blocks transfers above $100,
restricts execution to the `base` chain, and forces manual approval
for all autonomous transfers. It is the smallest non-trivial policy
that still exercises every interesting outcome (`auto_exec` →
`approval_required` → `block`).

### 1. Open the builder

Navigate to **Policies → Builder** in the operator console. The
page renders three sections (cited DOM ids match
[`policy_builder_live.ex`](../../lib/bank_web/live/policy_builder_live.ex)
and are stable for tests):

- `#policy-builder-published` — the currently published version
  banner, or "No policy version has been published in this
  workspace yet" if greenfield.
- `#policy-builder-draft` — the current draft (or an "Open new
  draft" call to action if none).
- `#policy-builder-simulator` — the side-by-side intent simulator.

### 2. Open a new draft

Click **Open new draft** (`#policy-builder-open-draft-btn`). The
draft starts as a clone of the current published version's
`rule_ids` list, or empty if no version has been published yet.
The published banner remains unchanged — drafts are isolated.

### 3. Add an amount-limit rule

In the draft section's **Add rule to draft** form
(`#policy-builder-rule-form`):

1. Choose **Rule type** → `amount_limit`.
2. Set **Max amount per intent** → `100`.
3. Click **Add rule** (`#policy-builder-save-rule-btn`).

The rule is created with `state: :draft` and added to the
draft's `rule_ids` list. The published version is unaffected.

### 4. Add a chain allowlist

In the same form:

1. Choose **Rule type** → `allowed_chain`.
2. Set **Chains (comma-separated)** → `base`.
3. Set **Mode** → `Allowlist`.
4. Click **Add rule**.

This rule fires for any intent whose `chain` is not in the
allowlist; the simulator surfaces the resulting violation in the
`Draft` column.

### 5. Require manual approval for autonomous transfers

In the same form:

1. Choose **Rule type** → `autonomy_tier`.
2. Set **Autonomy tier** → `Manual approval`.
3. Click **Add rule**.

`autonomy_tier: :manual` does not create a violation; it sets
`autonomy_tier == :manual` on the evaluation result, which the
simulator and the runtime both interpret as "outcome is
`approval_required`".

### 6. Simulate before publish

Scroll to **Simulator** (`#policy-builder-simulator`). Fill in:

- **Intent kind** → `transfer`
- **Asset** → `USDC`
- **Chain** → `base`
- **Amount** → `50`

Click **Run simulation** (`#policy-builder-simulator-run-btn`).

Expected result for a fresh workspace with no prior published
version:

- `#policy-builder-simulator-published-outcome` → `auto_exec`
  (no rules → policy passes).
- `#policy-builder-simulator-draft-outcome` →
  `approval_required` (the `autonomy_tier: :manual` rule
  matches; no policy violations).
- `#policy-builder-simulator-changed-banner` is visible — the
  draft would change the outcome.

Re-run with **Amount** → `150`:

- `published` → `auto_exec` (still no published rules).
- `draft` → `block` (the `amount_limit` rule violates).
- The `Matched rules` list under the draft side links each
  matched rule id to its draft entry above
  (`#policy-builder-draft-rule-<uuid>`).

### 7. Publish the draft

Confirm the simulator preview matches your intent. Click
**Publish draft** (`#policy-builder-publish-btn`). On success:

- The draft flips to `:published` atomically.
- Any prior published version is marked `:superseded`.
- Every `:draft` rule referenced by the published version's
  `rule_ids` list is promoted to `:active` in the same
  transaction.
- A `policy.version.published` audit event is appended.

The published banner now shows `v<n>`, the publishing actor, and
the resolved rule list. The draft section returns to "No draft
open".

### 8. Submit a real intent and verify the decision

Submit a `USDC` `base` transfer for `50` via the API or the
sandbox console. The decision envelope persisted by
[`Bank.Decisions.evaluate_intent/2`](../../lib/bank/decisions.ex)
will carry:

```json
{
  "rule_ids": ["<amount-limit>", "<chain-allowlist>", "<autonomy-tier>"],
  "policy_version_id": "<published-version-uuid>",
  "policy_version_number": 1
}
```

…inside `decision_envelopes.policy_snapshot_ref`. The pin is
the runtime's evidence that the decision was evaluated against
exactly the version the reviewer published — replay reads (e.g.
the decision-report runbook) resolve back to those rule rows
even after a future publish or rollback.

### 9. Roll back if needed (context-only in v0.1)

`Bank.Policies.Versions.rollback_to_version/2` is implemented and
audited (`policy.version.rolled_back`), but **the policy builder
UI does not yet surface a rollback affordance**. To roll back in
v0.1, an operator with DB access opens an `iex` session and
calls:

```elixir
target = Bank.Policies.Versions.get_in_workspace(version_id, workspace_id)
{:ok, _restored} =
  Bank.Policies.Versions.rollback_to_version(
    target,
    actor: :user,
    actor_id: operator_user_id
  )
```

The transaction supersedes the current published row and
re-publishes the target with a fresh `effective_at`. Old
decisions remain pinned to their original `policy_version_id`;
new decisions read the restored version. A UI affordance is
tracked as a follow-up and intentionally out of scope for #227.

## Automated proof — what the tests assert

This runbook is automated by
[`test/bank/policies/policy_builder_smoke_test.exs`](../../test/bank/policies/policy_builder_smoke_test.exs).
Each step above pins to one assertion in that test:

- **Step 2 (open draft).** Asserts `Versions.create_draft/2`
  produces a `:draft` row and the published banner is
  unchanged.
- **Steps 3–5 (add rules).** Asserts each rule is created with
  `state: :draft` and is referenced by the draft's `rule_ids`
  list.
- **Step 6 (simulate before publish).** Asserts the simulator
  reports `draft.outcome == :block` for an above-limit intent
  while `published.outcome == :auto_exec`, and `changed?` is
  `true`.
- **Step 6, runtime read.** Asserts
  `Bank.Policies.Versions.snapshot_for_workspace/1` returns
  `nil` *before* publish — proving the runtime never sees draft
  rules.
- **Step 7 (publish).** Asserts the draft flips to
  `:published`, prior draft rules become `:active`, and a
  `policy.version.published` audit event is emitted.
- **Step 8 (decision pin).** Asserts a `Bank.Decisions.evaluate_intent/2`
  call against a real `AgentIntent` produces a
  `DecisionEnvelope.policy_snapshot_ref` carrying `rule_ids`,
  `policy_version_id`, and `policy_version_number`. Reloading
  the decision row confirms the pin is durable, and the
  outcome reflects the published policy.

Additional snapshot-pinning regression coverage already lives in
[`test/bank/policies/versions_test.exs`](../../test/bank/policies/versions_test.exs)
("decision in a workspace with a published version stamps the
version metadata" and "old decision's pinned version survives a
new publish (replay determinism)").

## Running the focused suite

```sh
mix test test/bank/policies/policy_builder_smoke_test.exs
mix test test/bank/policies/versions_test.exs
mix test test/bank/policies/simulator_test.exs
```

`mix precommit` runs the same files plus formatting and the
OpenAPI check.

## What this runbook deliberately does **not** cover

- DeFi / Morpho rule families. Those rule types
  (`:allowed_defi_venue`, `:max_market_lltv`, etc.) are
  evaluated by [`Bank.Policies.Morpho.RulesCompiler`](../../lib/bank/policies/morpho/rules_compiler.ex)
  and have separate runbook coverage under #202.
- Approval threshold as a distinct rule type. v0.1 expresses
  "require approval" via `autonomy_tier: :manual`. A dedicated
  per-amount approval threshold is a tracked follow-up.
- API/OpenAPI surfaces. The policy builder is LiveView-only
  in v0.1; there are no HTTP endpoints to document here. (The
  legacy `/policies` controller predates the version surface
  and is not the recommended authoring path.)
