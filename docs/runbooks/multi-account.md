# Multi-account isolation — operator runbook

Issue [#187](https://github.com/Linh86/cryptobank/issues/187) (epic
[#167](https://github.com/Linh86/cryptobank/issues/167)).

> **Audience.** Operator or auditor verifying that one workspace
> cannot see, query, or mutate another workspace's account state,
> and confirming what "account routing" actually means in v0.1
> before the multi-account model lands.
>
> **Posture.** Every check in this runbook is **read-only**. There
> is no schema change, no flag flip, no broadcast. The runbook
> documents the v0.1 isolation contract and points at the test
> files that pin it; running through the steps does not mutate any
> production state.

## TL;DR — v0.1 reality

CryptoBank v0.1 is **workspace-scoped**, not multi-account. Every
durable resource a workspace owns lives in a row whose
`workspace_id` column matches that workspace's id; every list /
read / mutation surface that has been migrated takes an opt-in
`workspace_id:` filter; and the auto-execution router resolves a
smart account through a **single-active-delegation** invariant:
at most one non-terminal `delegations` row per
`smart_account_id`, regardless of workspace.

Concretely, the v0.1 account-routing model is:

- A workspace owns its intents, decisions, execution plans,
  delegations, and audit events through `workspace_id`.
- The runtime auto-dispatches an `:auto_exec` envelope only when
  exactly one delegation is currently executable
  (`Bank.Decisions.resolve_executable_account/0`); zero or
  multiple executable delegations hold the envelope as
  `intent.auto_exec_held` so the operator can pick a smart account
  manually.
- The smart account a plan dispatches through is whatever
  `smart_account_id` was written onto the plan when it was
  created. The dispatch worker re-loads the plan, re-checks the
  delegation by that exact `smart_account_id`, and refuses to
  proceed if no executable delegation is found.

The richer multi-account routing — e.g. a workspace holding
multiple smart accounts, intents declaring an explicit account
target, per-account caps and ledgers, account-level approval
queues — is **deferred** to issues
[#183](https://github.com/Linh86/cryptobank/issues/183),
[#184](https://github.com/Linh86/cryptobank/issues/184),
[#185](https://github.com/Linh86/cryptobank/issues/185), and
[#186](https://github.com/Linh86/cryptobank/issues/186). This
runbook honestly states what is true today and is the audit pin
that catches a regression that would let a future multi-account
refactor leak across workspaces.

## What this runbook is not

- **Not a migration plan.** The eventual multi-account model
  lands as #183-#186; until then there is no per-account table
  to migrate to. Issue #187 is an audit + docs + test pass
  against the v0.1 reality.
- **Not a recovery procedure.** If isolation is breached at
  runtime, follow [`docs/incident-runbook.md`](../incident-runbook.md)
  § Workspace-scope leak (treat as data-classification incident).
  This runbook only documents the posture and pins the
  regressions that catch a leak in CI.
- **Not an API surface change.** OpenAPI impact is none — the
  auth and workspace-scoping behaviour visible to API callers is
  unchanged by #187.

## Posture per acceptance (#187)

The runbook mirrors the structure of
[`docs/runbooks/base-mainnet-rehearsal.md`](base-mainnet-rehearsal.md):
each acceptance criterion below is pinned by an automated test in
`test/bank/cross_account_isolation_test.exs` (#187), and a
docs-pin describe block in
`test/docs/runbooks/multi_account_test.exs` keeps this runbook
itself in lockstep with the contract.

| Acceptance criterion | Surface | Pinned by |
| --- | --- | --- |
| No workspace can see another workspace's intents | `Bank.Intents.list/1` with `:workspace_id` filter | `cross_account_isolation_test.exs` "intents are workspace-scoped" |
| No workspace can see another workspace's decision envelopes | `Bank.Decisions.list_recent_decisions/2`, `list_pending_approvals/1`, `list_held_decisions/1`, `list_blocked_decisions/2` | `cross_account_isolation_test.exs` "decision envelopes are workspace-scoped" |
| No workspace can see another workspace's execution plans | `Bank.Decisions.list_active_executions/1`, `count_active_executions/1` | `cross_account_isolation_test.exs` "execution plans are workspace-scoped" |
| No workspace can see another workspace's delegations | `Bank.Delegations.list_active/1` | `cross_account_isolation_test.exs` "delegations are workspace-scoped" |
| No workspace can see another workspace's audit events | `Bank.Audit.list_events/2` with `:workspace_id` filter | `cross_account_isolation_test.exs` "audit events are workspace-scoped" |
| No intent can execute through a different smart account than its plan's `smart_account_id` | `Bank.Runtime.Workers.RunExecution.perform/1` | `cross_account_isolation_test.exs` "cross-workspace dispatch refusal" |
| Granting a delegation while a non-terminal one exists for the same `smart_account_id` does NOT create a parallel row | `Bank.Delegations.grant/3` | `cross_account_isolation_test.exs` "single-active-delegation pin" |

## The five workspace-scoped surfaces

CryptoBank v0.1 carries `workspace_id` on five durable surfaces.
Every isolation guarantee in this runbook reduces to one of them:

1. **Intents** (`agent_intents.workspace_id`) — set at
   `Bank.Intents.submit/2` when the controller passes
   `:workspace_id` from the authenticated workspace. Listed and
   counted via `Bank.Intents.list/1` and
   `Bank.Intents.counts_by_state/1`. Single-row reads use
   `Bank.Intents.get_in_workspace/2`, which returns `nil` for an
   intent that exists in a different workspace (controllers lift
   to `404` so the existence of an out-of-scope intent is not
   probeable by status code).
2. **Decision envelopes** (`decision_envelopes` joins through
   `agent_intents.workspace_id`) — listed via
   `Bank.Decisions.list_recent_decisions/2`,
   `list_pending_approvals/1`, `count_pending_approvals/1`,
   `list_held_decisions/1`, `list_blocked_decisions/2`. The join
   filter is enforced at the query layer; an envelope whose
   parent intent has `workspace_id IS NULL` is excluded under any
   non-`nil` filter.
3. **Execution plans** (`execution_plans.workspace_id`) — read
   hint set at `create_execution_plan` using the parent intent's
   `workspace_id`. Listed via
   `Bank.Decisions.list_active_executions/1` and counted via
   `Bank.Decisions.count_active_executions/1`. The dispatch
   worker (`Bank.Runtime.Workers.RunExecution`) consults this
   column when checking the chain-pause and mainnet gates so a
   plan whose workspace flips off mid-flight is aborted before
   any adapter call.
4. **Delegations** (`delegations.workspace_id`) — read hint set
   at `Bank.Delegations.grant/3` when callers supply
   `:workspace_id`. Listed via `Bank.Delegations.list_active/1`.
   The single-active rule is enforced by the partial unique
   index `delegations_smart_account_active_idx` on
   `smart_account_id` for non-terminal states — at most one
   non-terminal row per smart account exists, regardless of
   `workspace_id`.
5. **Audit events** (`audit_events.workspace_id`) — set at
   `Bank.Audit.append_event/1` from the emitting context. The
   column is a passthrough field; it is not part of the
   canonical audit hash, so two events with the same content can
   carry different `workspace_id` values without changing the
   chain integrity invariant. Listed via
   `Bank.Audit.list_events/2` filtered by `workspace_id`.

## Failure modes

Each row in the table below pairs a credible "what could go
wrong" with the surface that catches it and the operator's next
move. The table is exhaustive over the v0.1 isolation contract;
new failure modes land here as the multi-account model rolls in.

| Failure | Symptom | Surface that catches it | Next operator action |
| --- | --- | --- | --- |
| An intent is submitted with `target.smart_account_id` belonging to another workspace | controller request with the foreign `smart_account_id` in the payload | The submit path uses `opts[:workspace_id]` from the authenticated session; intents are stamped with the **caller's** workspace, never the payload's. The plan's `smart_account_id` is set at `create_execution_plan` from the resolver, not from the intent body. A future bug that took the SA id from the body would still fail closed at dispatch (`Delegations.executable?(sa_id)` returns `false` if no executable row matches). | None — pinned. If the test starts failing, treat as a P1 regression and revert the offending change. Do NOT attempt to "fix" by widening the cross-workspace check: the right answer is for the controller to keep using the session's workspace |
| A delegation is revoked between plan creation and dispatch | `RunExecution` runs after the operator (or adapter callback) flipped the row to `:revoking` / `:revoke_failed` / `:revoked` | `RunExecution.verify_delegation/1` calls `Delegations.executable?(sa_id)`; non-`:active` rows return `false` and the worker aborts the plan with `final_reason: "delegation_not_active"`, returns `{:cancel, :delegation_not_active}`, and never calls `Bank.AdapterClient` | None — pinned by the `delegation_not_active` cancellation path; this is the canonical revoke-mid-flight gate. Audit chain shows `execution.aborted` with the documented reason |
| A future bug allows two non-terminal delegations to share a `smart_account_id` | two rows in `delegations` with the same `smart_account_id` and non-terminal state | Postgres rejects the second insert with the `delegations_smart_account_active_idx` partial unique constraint; `Bank.Delegations.grant/3` translates that into `{:error, :already_exists}` | The `cross_account_isolation_test.exs` "single-active-delegation pin" describe block fails first. If the test was bypassed, treat as a P0 multi-tenant leak: pause via `Bank.Security.pause(:global, "cross_workspace_delegation_leak", actor: :operator, actor_id: <id>)` and follow [`docs/incident-runbook.md`](../incident-runbook.md) § Emergency pause. Do not roll a "fix" forward without a fresh PR explicitly addressing the root cause |
| A list query forgets to apply `:workspace_id` filter | a controller for workspace A surfaces rows from workspace B in a paginated list | The per-context regression suite in `test/bank/workspace_query_scoping_test.exs` (#158b/#158b.2) covers each list surface; the cross-account suite layers on by re-pinning the same invariant for intents, decisions, plans, delegations, and audit events from a single file so a regression that bypassed all five contexts simultaneously would still fail | Add the missing filter at the call site. The framework default is `nil` (legacy "all workspaces"); the omission is a contract violation, not a Phoenix compatibility issue |
| `Bank.Audit.list_events/2` is called without a `:workspace_id` filter from a workspace-scoped controller | audit page in the operator console for workspace A shows events from workspace B | The audit context exposes `:workspace_id` as a regular filter map key; controllers must pass it. The cross-account isolation test pins the filter behaviour | Add the filter at the controller. The controller should not "hide" cross-workspace events by client-side filtering — the SQL must already exclude them |
| A future migration or backfill leaves a row with `workspace_id IS NULL` in a workspace-scoped table | rows visible in legacy "all workspaces" queries even though the table is supposed to be scoped | All `workspace_id` columns are nullable today (#158a); the NOT NULL flip is deferred until every caller has been migrated. Cross-account list filters explicitly exclude `workspace_id IS NULL` rows under a non-`nil` filter so a leak through a NULL row is not possible | If a NULL row appears unexpectedly, audit how it was inserted (search audit events for the inserting actor) and either backfill the column or delete the row. Track via a separate ticket; do not re-open #187 |
| Audit events for one workspace appear in another workspace's `audit_events` page | row visible cross-workspace in the operator UI | `Bank.Audit.list_events/2` with `workspace_id: <ws-a.id>` excludes rows whose `workspace_id` is anything else (including `nil`); the cross-account test pins this | Same as the list-query case above — fix the call site, not the audit context |

## Cross-links

- [`docs/runbooks/production-observability.md`](production-observability.md)
  — the operator console's per-workspace cards. The audit and
  pending-approval cards both consume the workspace-filtered
  context APIs documented here.
- [`docs/runbooks/base-mainnet-rehearsal.md`](base-mainnet-rehearsal.md)
  — the no-broadcast rehearsal that runs before the first Base
  mainnet broadcast. The mainnet flag (#178) is itself
  workspace-scoped, so the rehearsal's posture pinning depends
  on the same isolation contract this runbook documents.
- [`docs/runbooks/base-mainnet-canary.md`](base-mainnet-canary.md)
  — the capped first-broadcast runbook. Reads the workspace's
  `mainnet_enabled` flag through the same context surfaces.
- [`docs/incident-runbook.md`](../incident-runbook.md) —
  § Emergency pause (the right response if cross-workspace
  isolation is ever observed to leak in production).
- [`docs/bank-v0.1-runtime-flow-and-api.md`](../bank-v0.1-runtime-flow-and-api.md)
  — § "Post-decision routing" describes the
  single-active-delegation auto-dispatch fallback referenced in
  this runbook's TL;DR.
- `test/bank/cross_account_isolation_test.exs` — the
  cross-workspace regression suite this runbook documents.
- `test/bank/workspace_query_scoping_test.exs` (#158b/#158b.2) —
  per-context query-scoping regression suite. Layered: the
  cross-account suite re-pins the cross-workspace invariant from
  a single file; the per-context suite covers each surface in
  more detail. Both must stay green.
- `test/bank/mainnet_gate_test.exs` (#178) — sibling cross-
  workspace + cross-chain regression suite for the mainnet flag.

## Related issues

- [#167](https://github.com/Linh86/cryptobank/issues/167) — epic
  (multi-account routing).
- [#158](https://github.com/Linh86/cryptobank/issues/158) —
  workspace_id foundation across the five scoped tables.
- [#183](https://github.com/Linh86/cryptobank/issues/183),
  [#184](https://github.com/Linh86/cryptobank/issues/184),
  [#185](https://github.com/Linh86/cryptobank/issues/185),
  [#186](https://github.com/Linh86/cryptobank/issues/186) —
  the deferred multi-account model. This runbook is the audit
  pin that catches a regression those issues' refactor would
  introduce if isolation slipped.
- [#187](https://github.com/Linh86/cryptobank/issues/187) — this
  runbook.
