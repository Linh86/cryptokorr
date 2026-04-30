# Workspace `workspace_id` Backfill — Operator Runbook

Operator-side guide for `mix bank.workspace_backfill`, the
cursor-batched task added in #158d-d (PR #274). Use it to fill the
legacy `NULL` tail of `workspace_id` on rows that pre-date workspace
scoping (#158a–c) before any later step that requires the column to
be populated (e.g. the `NOT NULL` flip in #158e).

Pairs with:

- [`lib/bank/workspaces/backfill.ex`](../../lib/bank/workspaces/backfill.ex) — module-level documentation of derivation chains and skip semantics.
- [`priv/repo/migrations/20260430140000_allow_audit_workspace_backfill.exs`](../../priv/repo/migrations/20260430140000_allow_audit_workspace_backfill.exs) — the narrow audit trigger relaxation that the backfill relies on.
- [`docs/incident-runbook.md`](../incident-runbook.md) — escalation if the task surfaces something unexpected.

## Tables in scope

| Table             | Source row                                                                |
|-------------------|---------------------------------------------------------------------------|
| `execution_plans` | `agent_intents.workspace_id` via `intent_id`                              |
| `delegations`     | latest `execution_plans.workspace_id` for the same `smart_account_id`     |
| `audit_events`    | the row at `(subject_type, subject_id)` (one extra hop through the intent for `trust_assessment`, `simulation_report`, `decision_envelope`; through `counterparty` for `address_label`) |

Anchor tables (`agent_intents`, `counterparties`, `policy_rules`)
are intentionally NOT in scope — they have no FK chain we can
derive from. Filling them needs a separate "pick a default
workspace per installation" pass and is not part of this task.

## Safety properties (review before running)

- **Dry-run by default.** No `--apply`, no writes.
- **Idempotent.** Only rows with `workspace_id IS NULL` are
  scanned. A second `--apply` run after success reports
  `scanned == 0`.
- **Cursor-batched.** Pages are `id ASC` with `LIMIT
  batch_size`; each batch is its own transaction. A crashed
  run resumes by re-invoking.
- **`audit_events` integrity preserved.** The append-only trigger
  still rejects every UPDATE that does not match the narrow
  bypass: workspace-only, prior NULL, every other authoritative
  column unchanged. The session-local flag the backfill arms is
  scoped to the work block.

## Procedure

### 0. Pre-flight

Confirm the migrations needed for the run are applied:

```sh
mix ecto.migrations | grep -E '20260415170600|20260430140000'
```

Both must be `up`. If `20260430140000` is `down`, an `audit_events`
backfill will fail with `read_only_sql_transaction`. Run `mix
ecto.migrate` first.

### 1. Dry-run

```sh
mix bank.workspace_backfill
```

Expected output (counts will vary):

```
Bank.Workspaces.Backfill (dry-run)
  tables     : delegations, execution_plans, audit_events
  batch_size : 1000
  limit      : no cap

execution_plans
  scanned : 12
  updated : 8
  skipped : 4
  skip_reasons:
    - intent_workspace_nil    4

delegations
  scanned : 7
  updated : 5
  skipped : 2
  skip_reasons:
    - no_plan_with_workspace  2

audit_events
  scanned : 153
  updated : 138
  skipped : 15
  by_subject_type:
    - agent_intent         scanned=80 updated=80 skipped=0
    - decision_envelope    scanned=21 updated=21 skipped=0
    - delegation           scanned=12 updated=12 skipped=0
    - execution_plan       scanned=18 updated=10 skipped=8
    - smart_account        scanned=10 updated=0 skipped=10
    - user                 scanned=12 updated=12 skipped=0
  skip_reasons:
    - subject_workspace_nil   8
    - workspace_blind_subject 7

Dry-run only. Re-run with --apply to commit.
```

Read the `skip_reasons` carefully:

- `intent_workspace_nil` / `subject_workspace_nil` — parent row
  exists but its own `workspace_id` is NULL. Re-running the
  backfill after the parent is filled will pick it up. If the
  parent is an anchor table that the backfill cannot fill, escalate.
- `subject_not_found` — a row referenced by `(subject_type,
  subject_id)` no longer exists. Expect this on
  `correlation_id`-linked tombstones from canceled flows; investigate
  if the count is unexpectedly high.
- `workspace_blind_subject` — `user`, `agent`, `smart_account`
  events. These permanently stay NULL until a future smart-account →
  workspace lookup lands.
- `unknown_subject_type` — a `subject_type` the backfill does not
  know about. Should be 0; non-zero is a bug or new event type that
  needs a derivation rule.
- `no_plan_with_workspace` — delegation row with no matching plan
  carrying a workspace. Common for legacy delegation rows from before
  any execution_plan referenced their smart account.

### 2. Apply

When the dry-run looks reasonable, commit:

```sh
mix bank.workspace_backfill --apply --batch-size 200
```

`--batch-size 200` keeps each transaction small enough that an
unexpected lock contention does not stall other writers. Increase
later if the run is slow against a table with heavy NULL counts;
keep below 1000 against `audit_events` until the row count is known.

### 3. Verify clean

Re-run the dry-run. Every table should report `scanned == 0`.

```sh
mix bank.workspace_backfill
```

If any table still has `scanned > 0`, inspect the `skip_reasons` —
the remaining rows are either intentionally skipped (workspace-blind
subjects, anchor-table parents) or signal a parent row that still
needs filling.

## Recovery

- **Run interrupted partway.** The task is resumable: re-invoke
  with the same arguments. Already-stamped rows are not rescanned
  (idempotent on `WHERE workspace_id IS NULL`).
- **Got an `audit_events is append-only` error during apply.** The
  `20260430140000_allow_audit_workspace_backfill` migration is not
  applied. Run `mix ecto.migrate` and retry.
- **Counts look wrong.** Stop. Open an incident referencing this
  runbook. Don't `--apply` until the dry-run output matches what
  staging looked like.

## What this task does NOT do

- It does not flip any column to `NOT NULL`. That is `#158e` and
  must NOT run until this backfill has produced a clean dry-run on
  the target environment.
- It does not lift any unique index.
- It does not delete or modify any non-workspace_id field.
- It does not touch `agent_intents`, `counterparties`, or
  `policy_rules` — those are anchor tables.
- It does not switch `BankWeb.SecurityLive`'s post-query MapSet
  filter to a SQL `WHERE workspace_id =`. That follow-up can land
  only after this task has actually run on the target environment
  and the legacy NULL tail is verified empty.
