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

- **In-flight execution plans card on `SecurityLive`** — `#229` body
  lists "in-flight execution plans" as a section. The stuck-plans card
  exists; a healthier "currently executing" surface (active plan list
  with adapter status, queue position, and a deep link into the
  per-plan inspector) would round it out.
- **Pending approvals surface** — `#229` lists "pending approvals" as a
  section. Approval queue counts already appear on dashboard stat
  cards (#316/#320); a dedicated panel showing pending approval rows
  with per-row inspect/decide affordances would close that bullet.
- **Failed/retrying jobs surface** — `#229` lists "failed/retrying
  jobs". Today the operator must drop into Oban LiveDashboard or query
  the DB. A small per-queue retry panel on the security console would
  match the surface inventory in the issue.
- **Provider/adapter health summary** — `#229` lists this as a section.
  `bank.ops.health.adapter_up` / `database_up` / `stuck_plans` already
  surface via `/v1/health/deep` and the deep-health response shape; a
  single-row "current health snapshot" panel on the security console
  would let the operator confirm posture without leaving the page.
- **Richer incident summary / export** — operator-facing "what
  happened in the last N minutes" summary that pulls from the safety
  timeline and the audit log. Useful for handoff at end of an incident
  and for the post-mortem writeup that
  [`docs/incident-runbook.md`](../incident-runbook.md) already
  references in its communication checklist.
- **Confirmation modals for emergency actions** — `#229` acceptance:
  *"All emergency actions confirm before applying."* Pause / resume /
  revoke flows already work admin-side; a quick audit of every
  emergency button to confirm a click-through confirmation is wired
  would close this acceptance bullet.

## Blocked by #228

These cannot ship until the per-scope pause backend lands under
#228 / [PR #310](https://github.com/Linh86/cryptobank/pull/310):

- **Per-chain pause card** — Phase 1 of #228.
- **Per-smart-account pause toggle on the delegations card** — Phase 2.
- **Per-api-key pause toggle on the API-keys management surface** —
  Phase 3.
- **Aggregate scoped-pause badge** on the security console header —
  also part of #228 §9 UI impact.

The design memo §9 ([PR #310](https://github.com/Linh86/cryptobank/pull/310))
documents exactly which `SecurityLive` slots get touched, so the UI
work is bounded and reviewable once the backend slice lands.

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
