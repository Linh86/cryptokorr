# Bank v0.1 — Control Plane

Phoenix control plane for Bank v0.1, an internal codename for a non-custodial
AI treasury runtime. This application is the decision authority: it accepts
agent intents, evaluates policy, consults trust and simulation inputs, writes
decisions, manages approvals, and orchestrates execution through a separate
TypeScript chain-adapter service.

Authoritative references (do not edit implementation assumptions without
updating these docs first):

* [docs/bank-v0.1-decision-memo.md](docs/bank-v0.1-decision-memo.md) — product
  thesis and architecture decisions.
* [docs/bank-v0.1-domain-model.md](docs/bank-v0.1-domain-model.md) — canonical
  domain objects and state machines.
* [docs/bank-v0.1-runtime-flow-and-api.md](docs/bank-v0.1-runtime-flow-and-api.md)
  — end-to-end runtime flow and `/v1/` API contract.

## Architecture at a glance

The control plane is a single Phoenix application at the repository root. It
is API-first but retains standard Phoenix structure so the web control tower
(Dashboard, Counterparties, Policies, Action Queue, Audit/Replay, Security
Console) can live alongside the API.

```
Agent -> POST /v1/intents -> Phoenix (decision authority)
                               |  - policy evaluation
                               |  - trust / evidence lookup
                               |  - simulation orchestration
                               |  - decision + approvals
                               |  - audit capture
                               v
                       TypeScript adapter (chain execution specialist)
                               v
                       Wallet / smart account / on-chain guardrails
```

* **Phoenix (this app)** owns decisioning, approvals, audit, pause, and the
  external `/v1/` API.
* **TypeScript adapter** (separate service, not in this repo) wraps simulation
  providers, bundlers / RPC, and wallet / smart-account behavior. It receives
  `ExecutionPlan` skeletons, fills in chain-specific steps, signs, broadcasts,
  and reports outcomes back over a private internal contract.
* **Postgres** is the source of truth for every domain object.
* **Oban** drives async orchestration (evaluation, approval TTL, execution,
  confirmation polling, delegation revoke).
* **Phoenix PubSub** drives realtime fan-out to the web control tower.

Failure in the adapter or any provider widens caution in Phoenix; it never
widens autonomy.

## Bounded contexts

Each context owns a clear slice of the domain. Contexts talk through narrow
public functions, not through each other's schemas.

| Context                | Responsibility |
|------------------------|----------------|
| `Bank.Intents`         | `AgentIntent` submission + lifecycle. |
| `Bank.Counterparties`  | Counterparties, address labels, evidence, operator-issued trust assertions. |
| `Bank.Policies`        | Versioned `PolicyRule` catalog and evaluation snapshots. |
| `Bank.Decisions`       | `DecisionEnvelope` writing and the approval state machine. |
| `Bank.Audit`           | Append-only `AuditEvent` stream and per-intent replay bundles. |
| `Bank.Runtime`         | Workflow orchestration (Oban queues) and realtime fan-out (PubSub topics). |
| `Bank.Delegations`     | Durable smart-account delegation projection + execution gating. |
| `Bank.Security`        | Pause / resume and delegation revocation. |

Full module-level docstrings live alongside each file under `lib/bank/`.

## Oban queues

Queue names use underscores because Oban queue atoms are idiomatically
underscored; the left column is the canonical semantic name from the
runtime-flow doc.

| Semantic name         | Queue atom             | Purpose |
|-----------------------|------------------------|---------|
| `intents.evaluate`    | `:intents_evaluate`    | Policy + trust + simulation pipeline on intent submission. |
| `intents.reevaluate`  | `:intents_reevaluate`  | Hold-TTL and trust/policy-change-driven re-evaluation. |
| `approvals.expire`    | `:approvals_expire`    | Approval TTL → successor envelope with outcome `block`. |
| `executions.run`      | `:executions_run`      | Re-validate the decision, plan, pause state, and delegation, then dispatch the transfer through the adapter. |
| `executions.confirm`  | `:executions_confirm`  | Safety-net reconciliation if adapter callbacks miss a terminal plan finalisation. |
| `security.revoke`     | `:security_revoke`     | Dispatch delegation revoke transaction through the adapter. |

Workers live under `Bank.Runtime.Workers`; see "Workers and realtime
fan-out" below for what each one does, which do real state transitions
today, and the retry posture.

## PubSub topics

Typed helpers live in `Bank.Runtime.PubSub` (topic strings) and
`Bank.Runtime.Notifier` (message shapes). Controllers, LiveViews, and
workers never hand-roll either; every broadcast is a map with a fixed
skeleton:

```elixir
%{
  topic: <atom>,          # which contract this message belongs to
  event: <atom>,          # specific transition (e.g. :expired)
  at: %DateTime{},        # runtime wall clock for the broadcast
  ...                     # topic-specific payload fields
}
```

* `intent:{id}`             — per-intent lifecycle transitions
  (`:state_changed`, `:decision_updated`, `:execution_updated`).
* `approval:queue`          — approval queue changes (`:enqueued`,
  `:expired`, `:granted`, `:rejected`).
* `dashboard:runtime_status` — runtime health / pause state.
* `security:events`         — pause, resume, revoke notifications.
* `audit:stream`            — compact summary of every emitted audit
  event (`Bank.Runtime.emit_audit/1` publishes here after the DB insert
  succeeds).

## Web control tower

The operator-facing web UI is a Phoenix LiveView application served
from the browser scope. Issue #13 delivers the first screen — the
connection and delegation dashboard at `/`.

**`BankWeb.ControlLive` (`/`)**

The landing page shows:

* **System status bar** — execution readiness and global pause state.
* **Delegation card** — the primary smart-account delegation with
  state badge (active / pending / revoking), chain, asset, delegation
  ID, timestamps, and scope.
* **Next-steps panel** — context-sensitive guidance based on the
  current delegation and runtime state.
* **Runtime card** — pause / resume controls with confirmation.
* **Architecture callout** — explains the non-custodial three-layer
  architecture (control plane, chain adapter, on-chain guardrails).

All state is loaded from the real backend contexts (`Bank.Delegations`,
`Bank.Security`). The LiveView subscribes to `security:events` via
PubSub and re-renders on pause/resume/revoke broadcasts without
polling.

**`BankWeb.DashboardLive` (`/dashboard`)**

The operator dashboard provides a high-signal overview of the runtime:

* **Stat cards** — runtime status (running / paused), delegation state,
  pending approvals count, and active executions count. Each card pulls
  real backend data from `Bank.Decisions` and `Bank.Delegations`.
* **Needs attention banner** — aggregates actionable items (paused
  runtime, missing delegation, in-flight revocations, pending approvals,
  active executions) into a single summary.
* **Recent decisions** — the latest current decision envelopes with
  outcome badges, risk tier, and intent summary. Empty state shows
  guidance about the trust engine.
* **Execution readiness checklist** — three-item checklist (runtime,
  delegation, execution) with pass/fail indicators.

Subscribes to four PubSub topics: `security:events`, `approval:queue`,
`dashboard:runtime_status`, and `audit:stream`. Re-renders on any
broadcast without polling.

**`BankWeb.IntentsLive` (`/intents`)**

Dedicated operator view of the intent stream, separate from dashboard
summaries, queue rows, and replay drilldowns:

* **State breakdown** — count chips for each `AgentIntent.state`.
  Counts respect the active `kind` and search filters, but
  intentionally ignore the active `state` filter so each chip answers
  "what would this slice show if I switched to this state?"
* **Filterable table** — shareable query-param filters for state,
  kind, and free-text search by agent ID or intent ID.
* **Intent rows** — latest intents with agent, kind, amount, target,
  state badge, submitted timestamp, and a direct "Replay" link to
  `/audit/replay/:intent_id`.
* **Empty state** — explains when the current filter slice has no
  matching intents.

Subscribes to `audit:stream`; any audit append triggers a reload of the
current slice without polling.

**`BankWeb.QueueLive` (`/queue`)**

The action queue surfaces decisions and executions that need attention:

* **Pending approvals** — decisions with outcome `:approval_required`.
  Approve/reject actions are live in both the UI and `/v1/approvals`.
  Approval records the successor decision envelope; actual execution
  still requires an explicit `POST /v1/decisions/:id/execute` with the
  chosen `smart_account_id`. Shows risk tier and expiry time.
* **Active executions** — in-flight execution plans (non-terminal
  status). Shows execution status badge and intent summary.
* **Held actions** — decisions with outcome `:hold` from the trust
  engine.
* **Blocked actions** — decisions with outcome `:block`. Read-only
  for audit investigation.

Empty state shows when the queue is clear. Subscribes to
`approval:queue`, `security:events`, and `audit:stream`.

**`BankWeb.CounterpartiesLive` (`/counterparties`)**

List and create counterparties — the business-level recipients that
addresses, evidence, and trust assertions attach to:

* **Counterparty list** — name, trust level badge (trusted / sensitive /
  unknown / conflicted), and link to detail page.
* **Inline create form** — changeset-backed form with name, initial trust
  level, ownership context, and notes. Blank enum selects are stripped
  before context calls to avoid Ecto.Enum cast errors.
* **Archive filter** — toggle to show/hide archived counterparties.

**`BankWeb.CounterpartyDetailLive` (`/counterparties/:id`)**

Full management of a single counterparty:

* **Edit** — inline form to rename or update notes/ownership context.
* **Archive** — one-click archive with state badge update.
* **Address labels** — attach blockchain addresses (chain + address + role),
  retire addresses (preserves history, removes from active list).
* **Evidence artifacts** — pin evidence (kind + content URI) to the
  counterparty. Append-only.
* **Trust assertions** — issue trust assertions with level, rationale, and
  optional scope (asset/chain). Displays assertion history with
  supersession. Schemaless changeset for the trust form.

Redirects to `/counterparties` if the counterparty ID is not found.

**`BankWeb.PoliciesLive` (`/policies`)**

Policy rules management with rule-type-specific structured param forms
(not raw JSON):

* **Rules list** — rule type, params summary, scope badges, state badge,
  and action buttons per rule.
* **State filter** — Active (default), All, Archived, Draft tabs.
* **Inline create form** — select a rule type to render its specific param
  fields. Supports all 8 rule types: amount limit, rolling spend cap,
  slippage ceiling, allowed router, allowed asset, allowed chain,
  autonomy tier, and time window.
* **Revise** — inline form below the rule being revised, pre-filled with
  current params. Creates a new version and supersedes the prior.
* **Archive** — one-click archive with flash confirmation.

**`BankWeb.AuditLive` (`/audit`)**

Append-only audit trail — the operator's view of what happened, who
triggered it, and what state changes followed:

* **Event list** — each row shows event type, actor, subject, correlation
  id, and timestamp. Color-coded badges per event family
  (intent/decision/trust/simulation/approval/execution/security).
* **Filters** — by event type, subject type, or correlation id. Invalid
  uuids in the correlation filter are gracefully ignored (empty result
  rather than 500).
* **Replay drilldown** — every row whose `correlation_id` is set carries
  a one-click "Replay" link to the per-intent replay view.
* **Real-time tail** — subscribes to `audit:stream`; the page reloads on
  every appended event without polling.

This is intentionally a focused log reader, not a SIEM. No aggregations
or saved searches.

**`BankWeb.IntentReplayLive` (`/audit/replay/:intent_id`)**

Per-intent replay — the deterministic bundle that explains a decision
path. Reads `Bank.Audit.replay/1` directly; no business logic is re-run.

Six stacked sections, in operator-reading order:

1. **Intent summary** — original submission (kind, asset, chain, amount,
   target, source, idempotency key).
2. **Audit timeline** — full correlation slice as a numbered sequence.
3. **Trust assessment history** — every claim with derived trust,
   confidence, supporting assertion/evidence counts, oldest first.
4. **Simulation history** — every report with status, provider, gas,
   slippage, TTL.
5. **Decision history** — every envelope with outcome, risk tier,
   reasons, supersession order.
6. **Execution plan history** — every plan with status, final outcome,
   tx refs.
7. **Policy snapshot** — the union of rule uuids captured across every
   decision, resolved to full rule rows.

Empty bundles render "nothing to show yet" stubs so an in-flight intent
loads cleanly. Subscribes to `audit:stream` and the per-intent
lifecycle topic for real-time updates.

**`BankWeb.SecurityLive` (`/security`)**

Operator security console — runtime safety posture and emergency
controls in one place:

* **Posture banner** — paused / no-delegation / ready / blocked, with
  one-line explanation of the current state.
* **Runtime card** — pause/resume controls with `data-confirm` prompts.
  Shows reason, actor, and timestamp when paused (from
  `Bank.Security.snapshot/0`).
* **Delegations card** — every active delegation, not just the primary.
  Per-row revoke button transitions the row into `:revoking` state
  immediately so an operator can't double-tap.
* **Recent safety events** — the audit slice for `security.*` and
  `delegation.*` event types, capped at 15.

Subscribes to `security:events` and `audit:stream`; pause/resume/revoke
changes from any source (this UI, the API, another operator) are
reflected immediately. Reuses the real `Bank.Security` and
`Bank.Delegations` contexts directly — no second interpretation layer.

**Route-aware navigation.** The sidebar navigation is route-aware: every
landed page (Dashboard, Connection, Intents, Action Queue, Policies,
Counterparties, Audit, Security) highlights based on the current page.
Each LiveView passes an `active_page` assign to the shared
`Layouts.app/1` shell.

**What is not yet included:**

* **Browser wallet integration.** The repo does not yet include a
  client-side wallet SDK (WalletConnect, wagmi). Delegation is
  established through the adapter callback flow; the UI reflects
  the state the backend already tracks. This limitation is made
  explicit in the UI.
* **Public intent intake.** `POST /v1/intents`, `GET /v1/intents/:id`,
  `POST /v1/intents/:id/simulate`, and `POST /v1/intents/:id/cancel`
  remain stubbed while the trust + simulation pipeline is still being
  wired into end-to-end submission.
* **Wallet risk intelligence.** Counterparty management exists today,
  but runtime address screening against sanctions, scam feeds, public
  attribution tags, and internal suspicious-wallet scoring has not yet
  been integrated into intent routing (epic #55).

The sidebar layout, theme toggle, and navigation shell are shared
infrastructure that future pages can reuse.

## `/v1/` API surface

Every endpoint from the runtime-flow doc has a routed home and a typed
controller. Surfaces are filled in progressively as owning engines land:

* **Decisions** (`GET /v1/decisions/:id`,
  `POST /v1/decisions/:id/execute`) are wired through
  `Bank.Decisions`.
* **Approvals** (`GET /v1/approvals`,
  `POST /v1/approvals/:decision_id/approve`,
  `POST /v1/approvals/:decision_id/reject`) are wired through
  `Bank.Decisions`' approval state machine.
* **Counterparty + address book + trust assertion routes** are wired
  through `Bank.Counterparties` (`/v1/counterparties*`,
  `/v1/address_labels/:id`, `/v1/trust_assertions`). See
  "Counterparties + address book" below.
* **Policy catalog routes** are wired through `Bank.Policies`
  (`GET /v1/policies`, `POST /v1/policies`, `POST /v1/policies/:id/revise`,
  `POST /v1/policies/:id/archive`). See "Policy engine" below.
* **Security** (`POST /v1/security/pause`, `/resume`,
  `/revoke_delegation`) is wired through `Bank.Security`.
* **Audit** (`GET /v1/audit`) and **Replay**
  (`GET /v1/intents/:id/replay`) are wired through `Bank.Audit`.
* **Browser connect scaffolding** (`POST /v1/connect/smart_account`) is
  wired through `Bank.Delegations.request_connect/1`, but the actual
  adapter-side grant dispatch is still stubbed.
* **Intent replay** is live, but the agent-facing intent intake and
  submission endpoints still return a `501 Not Implemented` envelope
  until the full evaluation pipeline lands.

See `lib/bank_web/router.ex` for the complete route table, or run
`mix phx.routes`.

Error envelope (shared across all `/v1/` controllers):

```json
{ "error": { "code": "...", "message": "...", "hint": "...", "retryable": false } }
```

Health and readiness:

* `GET /health`    — liveness, no DB touch. Safe for a load balancer.
* `GET /v1/health` — readiness. Verifies the Postgres connection.

## Local setup

Prerequisites: Elixir 1.15+, Erlang/OTP 26+, PostgreSQL reachable at
`localhost:5432` with a `postgres` role (default credentials in
`config/dev.exs` and `config/test.exs`).

```bash
mix deps.get
mix ecto.create
mix ecto.migrate
mix phx.server
```

Then:

* Liveness: `curl http://localhost:4000/health`
* Readiness: `curl http://localhost:4000/v1/health`
* LiveDashboard: `http://localhost:4000/dev/dashboard`

Run the test suite with `mix test`. Tests use `Ecto.Adapters.SQL.Sandbox`; the
test database auto-creates/migrates on first run.

## Schema strategy

The domain schema (issue #4) is deliberately explicit about a few
cross-cutting conventions; once you see them once, every table reads the
same way.

**UUID-everywhere.** Every row keyed by a DB-generated UUID v4 (`binary_id`
column, `gen_random_uuid()` default). Foreign keys are `binary_id`
throughout. Shared in `Bank.Schema`.

**Append-only history via supersession.** Domain objects that evolve
(policy rules, evidence, trust assertions, trust assessments, simulations,
decision envelopes, execution plans) are never edited in place. An
"update" writes a new row with `supersedes_id` pointing at the prior row.
The prior row is never deleted or mutated, which keeps replay bundles
deterministic.

**Current + history invariant.** On tables where the runtime reads "the
current row for this intent," a `current` (or `active`) boolean plus a
**partial unique index** (`WHERE current` / `WHERE active`) guarantees at
most one live row at a time. Successor writes flip the prior row's flag
off and insert the new row in the same transaction.

**Polymorphic subjects.** `EvidenceArtifact`, `TrustAssertion`, and
`AuditEvent` all key off `(subject_type, subject_id)`. Postgres can't
foreign-key that, so the invariant is a CHECK constraint on the allowed
`subject_type` values plus app-level validation of `subject_id`.

**Cached current-pointers on `agent_intents`.** `current_decision_id`,
`current_trust_assessment_id`, etc. are plain uuid columns with no FK.
They're set in the same transaction as the child-row insert. The
authoritative "which row is current" invariant lives on the child
table's partial unique index — pointers are a read optimisation, not
the source of truth.

**Policy snapshot by uuid.** `decision_envelopes.policy_snapshot_ref` is
`%{"rule_ids" => [uuid, ...]}`. Because `policy_rules` is append-only,
those uuids are a stable, minimal capture of what ruleset evaluated the
intent; no separate `policy_snapshots` table is needed.

**`amount` is numeric(38,18).** Eighteen decimal places cover ERC-20
decimals with headroom for wei-style units if the runtime ever leaves
Base.

Data-layer tests under `test/bank/` cover every constraint, uniqueness
rule, validation, and supersession helper described above.

## Audit + replay

`Bank.Audit` is the only sanctioned writer for `audit_events`. Emitters
go through one of:

```elixir
Bank.Audit.append_event(attrs)         # write one event
Bank.Audit.append_events([...])        # write a batch atomically
Bank.Audit.list_events(filters, opts)  # paged read (GET /v1/audit)
Bank.Audit.replay(intent_id)           # bundle (GET /v1/intents/:id/replay)
```

**Append-only posture.** The public API exposes no update or delete
function. `AuditEvent` has no `updated_at`, no update changeset, and a
Postgres trigger (migration `20260415170600_lock_audit_events.exs`)
raises `read_only_sql_transaction` on any `UPDATE`/`DELETE` against the
table. An accidental mutation fails loudly rather than silently
corrupting the record.

**Correlation conventions.** Every state transition carries a
`correlation_id`. The rules:

* **Intent-scoped events** — `correlation_id == intent_id`. This covers
  the bulk of the audit stream (submission, evaluation, decision,
  simulation, approval, execution).
* **Counterparty / address-label admin** — `correlation_id` is the
  counterparty id (or the label's owning counterparty id, never the
  label's own id). One filter tails the counterparty's history across
  all its labels.
* **Policy admin** — `correlation_id` is the rule's own id; the top of
  the supersession chain isn't stable enough to correlate on.
* **Runtime-global events** (`security.paused`, `delegation.revoked`)
  — `correlation_id` is `nil`; readers filter by `event_type` + `ts`.

**Event-type naming.** Dotted, lowercase, `<object>.<verb>`, past
tense. Examples: `intent.submitted`, `decision.decided`,
`execution.prepared`, `policy.revised`. The vocabulary is documented in
the `Bank.Audit` moduledoc; extending it is a doc change, not a schema
change.

**Payload hashing.** `payload_hash` is `sha256` (hex, lowercase) over
the canonical JSON encoding of the envelope's content fields —
alphabetically sorted keys, nils stripped, DateTimes as ISO-8601,
Decimals as canonical strings. Implementation: `Bank.Audit.Envelope`.
This hash is the substrate for later chain anchoring; integrity
anchoring itself is intentionally out of scope for v0.1.

**Emitter helpers.** `Bank.Audit.Events` returns pre-shaped attr maps
for common transitions (`intent_submitted/2`, `decision_decided/2`,
`execution_transition/3`, `policy_revised/3`, ...). Workers and
controllers call these, not the envelope directly, so that the shape of
an `intent.submitted` event changes in one place.

**Realtime fan-out.** `Bank.Runtime.emit_audit/1` is the seam between
persistence and PubSub: it calls `Bank.Audit.append_event/1` and, on
success, publishes a compact summary (`id`, `event_type`,
`subject_type`, `subject_id`, `correlation_id`, `ts`) to
`audit:stream`. Tests or backfills that want persistence alone can
still call `Bank.Audit.append_event/1` directly.

**Polymorphic subject_id.** `audit_events.subject_id` is a free-form
text column. Most subjects are uuid-keyed domain rows (`agent_intent`,
`decision_envelope`, ...), but `smart_account` subjects use an opaque
string id and future on-chain subjects may use hex addresses. The
column widening (`subject_id uuid → text`) landed with issue #6 so the
`security.revoke_requested` audit event could record the smart-account
id directly.

**Replay determinism.** `Bank.Audit.replay/1` reads the authoritative
child tables (`trust_assessments`, `simulation_reports`,
`decision_envelopes`, `execution_plans`) in domain-time order — not
cached `current_*_id` pointers on `agent_intents` — then pulls the
policy snapshot by resolving the union of `rule_ids` captured in every
decision's `policy_snapshot_ref`. The audit slice filters by
`correlation_id == intent_id`, ordered `(ts, id)`.

**Pagination cursor.** `Bank.Audit.cursor/1` encodes `(ts, id)` as an
opaque url-safe base64 JSON token. Reversible, stable under ties,
decode failures return `:error` instead of crashing — the controller
surfaces that as `422 invalid_query`.

## Counterparties + address book

`Bank.Counterparties` is the operator-authoritative write path for
recipients. Decisioning (issue #9+) and the trust engine read
through this context rather than touching `Counterparty`, `AddressLabel`,
`EvidenceArtifact`, or `TrustAssertion` directly.

**Object model.**

| Object             | Role                                                                 |
|--------------------|----------------------------------------------------------------------|
| `Counterparty`     | Business-level recipient. Policy and trust reason at this level.     |
| `AddressLabel`     | A `(chain, address)` pair owned by a counterparty. Retire, not edit. |
| `EvidenceArtifact` | Append-only piece of evidence on a counterparty or label.            |
| `TrustAssertion`   | Operator or trust-engine trust claim on a counterparty or label. |

**Public context API.**

```elixir
Bank.Counterparties.list_counterparties(filters, opts)
Bank.Counterparties.get_counterparty(id)
Bank.Counterparties.get_counterparty_with_preloads(id)
Bank.Counterparties.create_counterparty(attrs, opts)
Bank.Counterparties.update_counterparty(cp, attrs, opts)
Bank.Counterparties.archive_counterparty(cp, opts)

Bank.Counterparties.attach_address(cp, attrs, opts)
Bank.Counterparties.update_address_label(label, attrs, opts)
Bank.Counterparties.retire_address_label(label, opts)
Bank.Counterparties.resolve_address(chain, address)

Bank.Counterparties.pin_evidence(subject, attrs, opts)

Bank.Counterparties.issue_trust_assertion(subject_type, subject_id, attrs, opts)
Bank.Counterparties.effective_trust_assertions(subject_type, subject_id)
```

**Write paths emit audit.** Every write composes `Bank.Runtime.emit_audit/1`
with a `Bank.Audit.Events` helper so the DB effect and the audit trail stay
in sync.

| Write action                                 | Audit event                  |
|----------------------------------------------|------------------------------|
| `create_counterparty/2`                      | `counterparty.created`       |
| `update_counterparty/3`                      | `counterparty.updated` (+ `counterparty.archived` on the archival transition) |
| `archive_counterparty/2`                     | `counterparty.archived`      |
| `attach_address/3`                           | `address_label.attached`     |
| `update_address_label/3` (non-retirement)    | `address_label.updated`      |
| `update_address_label/3` (retirement)        | `address_label.retired`      |
| `retire_address_label/2`                     | `address_label.retired`      |
| `pin_evidence/3`                             | `evidence.attached`          |
| `issue_trust_assertion/4`                    | `trust_assertion.issued`     |

Correlation follows the audit convention: counterparty events correlate
on the counterparty's own id; address-label and label-scoped trust /
evidence events correlate on the owning counterparty's id, so one filter
tails a counterparty's full history across all its labels.

**Address-label invariants.**

* `(chain, lower(address))` is unique within the active label set —
  enforced by a partial unique index (`WHERE retired_at IS NULL`).
  Duplicate attachment returns `409`.
* The address and chain are immutable once attached; `PATCH`ing those
  fields silently drops them. A wrong address is retired and replaced.
* Retirement preserves history. Intents and audit rows keep pointing at
  the retired label.
* Attaching to an archived counterparty is rejected (`409`) — evidence
  and trust on a no-home subject would be unreachable from the
  decisioning path.

**Evidence is append-only.** Corrections go through a new row whose
`supersedes_id` references the prior row. The prior row is never edited.
When the caller omits `payload_hash`, the context stores a `sha256` of
`content_uri` as a MVP integrity anchor.

**Trust assertions and supersession.** A new assertion supersedes every
effective prior assertion on the same subject whose scope is covered by
the new scope (every key in the new scope matches the prior's value):

* New `{}` (broad) supersedes every effective assertion on that subject.
* New `{chain: "base"}` supersedes `{chain: "base", asset: "USDC"}` but
  not `{}`.
* New `{chain: "base", asset: "USDC"}` does not supersede
  `{chain: "base"}` — the new scope is narrower.

Supersession runs inside the same `Ecto.Multi` as the insert so the
`trust_assertions_subject_level_active_idx` stays consistent at every
commit boundary. After the commit, `trust_assertion.issued` is emitted
with the most recent superseded prior attached as `before_ref`.

**`current_trust_level` cache rule.** `Counterparty.current_trust_level`
is a read cache of the most recent effective **broadly-scoped** (empty
`scope`) trust assertion on the counterparty. Scoped assertions are
stored and returned verbatim but do not update the cache:

* The cache never "lies" — a cached `:trusted` always has a real,
  effective, unscoped assertion backing it.
* A "trusted for USDC payouts under $500" assertion shouldn't flip the
  counterparty to a global trust badge on a list view.
* Intent-level decisioning walks the effective-assertion set, not this
  cache.

**What's still deferred to the trust engine.** This context handles
only operator-authored state. Derived claims that combine evidence,
prior-successful-transfer data, and on-chain classification into an
`TrustAssessment` land with the trust engine. Those claims will
produce `TrustAssertion` rows through the same `issue_trust_assertion/4`
path, so the cache and supersession invariants here carry forward
unchanged.

## Policy engine

`Bank.Policies` is the versioned rule catalog and evaluation engine. It
owns the append-only `policy_rules` table and the `evaluate/2` function
that decisioning calls on every intent.

**Object model.** A `PolicyRule` is a `(rule_type, params, scope,
priority, state)` tuple with an append-only version chain. `state`
transitions:

* `:draft` — created but not yet participating in evaluation.
* `:active` — participating in evaluation.
* `:superseded` — replaced by a newer version (a successor's
  `supersedes_id` points here).
* `:archived` — retired; no longer considered.

Rules are **never edited in place**. A `revise` writes a new row with
`version = prior.version + 1`, `supersedes_id = prior.id`, and flips the
prior row to `:superseded` in the same `Ecto.Multi`. In-flight
evaluations keep running against the ruleset captured in their
decision's `policy_snapshot_ref`.

**Public context API.**

```elixir
Bank.Policies.list_rules(filters, opts)
Bank.Policies.get_rule(id)
Bank.Policies.load_active_ruleset()

Bank.Policies.create_rule(attrs, opts)
Bank.Policies.revise_rule(rule, attrs, opts)
Bank.Policies.archive_rule(rule, opts)

Bank.Policies.snapshot_applicable(input, ruleset \\ nil)
Bank.Policies.evaluate(input, opts \\ [])
```

**Write paths emit audit.** Every write composes `Bank.Runtime.emit_audit/1`
with a `Bank.Audit.Events` helper.

| Write action      | Audit event       |
|-------------------|-------------------|
| `create_rule/2`   | `policy.created`  |
| `revise_rule/3`   | `policy.revised`  |
| `archive_rule/2`  | `policy.archived` |

Policy audit events correlate on the rule's own id — the tip of the
supersession chain isn't stable enough to correlate on.

**Supported rule types.** Eight in v1:

| `rule_type`          | Semantics |
|----------------------|-----------|
| `amount_limit`       | Per-transaction ceiling on `amount`. Emits an `amount_ceiling` constraint. |
| `rolling_spend_cap`  | Windowed aggregate cap across prior intents. Intent-based accounting — see below. |
| `slippage_ceiling`   | **Swap-only.** Rejects if `slippage_bps` exceeds `max_bps` or is missing. Emits a `max_slippage_bps` constraint. |
| `allowed_router`     | **Swap-only.** Allowlist or denylist of router keys. Emits an `allowed_routers` constraint. |
| `allowed_asset`      | Allowlist or denylist of asset symbols. |
| `allowed_chain`      | Allowlist or denylist of chain keys. |
| `autonomy_tier`      | Global signal — `:auto`, `:manual`, or `:block`. Multiple matching rules collapse to the strictest tier. |
| `time_window`        | Day-of-week + hour-of-day window in a named timezone. |

Swap-only rules are skipped for transfers rather than raised as errors:
a slippage or router rule that only makes sense for swaps does not fail
a transfer intent that has no `router` or `slippage_bps` to reason
about.

**Rolling-spend-cap accounting is intent-based in v1.** Candidate
evaluation aggregates `amount` over `agent_intents` in `:executing` or
`:executed` state within the rule's `window_hours`, excluding the
candidate's own `intent_id`. Intent-based (vs execution-based)
accounting is chosen because it bites at submission time, is trivially
auditable from the intents table, and is conservative — pending work
already counts against the cap. A v1.1 upgrade path to execution-based
accounting is available once the adapter is wired.

**Scope matching.** A rule's `scope` is a small map; an empty scope
matches everything. Supported keys in v1 are `counterparty_id`, `asset`,
and `chain`. Unknown scope keys are treated as match-all so future
scope extensions do not retroactively silence older rules.

**Evaluation output.** `Policies.evaluate/2` returns a
`Bank.Policies.Evaluation` struct:

```elixir
%Bank.Policies.Evaluation{
  pass?: true | false,
  violations: [%{rule_id: _, rule_type: _, code: _, message: _, details: _}],
  matched_rule_ids: [uuid, ...],
  snapshot_ref: %{"rule_ids" => [uuid, ...]},
  autonomy_tier: :auto | :manual | :block,
  constraints: %{
    amount_ceiling: Decimal.t() | nil,
    max_slippage_bps: integer() | nil,
    allowed_routers: [binary()] | nil
  },
  evaluated_at: DateTime.t()
}
```

The engine is fully inspectable. Every violation names the rule that
produced it, carries a stable `code` for programmatic handling, a
human-readable `message`, and a `details` map for replay context.
Violations accumulate across rules — the engine never short-circuits,
so operators see the full failure surface on a single evaluation.

**Snapshot capture.** `snapshot_ref` uses the existing
`%{"rule_ids" => [uuid, ...]}` jsonb shape already stored on
`DecisionEnvelope.policy_snapshot_ref`. The captured ids are the rules
whose scope matched the candidate — a stable, minimal record of what
ruleset evaluated this intent. Because `policy_rules` is append-only,
replaying from the snapshot always sees the exact rule rows that were
live at decision time.

**Evaluation input seam.** `Bank.Policies.EvaluationInput` is a superset
of `AgentIntent` fields plus swap-only extras (`slippage_bps`, `router`)
and a `now` timestamp for TZ-sensitive rules. `Policies.evaluate/2`
accepts either an `EvaluationInput` or an `AgentIntent` directly; the
latter is coerced through `EvaluationInput.from_intent/2`.

**What this engine is not.** There is no user-programmable rule DSL.
The eight rule types above are the v1 surface — extending it is a code
+ doc change, not a runtime one. The engine is deliberately narrow and
sufficient for transfers and whitelist-only swaps.

## Delegation state model

`Bank.Delegations` is the durable Postgres projection of on-chain smart-
account delegation state. The adapter is the source of truth; this context
survives restart and answers three questions without an adapter round-trip:

1. Does this smart account have an active delegation?
2. Is a revoke in flight?
3. When does the delegation window expire?

**State machine.**

```
pending ──grant──▶ active ──revoke_requested──▶ revoking ──revoked──▶ revoked
                     │
                     └──expire──▶ expired
```

Terminal states: `:revoked`, `:expired`. A new grant for the same smart
account creates a new row; a partial unique index on `smart_account_id
WHERE state IN ('pending','active','revoking')` enforces at-most-one
non-terminal delegation.

**Execution gating.** `Delegations.executable?/1` returns `true` only for
`:active` state with a non-expired window. Every other state fails closed.

**Adapter callbacks.** `POST /internal/adapter/callback` with
`kind: "delegation.state_changed"` routes through `Delegations.apply_callback/1`,
which maps adapter states (`granted`, `revoking`, `revoked`, `expired`) to
context transitions. Execution callbacks (`broadcast`, `confirmed`,
`reverted`, `aborted`) are acknowledged at the HTTP layer; plan progression
is handled by `ConfirmExecution`.

## Manual execution

`POST /v1/decisions/:id/execute` is the operator path for triggering
execution of a decided envelope. It runs four sequential gates:

1. **Envelope current + auto_exec** — the envelope must be `current: true`
   and `outcome: :auto_exec`.
2. **No active plan** — no active `ExecutionPlan` for this decision.
3. **Not paused** — the global runtime must not be paused.
4. **Delegation active** — the smart account must have an active,
   non-expired delegation.

Each gate returns a distinct error code so the API can surface precise
feedback. On success, an `ExecutionPlan` is created in `:prepared` state
and enqueued for adapter dispatch.

## Workers and realtime fan-out

`Bank.Runtime` is the connective tissue: it enqueues async work through
Oban, fans out realtime updates through PubSub, and composes
`Bank.Audit` writes with the audit stream. Engines don't touch Oban or
PubSub directly — they go through this narrow API:

```elixir
Bank.Runtime.enqueue_evaluation(intent_id)                      # intents.evaluate
Bank.Runtime.enqueue_reevaluation(intent_id, reason)            # intents.reevaluate
Bank.Runtime.enqueue_approval_expiry(envelope_id, expires_at)   # approvals.expire, scheduled at the deadline
Bank.Runtime.enqueue_execution(decision_id)                     # executions.run
Bank.Runtime.enqueue_confirmation(execution_plan_id)            # executions.confirm
Bank.Runtime.enqueue_delegation_revoke(smart_account_id, reason) # security.revoke

Bank.Runtime.emit_audit(attrs)                                  # Audit.append_event + Notifier.audit_stream
```

**What each worker does today.** Workers split into two groups — the
intent-evaluation safe boundaries that still wait on the policy / trust
/ simulation pipeline, and the workers that already perform real state
transitions or real adapter dispatch.

| Worker              | Queue                  | Posture today |
|---------------------|------------------------|---------------|
| `EvaluateIntent`    | `:intents_evaluate`    | **Safe boundary.** Cancels as `:engines_pending` — the policy / trust / simulation engines land with the engine issues (#8+). |
| `ReevaluateIntent`  | `:intents_reevaluate`  | **Safe boundary.** Same as above, plus validates the intent is in `:decided` or `:blocked`. |
| `ExpireApproval`    | `:approvals_expire`    | **Real transition.** Supersedes the `:approval_required` envelope with a `:block` successor, flips the intent to `:blocked`, emits `decision.decided` + `intent.state_changed` audit, broadcasts on `approval:queue` + `intent:{id}`. Whole transition runs inside an `Ecto.Multi` so the partial unique index stays valid at every commit boundary. |
| `RunExecution`      | `:executions_run`      | **Real adapter dispatch.** Re-validates the decision, plan, pause state, and delegation, then calls the adapter's `/dispatch/transfer` route. Advances the plan to `:signing` on adapter acceptance, aborts deterministically on rejected / unresolvable plans, and relies on callbacks for the rest of the lifecycle. |
| `ConfirmExecution`  | `:executions_confirm`  | **Safety-net reconciliation.** Normally a no-op because adapter callbacks already progress plan + intent atomically. If a callback is lost after the terminal plan write, this worker finalises the intent to `:executed` or `:blocked`. Snoozes while the plan is mid-flight; idempotent on already-finalised intents. |
| `RevokeDelegation`  | `:security_revoke`     | **Real adapter dispatch.** Broadcasts `:delegation_revoke_requested`, writes `security.revoke_requested` audit, then calls the adapter's revoke dispatch route. Final state changes still land via `delegation.state_changed` callbacks. |

**Retry posture.** Oban return tuples encode intent:

* `:ok` — transition succeeded (or there was nothing to do); do not retry.
* `{:cancel, reason}` — deterministic, non-retriable stop (`:not_found`,
  `:already_superseded`, `:engines_pending`,
  `:already_finalised`, `:malformed_args`, wrong-state, wrong-outcome).
  The job completes without retrying — retrying wouldn't help.
* `{:snooze, seconds}` — non-terminal; try again later. Used by
  `ConfirmExecution` while the plan is mid-flight. Snoozes bump
  `max_attempts` so `max_attempts: 20` caps the total wait at ~10 minutes.
* `{:error, reason}` — transient (DB down, changeset error); standard
  Oban backoff + retry.

Failures widen caution, never autonomy. The still-deferred
action-authorising workers (`EvaluateIntent` and `ReevaluateIntent`)
stop short and cancel with `:engines_pending` until the policy / trust /
simulation pipeline is fully wired in — there are no mock results, no
"would have auto-executed" paths.

**Deterministic args.** Jobs always reference stable ids (`intent_id`,
`decision_id`, `execution_plan_id`, `smart_account_id`, `reason`) — no
structs or closures — so a job can be replayed from its row alone.

**Test posture.** `config/test.exs` runs Oban in `testing: :manual`:
jobs insert to the DB but don't auto-run. `Bank.Runtime.Workers.*Test`
modules use `Oban.Testing.perform_job/3` to invoke workers directly and
`Bank.Runtime.PubSub.subscribe/1` + `assert_receive` to verify
broadcasts. Real transitions (`ExpireApproval`, `ConfirmExecution`
terminal path) are covered end-to-end — schema effect, audit rows, and
the three-topic fan-out.

## What this issue does *not* include

Issues #3–#7 give you the scaffold, persistent model, audit + replay
pipeline, the Oban worker + PubSub substrate, and the counterparty +
address book + operator trust surface. The following are intentionally
deferred:

* **Trust / simulation engines.** `Bank.Policies` is wired (issue
  #8), but `EvaluateIntent` and `ReevaluateIntent` still stop at a safe
  boundary and cancel as `:engines_pending` because the trust and
  simulation engines that sit alongside policy in the pipeline land with
  later engine issues. Decisioning wires all three together.
* **Public intent submission.** The trust + simulation + decision
  engines are present as building blocks, but the public
  `/v1/intents*` submission and inspection surface remains stubbed until
  the full end-to-end intake flow is wired.
* **Browser wallet integration.** The connection page shows delegation
  state from the backend but does not yet include a client-side
  wallet SDK. A browser-native "connect wallet" flow (WalletConnect
  / wagmi) is a follow-up once the adapter supports it.
* **Wallet risk intelligence.** Runtime routing does not yet hard-block
  sanctioned addresses, challenge scam/phishing-labelled addresses, or
  enrich counterparties from public crypto attribution tagpacks and
  internal scoring (epic #55).
* **Integrity anchoring.** `payload_hash` is the substrate, but signing
  or external-service anchoring (Merkle chain, witness service) lands
  with issue #12 alongside the final security hardening pass.
