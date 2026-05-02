# Incident Center UI progress map (#229)

**Status:** coordination doc, not acceptance closeout.
**Parent epic:** #212 (Incident / Kill Switch / Recovery Center).
**Issue:** #229 — *Build Incident Center UI and emergency controls*.

## Purpose

A single map of the Incident Center UI work that has shipped, what is
likely next, and what is gated on other issues. Future UI workers can
read this in one pass to avoid duplicating finished slices and to pick
up the next reasonable piece without re-scanning the entire merged-PR
history.

This doc is **not** a #229 closeout — closing #229 belongs to whoever
maps every acceptance criterion in the issue body to landed evidence.
This is a working map of progress as of the most recent `main`.

## Recently landed since this map opened

- [PR #324](https://github.com/Linh86/cryptobank/pull/324) — SecurityLive
  in-flight execution plans card (`#in-flight-plans-card`). Originally
  listed under *Remaining likely slices*; moved into *Shipped surfaces*
  below. Read-only: it does NOT add abort/pause controls, does NOT
  surface failed/retrying jobs, does NOT add provider/adapter health,
  does NOT add chain-pause UI controls, and does NOT close #229 by
  itself.
- [PR #327](https://github.com/Linh86/cryptobank/pull/327) — SecurityLive
  emergency action confirmations (`data-confirm` audit). Originally
  listed under *Remaining likely slices*; moved into *Shipped surfaces*
  below. Closes the *"All emergency actions confirm before applying"*
  acceptance bullet for the `/security` surface only — does not by
  itself close #229.
- [PR #329](https://github.com/Linh86/cryptobank/pull/329) — SecurityLive
  pending approvals card (`#pending-approvals-card`). Originally listed
  under *Remaining likely slices*; moved into *Shipped surfaces* below.
  Read-only inline panel; the dedicated `/queue#pending-approvals-section`
  remains the operator workhorse for triage.
- [PR #330](https://github.com/Linh86/cryptobank/pull/330) — SecurityLive
  incident summary snapshot (`#incident-summary-card` +
  `#incident-summary-copy-block`). The original *"Richer incident summary
  / export"* slice has been narrowed: this PR ships read-only operational
  counts and a copy-block; reasons, payloads, token material, tx refs,
  and signing material are intentionally excluded. Any further
  enrichment is reframed as optional below.
- [PR #326](https://github.com/Linh86/cryptobank/pull/326) — DB-backed
  per-chain pause gate (#228 Phase 1, backend). Backend-only: new
  `pauses` table, `Bank.Security.Pauses` context, dispatch gates at
  `Decisions.validate_not_paused/2` and
  `RunExecution.verify_not_paused/1`, audit builders
  `security.scope_paused`/`_resumed`, and the `visible_to_workspace?/3`
  clauses + `@safety_event_types` entries that wire the new events into
  the `/security` safety timeline. **Not** a chain-pause UI card; the
  operator-facing per-chain pause card remains a follow-up slice.

## Shipped surfaces

Each entry cites the merged PR(s) that landed the surface. Surfaces are
organized by the LiveView they live on.

### `BankWeb.SecurityLive` (`/security`)

- **Agent-keys pause card** — operator-visible card showing workspace
  agent-key pause state with pause/resume controls. Landed in
  [#294](https://github.com/Linh86/cryptobank/pull/294)
  ("SecurityLive agent-keys pause card (#231-c, parent epic #212)").
- **Active delegation risk summary + agent-key safety events** —
  delegation risk panel and inclusion of agent-key audit events on the
  safety timeline. Landed in
  [#297](https://github.com/Linh86/cryptobank/pull/297)
  ("Active delegation risk summary + agent-key safety events (#231-e)").
- **Safety timeline filters** — event-type / actor / range filters on
  the security safety timeline. Initial filter UI in
  [#300](https://github.com/Linh86/cryptobank/pull/300); the actor /
  range filters were pushed into the DB query for correctness and
  scalability in [#301](https://github.com/Linh86/cryptobank/pull/301).
- **Stuck-plans card + `ops.stuck_plan_detected` on the safety
  timeline** — surfaces detector output operator-side. Landed in
  [#305](https://github.com/Linh86/cryptobank/pull/305) and
  workspace-scoped via
  [#308](https://github.com/Linh86/cryptobank/pull/308) ("SecurityLive:
  workspace-scoped stuck-plan query + Layouts.app current_scope").
- **In-flight execution plans card** — operator-visible card listing
  the current workspace's non-terminal execution plans (the superset
  of which the stuck-plans card is a subset). Stable element id
  `#in-flight-plans-card`, rendered between `#stuck-plans-card` and
  `#delegations-card`. Reads from `Bank.Decisions.list_active_executions/1`
  with `:workspace_id` pushed into the DB query (no in-memory
  post-filter). Surfaces `:prepared`, `:signing`, `:broadcasting`,
  and `:pending_confirmation` rows ordered `inserted_at desc`;
  terminal statuses (`:confirmed`, `:reverted`, `:aborted`) are
  excluded by the query. Read-only — no abort/pause controls in this
  slice. Tests cover empty state, present rows, all four non-terminal
  statuses rendering with `data-status`, terminal exclusion,
  sibling-workspace isolation, and stuck/in-flight coexistence (a
  stuck plan appears in BOTH cards because in-flight is the superset).
  Landed in [#324](https://github.com/Linh86/cryptobank/pull/324)
  ("SecurityLive: show in-flight execution plans (#229)"), merge SHA
  `9f8bdbc`.
- **Emergency-action confirmation audit** — every mutating control on
  `/security` carries a `data-confirm` attribute so a JS click handler
  can prompt before applying. `#resume-btn` gained `data-confirm` in
  this slice; the existing mutating buttons already had it pinned:
  `#pause-btn`, `#agent-keys-pause-submit`, `#agent-keys-resume`,
  `#revoke-btn-<smart_account_id>`, `#revoke-retry-btn-<smart_account_id>`,
  and `#abort-plan-btn-<plan_id>`. Read-side controls (`refresh`,
  `clear_safety_filters`) intentionally remain unconfirmed and are
  pinned negative so a future drive-by edit cannot silently regress
  the audit. Eight tests in `SecurityLiveTest` use stable
  `#id[data-confirm]` selectors. Landed in
  [#327](https://github.com/Linh86/cryptobank/pull/327) ("SecurityLive:
  confirm emergency actions (#229)"), merge SHA `8eba1b3`. Closes the
  *"All emergency actions confirm before applying"* acceptance bullet
  for `/security`; does not close #229 by itself.
- **Pending approvals card** — operator-visible read-only card that
  surfaces the current workspace's pending approvals inline so the
  operator can see triage demand without leaving `/security`. Stable
  element id `#pending-approvals-card`. Reads from
  `Bank.Decisions.list_pending_approvals/1` with `:workspace_id`
  pushed into the DB query. Each row links into
  `/queue#pending-approvals-section`, which remains the dedicated
  triage surface. Landed in
  [#329](https://github.com/Linh86/cryptobank/pull/329) ("SecurityLive:
  show pending approvals card (#229)"), merge SHA `89f6698`.
- **Incident summary snapshot** — read-only operational-counts panel
  rendered above `#safety-events-card`. Stable element id
  `#incident-summary-card` for the panel and
  `#incident-summary-copy-block` for the operator copy/export block
  underneath. Counts only — no reasons, no payloads, no policy
  snapshot, no API keys, no bearer tokens, no tx refs, no signing
  material. Landed in [#330](https://github.com/Linh86/cryptobank/pull/330)
  ("SecurityLive: add incident summary snapshot (#229)"), merge SHA
  `4f0d64b`.
- **`security.scope_paused` / `security.scope_resumed` on the safety
  timeline** — additive audit-event types for DB-backed scoped pauses
  (`#228` Phase 1: chain). Wired into `@safety_event_types` and into
  `visible_to_workspace?/3` with workspace-id-gated clauses placed
  BEFORE the existing `"security." <> _` catch-all so workspace-scoped
  scope events do not leak across workspaces. Backend gate landed in
  [#326](https://github.com/Linh86/cryptobank/pull/326) ("Add DB-backed
  per-chain pause gate (#228 phase 1)"), merge SHA `9083bc3`. The
  per-chain pause card with operator controls is still a follow-up
  slice (see *Remaining likely slices* below).

### `BankWeb.DashboardLive` (`/`)

- **Stuck-plans attention line** — top-of-dashboard banner row when the
  detector reports stuck plans. Landed in
  [#311](https://github.com/Linh86/cryptobank/pull/311)
  ("DashboardLive: stuck-plans attention line + Layouts.app
  current_scope (#229)").
- **Workspace agent-keys-paused attention line** — top-of-dashboard
  banner row when the workspace agent-key lockdown is active. Landed in
  [#313](https://github.com/Linh86/cryptobank/pull/313).
- **Attention-banner stable ids and links** — every attention banner
  row now has a stable id and an actionable link target. Landed in
  [#315](https://github.com/Linh86/cryptobank/pull/315).
- **Stat-card queue links** — dashboard stat cards link into the
  per-queue sections (intents, decisions, plans). Landed in
  [#316](https://github.com/Linh86/cryptobank/pull/316).
- **Runtime + delegation stat-card links to `/security`** — the
  symmetric set of dashboard stat-card links pointing into the security
  console. Landed in [#320](https://github.com/Linh86/cryptobank/pull/320).

### Cross-cutting (operator pages)

- **`current_scope` propagation across operator pages** — every
  operator LiveView passes the current scope to `<Layouts.app>` so
  navigation and per-tenant guards behave uniformly. Landed in
  [#319](https://github.com/Linh86/cryptobank/pull/319) ("LiveViews:
  pass current_scope to <Layouts.app> across operator pages (P3 sweep,
  supersedes #317)").

## Remaining likely slices

These are probable next pieces under #229 based on the issue body's
scope list and the surfaces not yet present. They are *suggestions*,
not commitments — a human owner should triage before assigning.

- **Failed/retrying jobs surface** — `#229` lists "failed/retrying
  jobs". **Blocked on backend Oban/read API** — today the operator
  drops into Oban LiveDashboard or queries the DB. A workspace-scoped
  read API for the relevant Oban queues would unlock a small per-queue
  retry panel on the security console.
- **Provider/adapter health summary** — `#229` lists this as a
  section. **Blocked on a cached backend health source** —
  `bank.ops.health.adapter_up` / `database_up` / `stuck_plans` exist
  via `/v1/health/deep`, but the LiveView surface needs a cached /
  push-driven source rather than re-running the deep probe per render.
- **Chain-pause UI card** — operator card for per-chain pause
  controls (pause / resume buttons, current paused-chains list,
  workspace-scoped). The DB-backed Phase 1 backend has now LANDED in
  [PR #326](https://github.com/Linh86/cryptobank/pull/326) (merge SHA
  `9083bc3`), so the gate is no longer "blocked on backend" — what
  remains for the UI slice is a controller / OpenAPI surface for
  pause/resume (or an admin-only LiveView form path), then the card
  itself. UI work bounded by the
  [PR #310](https://github.com/Linh86/cryptobank/pull/310) design memo
  §9.

## Optional enhancements

These are nice-to-haves that go BEYOND the #229 issue-body section
list as already addressed by shipped surfaces. Triage to a follow-up
issue if pursued; do not bundle into a #229 closeout.

- **Richer incident summary beyond the snapshot card** — the basic
  read-only operational-counts snapshot landed in
  [PR #330](https://github.com/Linh86/cryptobank/pull/330). Further
  enrichment (e.g., a curated "what happened in the last N minutes"
  narrative pulled from the safety timeline + audit log, or a
  structured export the post-mortem checklist in
  [`docs/incident-runbook.md`](../incident-runbook.md) can paste
  directly) is a follow-up; the current snapshot is intentionally
  counts-only with no reasons/payloads/token material/tx refs/signing
  material. Any enhancement must preserve those redaction guarantees.

## Blocked by #228

The per-scope pause backend is being delivered under #228 across the
slices below. As of the last refresh, the design memo
([PR #310](https://github.com/Linh86/cryptobank/pull/310)) is open and
Phase 1 backend ([PR #326](https://github.com/Linh86/cryptobank/pull/326))
is merged.

- **Per-chain pause card** — Phase 1 of #228. Backend gate is **MERGED**
  ([PR #326](https://github.com/Linh86/cryptobank/pull/326), SHA
  `9083bc3`). Remaining for UI: a controller / OpenAPI surface (or
  admin LiveView form) and the card itself. `expires_at`, the
  auto-resume sweeper, and any ETS projection are explicitly deferred
  to Phase 1.5+ per the design memo §6 / §13.
- **Per-smart-account pause toggle on the delegations card** — Phase 2;
  no backend yet.
- **Per-api-key pause toggle on the API-keys management surface** —
  Phase 3; no backend yet.
- **Aggregate scoped-pause badge** on the security console header —
  also part of #228 §9 UI impact.

The design memo §9 ([PR #310](https://github.com/Linh86/cryptobank/pull/310))
documents exactly which `SecurityLive` slots get touched, so each UI
slice is bounded and reviewable once its backend half lands.

## Not in scope for #229 (and therefore not in this map)

- Backend implementation under #228 (pause table, dispatch gates,
  context API). Tracked under #228.
- New `/v1/security/*` endpoints. Tracked alongside the relevant phase
  PR for #228.
- Chain adapter / TS adapter / `priv/adapter/contract.md` changes.
- Audit-event renames or shape changes outside the additive
  `security.scope_paused` / `security.scope_resumed` events documented
  in the design memo §8.

## How to use this map

- Picking up #229 next slice: scan **Remaining likely slices**, pick
  one, file (or claim) a sub-issue under #212 if the work is
  non-trivial, open a PR with `(#229)` in the title.
- Reviewing a #229 PR: check this map for surface overlap. If the PR
  covers a surface listed in **Shipped surfaces**, ask the author
  whether it is a follow-up patch or genuinely new scope.
- Closing #229: do **not** rely on this map alone. Map every
  acceptance criterion in the #229 issue body to landed evidence (PRs,
  tests, screenshots), the way the [#230 closure
  comment](https://github.com/Linh86/cryptobank/issues/230) did.

## Maintenance

This file is a snapshot. Update it when a new Incident Center surface
lands on `main`, or when a slice is no longer "likely next" because
priorities shifted. Keep entries terse — the PR title and number is
enough; this is not a place for design rationale.
