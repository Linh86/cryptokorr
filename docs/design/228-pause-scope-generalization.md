# Design memo: generalize kill-switch pause scopes (#228)

**Status:** draft for review
**Parent epic:** #212 (Incident / Kill Switch / Recovery Center)
**Authors:** runtime / security
**Path:** `docs/design/228-pause-scope-generalization.md`

## 1. Problem statement

Issue #228 asks us to **"generalize pause/kill-switch controls across global, workspace, chain, agent key, and smart-account scopes"** with a uniform model that records `scope type`, `scope id/value`, `reason`, `created_by`, optional `expires_at`, and `status active/resolved`. The acceptance criteria are explicit:

> - Global pause blocks all execution dispatch.
> - Workspace pause blocks workspace actions.
> - Chain pause blocks chain actions.
> - Agent key pause blocks agent-originated requests.
> - Smart-account pause blocks account dispatch if account model exists.
> - Pause status is audited.

Today only two of those five scopes have meaningful gates wired to dispatch. The runtime cannot, for example, pause Base while leaving Optimism live, cannot pause one specific agent key without revoking it, and cannot pause a single misbehaving smart account without flipping the workspace-wide agent-keys pause and locking out every other agent in the same workspace. Operator scenarios this blocks today:

- **Single-chain incident** (RPC outage, bridge exploit, sequencer halt). The operator wants Base paused; they currently must global-pause, which also blocks any future multi-chain workloads on the same control plane.
- **Compromised agent identity, blast-radius limit.** A specific API key starts emitting suspicious intents. The operator can revoke (`Bank.APIKeys.revoke_key/2`, `lib/bank/api_keys.ex:280`) — but revoke is terminal and forces credential rotation. A reversible "pause this key while we investigate" is not available.
- **Per-account containment.** A smart account's policy posture looks degraded; the operator wants to halt only that account's dispatch path while leaving sibling accounts in the same workspace executing normally. No such lever exists.

The two existing scope shapes (`:global` and `{:counterparty, id}` in `Bank.Security.PauseState`, `lib/bank/security/pause_state.ex:31`) cover the parent epic's "Definition of done" only partially — the parent #212 explicitly enumerates **per-workspace, per-chain, per-agent, and per-smart-account** as DoD bullets.

## 2. Current pause-lever inventory

The runtime ships with four distinct levers; only two are pauses in the strict "fail-closed gate on dispatch" sense.

### 2.1 `Bank.Security.PauseState` (in-memory, runtime-scoped)

A single GenServer process holding `%{global: record | nil, counterparties: %{cp_id => record}}` (`lib/bank/security/pause_state.ex:43`). Mutated through `Bank.Security.pause/2` and `resume/2` (`lib/bank/security.ex:88`, `lib/bank/security.ex:117`). Read at three known dispatch gate sites:

- `Bank.Decisions.validate_not_paused/0` (`lib/bank/decisions.ex:1322`), invoked from `create_execution_plan/4` at `lib/bank/decisions.ex:1205`.
- `Bank.Runtime.Workers.RunExecution.verify_not_paused/1` (`lib/bank/runtime/workers/run_execution.ex:188`) — fail-closed before adapter dispatch, race-tight by design.
- `Bank.Decisions.claim_plan_for_dispatch/1` (`lib/bank/decisions.ex:1495`) does NOT explicitly re-check pause; it relies on the worker-level `verify_not_paused` upstream and on row-locked status guarding.

The state is **process-local**: a control-plane restart clears every pause. The module's own docstring spells the deferral out: *"v0.1 keeps this in-memory — there is exactly one control-plane node per deployment and the expected recovery path on crash is 're-pause if you were paused' via an operator action, because a safety control should never silently come back up in a less-restricted state."* (`lib/bank/security/pause_state.ex:5-9`). A persistence-backed version is explicitly slated for v1.0 in the same docstring.

`paused?({:counterparty, id})` returns `true` if **either** that counterparty or `:global` is paused (`lib/bank/security/pause_state.ex:118`), which is the inheritance contract callers depend on; any new scope must preserve "global pause beats every more-specific check".

### 2.2 Workspace agent-key pause (DB-backed)

Issue #231-a added `workspace.agent_keys_paused_at`, `agent_keys_paused_reason`, `agent_keys_paused_by_user_id` columns and the `Bank.APIKeys.pause_workspace/3` / `resume_workspace/3` API (`lib/bank/api_keys.ex:174`, `lib/bank/api_keys.ex:226`). The gate lives in `Bank.APIKeys.verify_key/1` at `lib/bank/api_keys.ex:453`, returning `{:error, :workspace_paused}` so `BankWeb.Plugs.VerifyAPIKey` can return `401 invalid_credentials` (uniform with revoked/expired). Pause is a **workspace overlay on otherwise-valid keys**; per-row state is untouched. Idempotent via `FOR UPDATE` lock (`lib/bank/api_keys.ex:184`). Audits emit `agent_keys.paused` / `agent_keys.resumed` only on real transitions (`lib/bank/audit/events.ex:1142`, `lib/bank/audit/events.ex:1175`).

This is the canonical durable-pause precedent we extend in §5.

### 2.3 Chain-action rate caps (`BankWeb.Plugs.RateLimit.ChainAction`)

Stricter per-key rate limit applied to `/v1/security/*` (pause, resume, revoke_delegation, pause/resume_agent_keys, abort_execution) — `lib/bank_web/plugs/rate_limit/chain_action.ex:1-87`. Default 5 requests / 60s. **This is throttling, not pausing.** It bounds how fast a credential can spam emergency endpoints; it never blocks dispatch. Mentioned here to keep reviewers from conflating it with the new chain-pause scope (§5 phase 1) — they share neither purpose, datapath, nor lifecycle.

### 2.4 Delegation revoke

`Bank.Security.revoke_delegation/2` (`lib/bank/security.ex:166`) enqueues an on-chain revoke through the TS adapter. It is **terminal at the API level** — re-delegation is an operator console flow only. Functionally adjacent to pause but distinct in shape: revoke is a one-way authoritative cut, pause is reversible. The new pause scopes do not displace revoke; they fill the reversible gap below it.

## 3. Goals and non-goals

### Goals

- **Per-chain pause** (`{:chain, "base"}`). Block every dispatch whose plan targets that chain.
- **Per-agent-key pause** (`{:api_key, key_id}`). Reject `/v1` traffic from a specific key with `401 invalid_credentials`, reusing `VerifyAPIKey`'s existing reject envelope (`lib/bank/api_keys.ex:447-454`).
- **Per-smart-account pause** (`{:smart_account, sa_id}`). Block dispatch whose `ExecutionPlan.smart_account_id` matches.
- **Durable across control-plane restart** for any scope where the resource is itself durable (chain, key, smart account). `:global` and `{:counterparty, id}` may stay in-memory in v0.1 and acquire durability later — the new scopes get durability up front because the resources they reference live in the DB.
- **Audited** with actor/subject/correlation/workspace_id, idempotent on repeat calls, mirroring the `agent_keys.*` precedent.
- **Workspace-scoped where applicable.** Per-key, per-smart-account, and per-chain pauses are workspace-scoped — one workspace pausing Base cannot affect a sibling workspace's Base traffic. `:global` stays runtime-global by definition.

### Non-goals

- **Chain adapter internals.** The TS adapter side is untouched; pause sits in the Phoenix dispatch path.
- **Broadcast / signing path.** No change to `RunExecution`'s adapter call shape, the contract in `priv/adapter/contract.md`, or the dispatch envelope.
- **`.env` / Sepolia / mainnet / network rotation.** Out of scope; this is a control-plane gate, not a network change.
- **NOT NULL columns or production backfills.** Per AGENTS.md cross-cutting checklist, every new column is nullable-first and any backfill is dry-run, batched, logged. The recommended schema (§6) ships with zero NOT NULL adds.
- **#158e workspace_id audit backfill** is explicitly out of scope. The legacy-NULL audit tail described in `lib/bank_web/live/security_live.ex:425-437` stays as-is; new pause events are workspace-stamped via the envelope passthrough from day one and require no historical fix.
- **Replacing `RateLimit.ChainAction`.** That plug stays exactly as it is.

## 4. Option comparison

### Option A — Tuple-based `PauseState` extension (in-memory)

Extend the existing `scope` type to:

```elixir
@type scope ::
        :global
        | {:counterparty, String.t()}
        | {:chain, String.t()}
        | {:api_key, String.t()}
        | {:smart_account, String.t()}
```

Add map slots in `PauseState`'s state (`%{global, counterparties, chains, api_keys, smart_accounts}`).

**Pros**

- Smallest diff. Reuses the existing GenServer, the existing audit emit (`security.paused` / `security.resumed`), the existing PubSub broadcast (`Bank.Runtime.broadcast_security_event/2`).
- Idempotency, inheritance ("global pause wins"), and the snapshot shape transfer for free.
- Test surface barely grows.

**Cons**

- **Not durable.** A control-plane restart drops every chain / key / smart-account pause. For a per-chain pause that an operator set during an active incident, that is unacceptable — the moment Phoenix restarts the runtime quietly resumes all chains. The existing `:global` and `:counterparty` scopes are tolerable as in-memory because of the docstring's "re-pause on restart" doctrine, but applying that to ten-plus per-resource pauses is operationally untenable.
- **No native workspace boundary.** Tuple keys are flat; preventing workspace A's `{:chain, "base"}` from leaking into workspace B's view requires a parallel workspace-scoping table or shoehorning into the tuple (`{:chain, ws_id, "base"}` — ugly).
- No `expires_at`, no `created_by`, no `status` field as #228 demands; the in-memory record map (`lib/bank/security/pause_state.ex:33-38`) has only `paused_at`, `reason`, `actor`, `actor_id`.

### Option B — DB-backed `pauses` table (durable)

Single polymorphic `pauses` table mirroring the `agent_keys_paused_at` precedent but generalized. Schema sketch in §6.

**Pros**

- **Durable across restart.** Survives deploys, control-plane crashes, and multi-node rollouts (when those land).
- Maps 1:1 onto #228's required attribute list (`scope_type`, `scope_value`, `reason`, `created_by`, `expires_at`, `status`).
- Native `workspace_id` column → cross-workspace isolation at the query layer; mirrors the rest of the codebase's #158 scoping pattern.
- Idempotency via partial unique index on `(scope_type, scope_value, status='active')`.
- Audit + replay parity with `agent_keys.*` (workspace-stamped, idempotent emission).

**Cons**

- More moving pieces: migration, schema module, context functions, tests.
- Hot-path lookup cost: `RunExecution`'s pause check goes from in-memory `:ets`/GenServer to a SELECT. Mitigated with a per-process cache or a small `:ets` projection refreshed via PubSub on `pauses.changed` (proposed in §6).
- Inherits all DB-migration discipline: the column stays nullable, the unique index is partial, the rollout is incremental (§5).

### Option C — Hybrid

Keep `PauseState` in-memory for `:global` (the panic lever — must respond instantly, must survive only at GenServer scope) and short-window emergency overrides; put per-resource pauses (chain, key, smart account, eventually counterparty) in DB.

**Pros**

- `:global` keeps its sub-millisecond panic posture and the existing "re-pause on restart" doctrine that the security context already documents.
- Per-resource pauses get durability where it matters.

**Cons**

- Two code paths. Every reader (`Security.paused?/1`) has to consult both. Two audit emit shapes risk drifting.
- The simplification value of "one model, one table, one read" is gone.
- The same hot-path concern as Option B for the DB pauses, plus an in-memory consult for `:global`.

### Comparison table

| Axis | A: in-memory tuples | B: DB table | C: hybrid |
| --- | --- | --- | --- |
| Durable across restart | No | Yes | Partial (per-resource only) |
| Workspace isolation | Awkward (tuple key) | Native (column) | Mixed |
| Matches #228 attribute list | Partial | Full | Full (per-resource side) |
| `expires_at` / auto-resume | No | Yes (DB job) | Yes (per-resource side only) |
| Hot-path read cost | GenServer call | DB read or `:ets` projection | Both |
| Migration footprint | None | One nullable table | One nullable table |
| Multi-node ready | No | Yes | Partial |

## 5. Recommended option + phased rollout

**Recommendation: Option B with a small in-memory projection for hot-path reads.**

The durability and workspace-isolation arguments are decisive; the hot-path concern is solvable with a `:ets`-backed read-through cache invalidated on PubSub `pauses.changed` events. `:global` and `{:counterparty, id}` stay where they are in `PauseState` for v0.1 — this memo does **not** propose collapsing those into the new table — but the new scope shapes (chain, api_key, smart_account) all land in the DB.

### Phased rollout

Each phase is its own PR. None depends on a later phase.

#### Phase 1 — Per-chain pause (smallest blast radius)

**Why first.** `chain` is already a domain-modeled string column on every relevant business row (`AgentIntent.chain`, `lib/bank/intents/agent_intent.ex:68`; `ExecutionPlan.chain`; `Delegation.chain`, `lib/bank/delegations/delegation.ex:97`). Gating on it is a one-clause addition to `validate_not_paused/0` (`lib/bank/decisions.ex:1322`) and a one-clause addition to `RunExecution.verify_not_paused/1` (`lib/bank/runtime/workers/run_execution.ex:188`). No new tables in the dispatch path; the gate consults the same `pauses` table introduced in this phase. Operator surface in `SecurityLive` is a new card alongside the existing runtime card.

#### Phase 2 — Per-smart-account pause

Builds on the same `pauses` table. Gate is in `validate_delegation_active/1` at `lib/bank/decisions.ex:1330` and in `RunExecution.verify_delegation/1` at `lib/bank/runtime/workers/run_execution.ex:162` — both see `smart_account_id` already. UI is a per-delegation-row pause toggle in the existing delegations card (`lib/bank_web/live/security_live.ex:1138`).

#### Phase 3 — Per-agent-key pause

Last because it interacts with the auth-plug fast path (`VerifyAPIKey`) and the per-key rate-limit telemetry (`Bank.RateLimit`, `lib/bank/rate_limit.ex`). Adds a check after the existing workspace-paused branch (`lib/bank/api_keys.ex:453`); maps to the existing `:workspace_paused`-style 401 envelope (`{:error, :api_key_paused}` collapsing to the same wire response). UI is a per-key pause toggle in the API-keys management surface (a separate epic; this phase only adds the model + gate).

The dependency graph is **flat**: phases 1, 2, 3 share the `pauses` table introduced in phase 1 and otherwise touch independent gate sites. Phase 1 ships first because chain pause has the lowest UI-coupling cost.

## 6. Data model sketch

```elixir
# Migration (mix ecto.gen.migration create_pauses):
create table(:pauses, primary_key: false) do
  add :id, :binary_id, primary_key: true

  # Discriminator. Stored as text; Ecto.Enum handles the mapping in
  # the schema module. Starts {chain, smart_account, api_key} in
  # phase 1; counterparty / global may be ported later but not in
  # this issue.
  add :scope_type, :text, null: false
  add :scope_value, :text, null: false   # chain id, smart_account_id, api_key.id

  # Nullable workspace_id — mirrors agent_keys_paused on workspaces.
  # Per-chain pauses are workspace-scoped; one workspace pausing Base
  # cannot block a sibling workspace.
  add :workspace_id, references(:workspaces, type: :binary_id,
       on_delete: :nilify_all), null: true

  add :reason, :text, null: true
  add :created_by_user_id, references(:users, type: :binary_id,
       on_delete: :nilify_all), null: true

  add :paused_at, :utc_datetime_usec, null: false
  add :resumed_at, :utc_datetime_usec, null: true
  add :expires_at, :utc_datetime_usec, null: true

  # Active = paused_at IS NOT NULL AND resumed_at IS NULL AND
  # (expires_at IS NULL OR expires_at > now). Stored as a generated
  # / computed column would be ideal; for now it is implicit in the
  # status query helper and reasserted by the partial index below.
  timestamps(type: :utc_datetime_usec)
end

# At-most-one active pause per (scope_type, scope_value, workspace_id)
create unique_index(
  :pauses,
  [:scope_type, :scope_value, :workspace_id],
  where: "resumed_at IS NULL",
  name: :pauses_active_uniq
)

# Hot-path lookup — gate sites query (workspace_id, scope_type, scope_value)
create index(:pauses, [:workspace_id, :scope_type, :scope_value])
```

**Nullable-first commitment.** Every column except `id`, `scope_type`, `scope_value`, `paused_at`, and the timestamps is nullable. No NOT NULL is added. The migration creates a brand-new table — it does not alter any existing table — so #228 cannot regress any other feature's row-level invariants.

**Schema module** (`Bank.Security.Pause`) declares `scope_type` as `Ecto.Enum, values: [:chain, :smart_account, :api_key]` and exposes `active?/1` derived from the three columns. A `Bank.Security.Pauses` context owns the CRUD: `create_pause/1`, `resume/2`, `list_active/1`, `paused?/3`. The existing `Bank.Security` module gets one new clause per scope inside `pause/2` and `resume/2` that delegates to the new context for non-`:global`, non-`:counterparty` scopes; the GenServer is left alone.

**Hot-path read.** A small `:ets` projection (e.g. `:bank_pauses_active`) refreshed by a `Bank.Runtime.PubSub` subscriber on `security:events` keeps `RunExecution.verify_not_paused/1`'s read at single-digit microseconds. Cache-miss falls through to `Bank.Security.Pauses.paused?/3`. The fail-closed contract is preserved: a stale projection never falsely admits a paused scope (each phase's tests prove this with a deliberate cache-skew case).

## 7. Auth / RBAC

| Scope | Pause role | Resume role | Browser deny | API deny |
| --- | --- | --- | --- | --- |
| `:chain` (phase 1) | `:admin` (workspace-scoped) | `:admin` (workspace-scoped) | LiveView refuses; flash + 200 | `403 forbidden` |
| `:smart_account` (phase 2) | `:admin` (workspace-scoped) | `:admin` (workspace-scoped) | LiveView refuses; flash + 200 | `403 forbidden` |
| `:api_key` (phase 3) | `:admin` (workspace-scoped) | `:admin` (workspace-scoped) | LiveView refuses; flash + 200 | `403 forbidden` |

Everything mirrors the existing `Security.pause(:global, ...)` flow in `BankWeb.SecurityLive.handle_event("pause_runtime", ...)` (`lib/bank_web/live/security_live.ex:108-121`) and the agent-keys handler (`lib/bank_web/live/security_live.ex:218-254`): `BankWeb.LiveAuth.authorize_action(socket, :admin)` for browser, `BankWeb.Plugs.RequireRole, :admin` for API. **A paused scope NEVER locks the operator out of the resume path** — `/security` is reachable through Google OAuth + Plug session, not API-key auth (`lib/bank/api_keys.ex:152-156`). This rule transfers from the agent-keys precedent unchanged.

API endpoints `POST /v1/security/pause_chain`, `POST /v1/security/resume_chain`, etc., go through `BankWeb.Plugs.RateLimit.ChainAction` (`lib/bank_web/plugs/rate_limit/chain_action.ex:19-26` already lists the new families as routes covered).

## 8. Audit events

**Recommendation: unified event names with a `subject_type` discriminator** — `security.scope_paused` / `security.scope_resumed` with `subject_type ∈ {"chain", "smart_account", "api_key"}` and `subject_id` carrying the scope value.

**Why unified.** The existing `security.paused` / `security.resumed` already use `subject_type` to discriminate (`"runtime"` vs `"counterparty"`, `lib/bank/security.ex:265-266`). Splitting per-kind (`security.chain_paused`, `security.smart_account_paused`, `security.api_key_paused`) explodes the safety-event allowlist in `BankWeb.SecurityLive` (`lib/bank_web/live/security_live.ex:52-66`) from 6 entries to ~12, doubles the test matrix, and forces consumers (replay, ops dashboards) to learn a per-resource taxonomy. The discriminator pattern was already chosen for `api_key.rate_limited` with `after_ref.scope ∈ {key, workspace, chain_action}` (`lib/bank/audit/events.ex:1218-1238`) precisely to avoid this fan-out.

Concretely we introduce two new `Bank.Audit.Events` builders:

```elixir
def security_scope_paused(%Pause{} = pause, opts), do: %{
  actor: :user, actor_id: ..., event_type: "security.scope_paused",
  subject_type: pause.scope_type |> to_string(),
  subject_id: pause.scope_value,
  correlation_id: nil,
  before_ref: %{paused_at: nil},
  after_ref: %{paused_at: pause.paused_at, reason: pause.reason,
               expires_at: pause.expires_at,
               created_by_user_id: pause.created_by_user_id},
  workspace_id: pause.workspace_id
}

def security_scope_resumed(%Pause{} = pause, prior, opts), do: # mirror
```

The existing `security.paused` / `security.resumed` events for `:global` and `:counterparty` are **NOT renamed** — they stay as the canonical events for those two scopes. The new event names cover only the scopes introduced by this issue.

## 9. UI impact

`BankWeb.SecurityLive` (`lib/bank_web/live/security_live.ex`) gains:

- **Per-chain pause card** in the left column (phase 1), placed between `agent_keys_card` (`lib/bank_web/live/security_live.ex:615`) and `risk_summary_card` (`lib/bank_web/live/security_live.ex:621`). Lists each chain the workspace has touched (derived from active delegations, `lib/bank/delegations/delegation.ex:97`), shows pause/active state, with a per-chain Pause/Resume button under the same admin gate as the runtime card.
- **Per-row pause toggle** added to `delegations_card` (phase 2, `lib/bank_web/live/security_live.ex:1138-1207`), beside the existing Revoke button.
- **Per-key pause toggle** appears in the future API-keys management surface (phase 3); SecurityLive surfaces only the count of currently paused keys in `risk_summary_card`.
- **Aggregate badge** on the page header: `n` non-global scopes paused. Not a new card — augments the existing `posture_banner/1` (`lib/bank_web/live/security_live.ex:652-731`) so the operator sees "runtime running, but 2 scoped pauses active".
- **Safety timeline** (`load_safety_events/3`, `lib/bank_web/live/security_live.ex:449`) gains `"security.scope_paused"` and `"security.scope_resumed"` in `@safety_event_types` (`lib/bank_web/live/security_live.ex:52`). `visible_to_workspace?/3` adds a clause matching on `event.workspace_id == ws_id` for these (mirrors the existing `ops.stuck_plan_detected` clause at `lib/bank_web/live/security_live.ex:574-580`).

No new card replaces an existing one. The runtime card and agent-keys card stay exactly as they are.

## 10. Migration / backfill safety

Explicit commitments enforced in every phase's PR:

- **No NOT NULL adds.** The `pauses` table is created from scratch; the only `null: false` columns are `id`, `scope_type`, `scope_value`, `paused_at`, `inserted_at`, `updated_at`. `workspace_id` is nullable for the same reason `agent_keys_paused_at` is on `workspaces`: an in-progress migration must never refuse a write because of a missing-tenant case.
- **No production backfill.** The table starts empty. There is no historical pause state to import. (The `:global` and `{:counterparty, id}` rows in `PauseState` stay where they are; this issue does not migrate them.)
- **Migration generated via `mix ecto.gen.migration`** per AGENTS.md.
- **Reversible.** The `down/0` clause drops the table and indexes; nothing else is touched.
- **Index discipline.** The active-pause partial unique index is created in the same migration. The hot-path index is included so the first deploy does not see a DB-scan regression on `paused?/3`.

## 11. Tests

Each phase's PR ships:

- **Context tests** (`Bank.Security.Pauses` / extended `Bank.Security`):
  - happy path pause/resume per scope, idempotent re-pause, idempotent re-resume,
  - expired pause auto-clears (phase 1: deferred to a follow-up worker; the schema column lands now, the auto-resume worker is its own slice),
  - the partial unique index races (two concurrent pauses on the same scope, one wins).
- **Controller tests** (`/v1/security/pause_chain`, `/resume_chain`, etc.):
  - `:admin` admits, `:operator` 403, `:viewer` 403,
  - cross-workspace boundary: workspace A's admin cannot pause workspace B's chain (the controller resolves `current_scope.workspace_id` and the context refuses anything else),
  - rate-limit headers on the chain-action plug.
- **LiveView tests** (`SecurityLiveTest`):
  - per-scope card renders; pause button gated by `:admin`,
  - non-admin sees a read-only panel,
  - safety timeline includes the new event names.
- **Audit hygiene tests** (`AuditEventsTest`):
  - `after_ref` for the new builders carries no secret-bearing fields,
  - workspace_id is stamped, actor + actor_id present, idempotent emission proven against the unique-index dedupe.
- **Cross-workspace isolation tests** (per #158 doctrine; `lib/bank/api_keys.ex:541-554` sets the precedent):
  - workspace A reads of `Pauses.list_active/1` MUST NOT surface workspace B's pauses,
  - workspace A's `paused?/3` MUST NOT consult workspace B's rows.
- **Dispatch-gate tests** (per phase):
  - phase 1: `RunExecution` aborts a `:base` plan when `{:chain, "base"}` is paused,
  - phase 2: `RunExecution` aborts a plan whose `smart_account_id` is paused,
  - phase 3: `VerifyAPIKey` rejects a paused key with the `:api_key_paused` reason mapping to the same generic 401 envelope used today.
- `mix precommit` per AGENTS.md.

## 12. Rollout phases (dependency graph)

```
Phase 1 (chain pause) ──┐
                        ├── all share the new pauses table + Bank.Security.Pauses context
Phase 2 (sa pause) ─────┤
                        │
Phase 3 (key pause) ────┘
```

No phase blocks another. Phase 1 ships first because it has the smallest UI coupling and the tightest test surface. Each phase is OpenAPI-required (new `/v1/security/*` endpoints), so each PR follows the parent epic's OpenAPI discipline — schemas, registry, regenerated `priv/openapi/openapi.json`, `mix openapi.check`.

## 13. What NOT to touch yet

Listed for explicitness so review can flag scope creep:

- **Chain adapter internals.** The TS adapter side, the contract in `priv/adapter/contract.md`, `Bank.AdapterClient.dispatch_transfer/1`, and the broadcast/signing path stay untouched. Pause operates strictly at the Phoenix dispatch gate.
- **`.env`, Sepolia, mainnet, network rotation.** Out of scope; this is a control-plane gate.
- **#158e workspace_id audit backfill.** The legacy-NULL audit tail (`lib/bank_web/live/security_live.ex:425-437`) is not addressed here. New `security.scope_paused` events stamp `workspace_id` from day one.
- **`Bank.RateLimit` and `BankWeb.Plugs.RateLimit.ChainAction`.** Different concern (throttling vs pausing). The chain-action plug already covers the new `/v1/security/pause_chain` family by route prefix; no plug changes are needed beyond adding the routes themselves.
- **`PauseState` GenServer durability.** Out of scope. The existing `:global` and `{:counterparty, id}` scopes stay in-memory; their persistence is a separate v1.0 follow-up already documented in the module (`lib/bank/security/pause_state.ex:5-13`). This memo only adds DB-backed scopes alongside.
- **Auto-resume / `expires_at` worker.** The schema lands the column now (§6); the periodic worker that flips active → resumed when `expires_at < now` is a distinct slice, deliberately decoupled from the scope rollout so a test of `expires_at` enforcement does not gate phase 1 from shipping.
