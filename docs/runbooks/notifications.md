# Notifications — operator runbook

This runbook is the operator-facing reference for the in-app **notification inbox** (issues #233–#237). It tells a fresh reviewer what notifications are, what is and is not implemented today, and how to verify the surfaces locally without secrets, without `.env`, and without any chain broadcast.

> **Audience.** Operators, alpha reviewers, and anyone wiring decision / execution / access events into the inbox. The notification surface is a passive **operator UI hook** — *not* an alerting service, *not* a paging integration, *not* a substitute for the audit log.

## What notifications are

A notification is a workspace-scoped row in the `notifications` table that captures one operator-actionable event in a small, redacted, deterministic shape. Notifications are produced by `Bank.Notifications.Emitter.*` after a domain transaction commits and persisted via `Bank.Notifications.create/1`.

Three modules cooperate today:

1. **[`Bank.Notifications`](../../lib/bank/notifications.ex)** (#233) — inbox CRUD: `create/1`, `list_for_workspace/2`, `list_for_user/3`, `get_in_workspace/2`, `mark_read/2`, `archive/2`. The `create/1` boundary runs a closed secret-marker gate over `title`, `body`, and `action_link`, so the inbox cannot accept rows containing `Authorization:`, `Bearer …`, `sk_(test|live)_…`, PEM private-key markers, or `private_key=…` shapes.
2. **[`Bank.Notifications.Emitter`](../../lib/bank/notifications/emitter.ex)** (#234, partial) — domain-side emitters that run after a transaction commits and call `Notifications.create/1` with a deterministic `dedupe_key`. The post-commit posture means a notification-side failure cannot roll back the underlying state transition.
3. **[`Bank.Notifications.Deliveries`](../../lib/bank/notifications/deliveries.ex)** (#236) — preferences (per-workspace per-target per-channel) and per-channel delivery state rows that record attempts toward external channels.

Each notification carries a workspace boundary (`workspace_id`) and exactly one recipient address: either `user_id` (one specific user) or `role_target` (every member with that role).

## Implemented event types

The table below lists every event type the runtime emits **today**. New emitters land in follow-up issues; do not assume an event type exists in the table without checking `lib/bank/notifications/emitter.ex` first.

| Event type | Trigger (source path) | Severity | Recipient | Action link |
|---|---|---|---|---|
| `decision.approval_required` | `Bank.Decisions.evaluate_intent/3` outcome `:approval_required` | `:warning` | role `:operator` | `/queue#pending-approvals-section` |
| `decision.hold` | `Bank.Decisions.evaluate_intent/3` outcome `:hold` | `:warning` | role `:operator` | `/queue#held-actions-section` |
| `decision.block` | `Bank.Decisions.evaluate_intent/3` outcome `:block` | `:critical` | role `:operator` | `/queue#held-actions-section` |
| `execution.reverted` | `Bank.Decisions.apply_execution_callback/1` `:reverted` terminal | `:critical` | role `:operator` | `/audit/replay/<intent_id>` |
| `execution.aborted` | `Bank.Decisions.apply_execution_callback/1` `:aborted` terminal | `:warning` | role `:operator` | `/audit/replay/<intent_id>` |
| `execution.confirmed` | `Bank.Decisions.apply_execution_callback/1` `:confirmed` terminal | `:info` | role `:operator` | `/audit/replay/<intent_id>` |
| `access.approved` | `Bank.Access.approve_pending_user/3` membership upsert | `:info` | user `user_id` (the newly admitted user) | `/dashboard` |
| `security.scope_paused` | `Bank.Security.Pauses.create_pause/4` real `:paused` transition | `:warning` | role `:operator` | `/security` |
| `security.scope_resumed` | `Bank.Security.Pauses.resume/4` real `:resumed` transition | `:info` | role `:operator` | `/security` |

`decision.auto_exec` is intentionally **silent** — operators do not need an inbox row for the happy path.

`execution.confirmed` is **opt-in per workspace**. The emitter (`Bank.Notifications.Emitter.emit_execution_outcome/1`) only writes a row when the workspace's `notify_execution_confirmed` flag is `true`; the flag defaults to `false`, so a workspace that has not opted in keeps the silent-on-success posture. Admins flip the flag with `Bank.Workspaces.set_notify_execution_confirmed/2`. `:reverted` and `:aborted` are always emitted regardless of the flag.

## Severity vocabulary

The closed enum is `[:info, :warning, :critical]` (in `lib/bank/notifications/notification.ex`). Meaning:

- `:info` — operator-friendly state change. Not actionable; appears in the inbox to confirm something happened (e.g. "you've been added to a workspace").
- `:warning` — operator action expected. The runtime's safety rails fired but did not refuse outright. Most decision-side rows live here.
- `:critical` — terminal failure or hard refusal. On-chain reversion, internal allowlist breach, or trust-engine block. Operators should triage these first.

## Inbox usage

Operators interact with notifications through three surfaces:

1. **Operator inbox UI** — `GET /inbox` (`BankWeb.OperatorInboxLive`) lands every member of the workspace at their visible inbox view. Rows targeted to your `user_id` show alongside rows targeted to a role you hold.
2. **Mark read / archive** — `Bank.Notifications.mark_read/2` flips `:unread` → `:read` and stamps `read_at`; `Bank.Notifications.archive/2` flips to `:archived` and stamps `archived_at`. Both are idempotent and stale-struct-safe (the conditional `update_all` guard from #233 P2 means a stale in-memory struct cannot regress an archived row back to `:read`).
3. **Programmatic listing** — `Bank.Notifications.list_for_workspace/2` returns the workspace inbox newest-first. `:status` filter accepts `:unread | :read | :archived` (single, list, or `:all`); `:event_type`, `:severity`, `:user_id`, `:role_target` filters compose.

The notification body is intentionally small. Anything richer than a one-line "what happened + click here" lives behind `action_link` on the operator page (queue, replay, dashboard) the link points to.

## Delivery preferences

The `notification_delivery_preferences` table (#236) is the per-workspace per-target per-channel opt-in for *external* channels. The in-app inbox row is always written; external delivery is opt-in.

External channels today: `:email`, `:webhook`, `:telegram`. Every channel currently routes to **`Bank.Notifications.Channel.Stub`** (`lib/bank/notifications/channel/stub.ex`), a no-op module that returns `{:ok, %{provider: "stub"}}` deterministically. **Real SMTP / webhook HTTP / Telegram clients are not yet implemented** — they are explicit non-goals of #236 and land in follow-up issues. The runbook does not promise external delivery beyond the stub.

`Bank.Notifications.Deliveries.set_preference/1` upserts a row. Idempotent: repeat calls update `min_severity` / `enabled` in place. Targeting is XOR — a preference row carries either `user_id` OR `role_target`, never both.

```elixir
# Operator opt-in: deliver every :warning-and-above decision
# row to email, for every member who holds the :operator role.
Bank.Notifications.Deliveries.set_preference(%{
  workspace_id: ws.id,
  role_target: :operator,
  channel: :email,
  min_severity: :warning,
  enabled: true
})
```

`Bank.Notifications.create/1` calls `Deliveries.dispatch_after_create/1` post-commit. That hook resolves `enabled_channels_for/1` (user-targeted preferences first, then role-targeted, then OFF) and creates one `notification_deliveries` row per enabled channel. The hook is **best-effort**: a preference-side failure cannot break the inbox-row write. The inbox row therefore always survives even if every external channel is broken — the issue's "in-app notification still exists even if external delivery fails" acceptance bullet (#236).

## Delivery state machine

Each row in `notification_deliveries` (#236) carries a closed status enum:

```
:queued          → :delivering → :delivered
                              → :failed → … → :permanently_failed
```

- `:queued` — waiting for the worker.
- `:delivering` — in flight (the worker holds the row lock).
- `:delivered` — terminal success.
- `:failed` — transient failure; the row's `next_attempt_at` is the earliest retry time, computed via exponential-with-cap backoff (2^attempts × 30s, capped at 1h).
- `:permanently_failed` — terminal failure: hit `max_attempts` (default 5) OR the channel returned a `{:permanent_error, code}` short-circuit.

`last_error` is a closed atom enum: `:transport_error`, `:provider_5xx`, `:provider_4xx`, `:provider_timeout`, `:malformed_payload`, `:rate_limited`, `:unknown`. The column is **never** a free-text reason — pinned by tests, ensures secret hygiene at the column level.

`Bank.Notifications.Deliveries.attempt_delivery/2` is the single entry point that drives transitions. It opens a transaction, locks the row with `FOR UPDATE`, reloads the current status, and **short-circuits on terminal rows** (`:delivered` or `:permanently_failed`) without calling the channel module. A stale caller cannot regress a terminal row — the #236 P2 terminal-state guard is pinned by tests in `test/bank/notifications/deliveries_test.exs`.

## Run the automated smoke

For a non-interactive pass/fail signal that the whole notifications pipeline is wired correctly, run:

```sh
mix bank.notifications.smoke
```

The task exercises every notification surface against the seeded `sandbox-demo` workspace and prints a per-check report:

1. `seed_intents` — confirms the demo intents `partner-x-pending-approval` and `treasury-held` are present.
2. `operator_preferences` — upserts the `:operator + :email` and `:operator + :webhook` preferences with `min_severity: :warning`.
3. `emit_approval_required` — calls `Bank.Notifications.Emitter.emit_decision_outcome/2` with the seeded approval intent + envelope and asserts the inbox row landed.
4. `emit_hold` — same for the seeded hold intent.
5. `mark_read` — flips the approval inbox row to `:read`.
6. `archive` — flips the hold inbox row to `:archived`.
7. `delivery_preference_dispatch` — confirms the post-create hook lands one delivery row per enabled channel.
8. `delivery_attempt_success` — configures the stub to `{:ok, _}` and runs `attempt_delivery/2`; asserts `:delivered` (or terminal-state no-op on re-run).
9. `delivery_attempt_transient_failure` — configures the stub to `{:error, :transport_error}` and runs `attempt_delivery/2` against the queued webhook delivery; asserts `:failed` with `attempts >= 1` and `next_attempt_at` scheduled (or `:permanently_failed` if a prior run already burned through the cap).
10. `secret_hygiene` — scans every emitted row's `title`, `body`, `action_link`, `dedupe_key` and every delivery row's `last_error` for the same secret-marker family the inbox row's create changeset already rejects (`Authorization`, `Bearer`, `sk_(test|live)_`, PEM markers, `private_key`).

The smoke is **read-mostly with respect to the world outside the sandbox-demo workspace**:

- The database is the only external dependency.
- No `.env` / no environment variables read.
- No HTTP to the chain adapter (`Bank.AdapterClient` is never called).
- No real RPC, no signing, no broadcast, no dispatch.
- No real SMTP / webhook / Telegram — the channel stub returns deterministic results.
- No Oban jobs are enqueued.

Within the demo workspace the smoke writes inbox rows and delivery rows for the seeded intents. Re-runs are idempotent: the inbox row's `(workspace_id, dedupe_key)` unique constraint, the delivery row's `(notification_id, channel)` unique constraint, and the `attempt_delivery/2` terminal-state guard from #236 P2 collapse repeats.

Exits 0 on PASS and 1 on FAIL so a CI step can pick up the outcome without parsing stdout.

If the demo workspace has not been seeded yet, the runner short-circuits with a single `seed`-failure check pointing the operator at `mix bank.demo.seed`.

## Troubleshooting

### A notification did not land

1. Confirm the underlying domain transaction committed. The emitter runs **post-commit** — if the transaction rolled back, no inbox row will exist.
2. Confirm the source path is one of the implemented event types listed above. Other events (e.g. stale quote / provider failures, Morpho severe warnings) are explicit #234 follow-ups and do not write inbox rows yet. For `execution.confirmed` specifically, also confirm the workspace's `notify_execution_confirmed` opt-in is `true`; the default is `false`, so a workspace that has not opted in will not see success-side rows even though the emitter is implemented.
3. The notification's `dedupe_key` is `"<source_path>:<deterministic_id>:<outcome>"` (e.g. `decision:<intent_id>:approval_required`). A second emit with the same key returns `{:duplicate, existing}` — that is correct dedupe, not a bug. Check `Bank.Notifications.list_for_workspace/2` for a row with the matching `correlation_id`.

### A delivery row stuck in `:queued`

1. The Oban-driven delivery worker is not yet implemented (#236 follow-up). For now, deliveries only transition when an operator runs `mix bank.notifications.smoke` or calls `Deliveries.attempt_delivery/2` directly. Queued rows accumulating is expected behaviour pre-worker.
2. Confirm a preference for the row's channel exists and is `enabled: true`. The preference's `min_severity` must be at or below the notification's severity for the row to have been queued in the first place.

### A delivery row stuck in `:failed`

1. `next_attempt_at` is the earliest retry time. Until that timestamp is in the past, the future Oban worker will skip the row.
2. `attempts` ≥ `max_attempts` (default 5) flips the row to `:permanently_failed` on the next attempt. Inspect `last_error` for the closed-enum failure code.
3. Operators can manually re-attempt by calling `Deliveries.attempt_delivery/2` after fixing the channel-side issue (e.g. a transient network blip). The function is safe to re-run — the terminal-state guard from #236 P2 prevents double-delivery.

### A delivery row stuck in `:permanently_failed`

The row is terminal. `attempt_delivery/2` is a no-op against it (returns `{:ok, current}` without calling the channel module). Operators who need to retry must create a new delivery row by re-emitting the parent notification (which will dedupe at the inbox level — a fresh `(notification_id, channel)` pair is the only way to start over).

## Limitations and provenance

- **No real external channels yet.** Email / webhook / Telegram all route to `Bank.Notifications.Channel.Stub`. The runbook does not promise SMTP, HTTP, or Telegram delivery; the `Channel` behaviour is the foundation that future channel implementations attach to.
- **No Oban delivery worker yet.** Deliveries transition only when `attempt_delivery/2` is called (today, by the smoke task or a follow-up Oban worker). The state machine + retry math + terminal guard are all in place; the shell that walks `status: :queued AND next_attempt_at <= now()` lands in a follow-up.
- **No external-channel preferences UI yet.** Operators set preferences via `Deliveries.set_preference/1` (or a future operator-tier admin form). The inbox UI (#235) lists notifications but does not currently expose channel preference editing.
- **Workspace boundary is enforced everywhere.** Every row in `notifications`, `notification_delivery_preferences`, and `notification_deliveries` carries `workspace_id`; cross-workspace lookups return empty. No row can be addressed across workspaces by accident.
- **No secrets in payload.** `Bank.Notifications.create/1` rejects rows whose `title` / `body` / `action_link` match the closed secret-marker family. `Channel.payload_for/1` exposes only seven controlled fields. `notification_deliveries.last_error` is a closed atom enum. The smoke's `secret_hygiene` check scans every row to pin the contract.

## Verification (what `mix precommit` covers)

The shipped surfaces this runbook describes are pinned by:

- `test/bank/notifications_test.exs` — inbox CRUD, dedupe semantics, secret-marker gate, status state transitions.
- `test/bank/notifications/emitter_test.exs` — per-source-path emitter shape, deterministic dedupe keys, severity mapping.
- `test/bank/notifications/deliveries_test.exs` — preference upsert, channel resolution, post-create enqueue, attempt machinery, retry math, terminal-state guard (#236 P2).
- `test/bank/notifications/smoke_test.exs` — `mix bank.notifications.smoke` runner happy path and side-effect contract.

Run them as part of the pre-merge gate:

```sh
mix precommit
```

A green `mix precommit` plus a green `mix bank.notifications.smoke` on a fresh seed is the success signal for this runbook.
