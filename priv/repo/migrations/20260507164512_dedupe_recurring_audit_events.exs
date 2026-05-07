defmodule Bank.Repo.Migrations.DedupeRecurringAuditEvents do
  @moduledoc """
  SQL-level dedupe for the two recurring audit emitters whose
  idempotency previously rested on `concurrency: 1` Oban queues plus
  a per-row `Repo.exists?` pre-check (audit M8):

    * `Bank.Runtime.Workers.ScanStuckPlans` —
      `event_type = 'ops.stuck_plan_detected'`
    * `Bank.Runtime.Workers.AggregateAPIKeyUsage` —
      `event_type = 'api_key.used'`

  Both share the same dedupe shape: `(subject_id, after_ref->>'window_start')`
  per `event_type`. A manual back-fill paralleling cron breaks the
  pre-check (it is SELECT-then-INSERT, not atomic) — the new partial
  unique index makes the invariant structural so the workers can
  switch to `INSERT ... ON CONFLICT DO NOTHING`.

  ## Why a partial index

  `audit_events` is the firehose of every state transition; a unique
  index keyed on every row would pay an unnecessary insert cost for
  the >95% of event types that have no dedupe shape. Restricting the
  index to the two specific event types keeps the cost local to the
  emitters that need it.

  ## Append-only trigger compatibility

  The `audit_events_no_update` / `audit_events_no_delete` triggers
  installed by `LockAuditEvents` raise on UPDATE and DELETE
  respectively. `INSERT ... ON CONFLICT DO NOTHING` does NOT emit a
  no-op UPDATE — Postgres simply skips the conflicting row — so the
  triggers are not invoked. The append-only contract holds.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE UNIQUE INDEX audit_events_recurring_dedupe_idx
      ON audit_events (subject_id, (after_ref->>'window_start'))
      WHERE event_type IN ('ops.stuck_plan_detected', 'api_key.used');
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS audit_events_recurring_dedupe_idx;")
  end
end
