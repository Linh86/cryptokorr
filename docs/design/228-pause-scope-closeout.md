# Pause-scope generalization (#228) — closeout

**Status:** closeout map. Phase 1 chain-pause shipped end-to-end on `main`.
**Issue:** #228 — *Generalize kill-switch pause scopes*.
**Parent epic:** #212.
**Companion design:** PR [#310](https://github.com/Linh86/cryptokorr/pull/310)
on branch `codex/228-pause-scope-design-memo` informed the
implementation and remains the design reference for any future Phase 2
/ Phase 3 work. The companion memo is not currently checked in as a
local Markdown file on this branch.

## Purpose

Map the #228 issue body — *Goal*, *Scope*, *Acceptance criteria*,
*Tests* — to the shipped behavior on `main`, so the issue can close
without losing the citations a future reader needs to verify it.

This is **not** a how-to or a runtime narrative; that lives in the
design memo and in the runbook.

## Acceptance criteria → shipped evidence

Every bullet from the #228 issue body is mapped below. Each row cites
the merged PR(s), merge SHA, and the gate or audit-event location an
auditor can reach with a `git show <SHA> -- <file>`.

| #228 acceptance bullet | Shipped behavior | Evidence |
|---|---|---|
| Global pause blocks all execution dispatch | `Bank.Security.PauseState` `:global` flag refuses both decision-time admission and worker-time dispatch | `lib/bank/security/pause_state.ex`; gates: `Bank.Decisions.validate_not_paused/2` (decision-time) and `Bank.Runtime.Workers.RunExecution.verify_not_paused/1` (worker-time) — both accept the new chain layer additively. Preexisting before #228; behavior preserved verbatim by [PR #326](https://github.com/Linh86/cryptokorr/pull/326) (SHA `9083bc3`). |
| Workspace pause blocks workspace actions | Workspace-wide agent-keys pause refuses every `/v1` request from the workspace's API keys with `401 invalid_credentials` | `Bank.APIKeys.pause_workspace/3` (`lib/bank/api_keys.ex:185-220`); gate at `Bank.APIKeys.verify_key/1`. Audited via `agent_keys.paused` / `agent_keys.resumed` (`lib/bank/audit/events.ex`). Preexisting (#231-a). |
| Chain pause blocks chain actions | DB-backed `:chain` scope refuses dispatch whose plan targets the paused chain | New `pauses` table + `Bank.Security.Pauses` context + dispatch gates: [PR #326](https://github.com/Linh86/cryptokorr/pull/326) (SHA `9083bc3`). HTTP / OpenAPI surface (`POST /v1/security/pause_chain`, `POST /v1/security/resume_chain`, Phase 1 accepts `"base"` only with `422 unsupported_chain` for others): [PR #332](https://github.com/Linh86/cryptokorr/pull/332) (SHA `35a1574`). |
| Agent key pause blocks agent-originated requests | Workspace-wide agent-keys pause (above) blocks every API-key-authenticated request from the workspace, which is the channel agents use | `Bank.APIKeys.pause_workspace/3`; reject in `verify_key/1`. Per-key granularity (Phase 3) is explicitly future scope and is **not** required by the literal acceptance bullet (which says "agent-originated requests", which the workspace-level mechanism blocks). |
| Smart-account pause blocks account dispatch **if account model exists** | The conditional applies: there is no dedicated smart-account entity in the codebase (no `lib/bank/smart_accounts/`, no `smart_accounts` table). `smart_account_id` is a string field on `Delegations` and `ExecutionPlan`, not a top-level entity model. | The acceptance bullet's "if account model exists" escape clause covers the current absence of the entity. Phase 2 of the design memo (#310 §5) introduces `:smart_account` to the `pauses` enum if and when a smart-account entity model lands; that work would be tracked under a fresh issue, not a continued #228 blocker. |
| Pause status is audited | New audit-event types and existing audit-event types together cover all five scopes; every event carries `actor`, `actor_id`, `subject_type`, `subject_id`, `correlation_id`, `workspace_id`, and an allowlisted `after_ref` (no secrets) | New `security.scope_paused` / `security.scope_resumed` (with `subject_type ∈ {"chain", "smart_account", "api_key"}` discriminator and `subject_id` carrying the scope value) — [PR #326](https://github.com/Linh86/cryptokorr/pull/326) (SHA `9083bc3`). Preexisting `security.paused` / `security.resumed` (global, counterparty), `agent_keys.paused` / `agent_keys.resumed` (workspace agent-keys), `delegation.revoke_*` (delegation revoke). |

## Tests → shipped evidence

| #228 test bullet | Shipped tests |
|---|---|
| Each pause scope blocks expected paths | Global / counterparty: `test/bank/runtime/workers/run_execution_test.exs`, `test/bank/decisions_test.exs`. Workspace agent-keys: `test/bank/api_keys_test.exs`. Chain: `test/bank/security/pauses_test.exs`, `test/bank/runtime/workers/run_execution_test.exs`, `test/bank/decisions_test.exs` (all extended in [PR #326](https://github.com/Linh86/cryptokorr/pull/326)). |
| Unrelated workspace unaffected | Chain: cross-workspace isolation tests in `test/bank/security/pauses_test.exs`, `test/bank/runtime/workers/run_execution_test.exs`. Workspace agent-keys: existing `test/bank/api_keys_test.exs` cross-workspace cases. |
| Expired/resolved pause no longer blocks | Resume tests in `test/bank/security/pauses_test.exs` (#326). Expiry sweeper tests in `test/bank/runtime/workers/sweep_expired_pauses_test.exs` ([PR #336](https://github.com/Linh86/cryptokorr/pull/336), SHA `6744871`). |
| `mix precommit` | Green on every #228 implementation PR. Latest `main` runs at 2306 tests, 0 failures. |

## Phase 1 shipped state, in one screen

- **DB-backed `pauses` table** — workspace-scoped, with `null: false`
  `workspace_id` and `on_delete: :restrict`; partial unique index
  `pauses_active_uniq` on `(workspace_id, scope_type, scope_value)
  WHERE resumed_at IS NULL`. Phase 1 enum value is `:chain` only.
  Source: [PR #326](https://github.com/Linh86/cryptokorr/pull/326)
  (SHA `9083bc3`).
- **Bank.Security.Pauses context** — `create_pause/1`, `resume/2`,
  `paused?/3`, `list_active/1`. Idempotent insert via lock-then-check;
  duplicate-active inserts collapse to `{:ok, :already_paused, row}`
  with no second audit. Same PR.
- **Dispatch gates** — chain check layered after the existing global
  check at `Bank.Decisions.validate_not_paused/2` and
  `Bank.Runtime.Workers.RunExecution.verify_not_paused/1`. Same PR.
- **HTTP / OpenAPI** — `POST /v1/security/pause_chain` and
  `POST /v1/security/resume_chain`; Phase 1 accepts `"base"` only;
  other values yield `422 unsupported_chain` with a stable error
  code naming the supported set.
  Source: [PR #332](https://github.com/Linh86/cryptokorr/pull/332)
  (SHA `35a1574`).
- **Read-only `#chain-pauses-card`** — operator-visible list of the
  current workspace's active pauses on `/security`.
  Source: [PR #334](https://github.com/Linh86/cryptokorr/pull/334)
  (SHA `69d8770`).
- **`expires_at` + auto-resume sweeper** — nullable column with a
  partial index for cheap sweeper reads; `Bank.Runtime.Workers.SweepExpiredPauses`
  flips active rows whose `expires_at <= now()` to resumed.
  Source: [PR #336](https://github.com/Linh86/cryptokorr/pull/336)
  (SHA `6744871`).
- **Mutating Base controls on `/security`** — admin-only
  `#chain-pause-base-control` panel inside `#chain-pauses-card`;
  `data-confirm` on both pause and resume buttons; LiveView event
  handlers re-check `:admin` via
  `BankWeb.LiveAuth.authorize_action/2`; chain pinned to `"base"`
  server-side from `current_scope`, not from client input.
  Source: [PR #337](https://github.com/Linh86/cryptokorr/pull/337)
  (SHA `d67dd951`).
- **Safety-timeline integration** — `security.scope_paused` /
  `security.scope_resumed` added to `@safety_event_types`;
  workspace-id-gated `visible_to_workspace?/3` clauses inserted
  **before** the existing `"security." <> _` catch-all so
  workspace-scoped scope events do not leak across workspaces.
  Source: [PR #326](https://github.com/Linh86/cryptokorr/pull/326).

## Safety invariants preserved

These are the load-bearing invariants from the design memo that the
shipped Phase 1 implementation must continue to honor; future Phase 2 /
Phase 3 work must keep them intact.

- **Workspace boundary is on the column, not at the application
  layer.** `pauses.workspace_id` is `null: false` with FK
  `on_delete: :restrict`. Postgres treats NULL as distinct in unique
  indexes, so the partial unique index would not actually enforce
  single-active without the NOT NULL discipline.
- **No fake workspace filtering.** Every `Bank.Security.Pauses` query
  pushes `:workspace_id` into the DB layer; no in-memory post-filter.
- **No `String.to_atom/1` on user input.** `scope_type` parsing uses
  the schema's `Ecto.Enum` cast; reasons are free-text strings capped
  at 256 chars; chain values are matched against a fixed allowlist
  (`"base"` for Phase 1) and unsupported values yield `422
  unsupported_chain` rather than an atom-table leak.
- **SecurityLive `visible_to_workspace?/3` ordering.** Workspace-id-
  gated clauses for `security.scope_paused` / `security.scope_resumed`
  must precede the existing `"security." <> _ → true` catch-all. Pinned
  by a regression test (`SecurityLiveTest`) that asserts a sibling
  workspace's `security.scope_paused` row does NOT appear in another
  workspace's safety timeline.
- **Audit `after_ref` allowlist / no secrets.** Builders include only
  pause metadata: `paused_at`, `reason`, `created_by_user_id`,
  `expires_at`. No `args`, `errors`, `meta`, `tags`, raw exception
  text, RPC URLs, or signing material. Pinned by audit-hygiene tests
  in `test/bank/audit/events_test.exs`.

## Out of scope for #228 (NOT closeout blockers)

These are explicitly future work and should be tracked under their
own issues if pursued, **not** under continued #228 ownership:

- **Non-Base chain pause/resume.** Phase 1 backend, API surface, and UI
  controls all pin `"base"`. Adding more chains (e.g., Optimism,
  Arbitrum) is a new slice; it requires the dispatch path to actually
  consider the additional chain values and the operator UI to widen
  beyond Base. No present demand on `main`.
- **Per-smart-account pause** (design memo Phase 2). Requires a
  smart-account entity model first; the `smart_account_id` string
  field is not a model. Open this as a fresh issue if/when a
  smart-account entity is introduced.
- **Per-API-key pause** (design memo Phase 3). The current
  workspace-wide agent-keys pause covers the literal #228 acceptance
  bullet; per-key granularity is a refinement. Open as a fresh issue
  if pursued; carries the bootstrap caveat from the agent-keys
  precedent.
- **ETS projection for hot-path reads** (design memo §6 Phase 1.5+).
  Phase 1 ships DB-only for correctness. If a latency budget later
  motivates a cache, the projection MUST be active-rows-only — the
  cache may answer "paused" fast, but a miss MUST fall through to the
  DB and the cache must never assert "not paused". The fail-closed
  contract is preserved only under that invariant.

## Sources of truth

- Design memo (PR #310, branch `codex/228-pause-scope-design-memo`):
  the architectural rationale, including the workspace_id NOT NULL
  argument, the no-`expires_at`-without-sweeper rule, and the
  active-rows-only future-cache invariant. Open as of this closeout;
  remains valuable as design reference for Phase 2 / Phase 3 if those
  issues are opened.
- Runbook (`docs/incident-runbook.md`): operator-facing playbook;
  notes scoped pauses are tracked under #228 (added in PR #321).
- Surface map (`docs/design/229-incident-center-ui-progress.md`):
  citations of every shipped UI surface for #229 with stable element
  ids; merged at `48c2590`.
