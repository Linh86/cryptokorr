defmodule Bank.Repo.Migrations.AllowAuditWorkspaceBackfill do
  @moduledoc """
  Narrow relaxation of the `audit_events_no_update` trigger from
  `20260415170600_lock_audit_events.exs`, scoped exclusively to the
  #158d-d backfill of `workspace_id`.

  ## Why

  `audit_events` is append-only at the SQL level: the existing
  trigger rejects every `UPDATE` and `DELETE` with a
  `read_only_sql_transaction` error. That guarantee is load-bearing
  for the audit-trail integrity story and must NOT be loosened in
  general. But #158a–c added a nullable `workspace_id` column that
  rows created before workspace scoping have left as `NULL`. Filling
  those NULLs in-place is the entire point of #158d-d's
  `Bank.Workspaces.Backfill`.

  ## What the new trigger function allows

  An `UPDATE` is permitted **only** when ALL of the following hold:

    * a session-local `bank.audit_workspace_backfill` setting is
      `'on'` (set per-batch by the backfill task — never by the
      runtime app),
    * the row's prior `workspace_id` was `NULL` (so the backfill
      can fill but never overwrite),
    * the new `workspace_id` is non-NULL (no churn writes),
    * every other authoritative column on the row is byte-for-byte
      unchanged: `id`, `ts`, `actor`, `actor_id`, `event_type`,
      `subject_type`, `subject_id`, `correlation_id`, `before_ref`,
      `after_ref`, `payload_hash`, `schema_version`,
      `inserted_at`. `before_ref` and `after_ref` are part of the
      canonical hash payload, so an out-of-band edit would already
      invalidate `payload_hash` on replay — locking them at the
      trigger as well is defense in depth so a corrupt row never
      lands in the first place.

  Any UPDATE that violates a single one of these constraints — and
  every DELETE — still raises the same
  `read_only_sql_transaction` exception. The integrity property is
  preserved: the audit body is immutable; only the read-hint
  workspace pointer can be filled exactly once per row.

  ## Operator surface

  The session-local setting is set with `SET LOCAL`, so it
  auto-clears at transaction commit/abort. There is no GUC default,
  no role-level grant, and no app-startup setter. The only writer
  that ever flips it is the backfill task; the test suite exercises
  it through `Bank.Workspaces.Backfill`.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION audit_events_reject_mutation()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE'
         AND current_setting('bank.audit_workspace_backfill', true) = 'on'
         AND OLD.workspace_id IS NULL
         AND NEW.workspace_id IS NOT NULL
         AND OLD.id = NEW.id
         AND OLD.ts = NEW.ts
         AND OLD.actor = NEW.actor
         AND OLD.actor_id IS NOT DISTINCT FROM NEW.actor_id
         AND OLD.event_type = NEW.event_type
         AND OLD.subject_type = NEW.subject_type
         AND OLD.subject_id IS NOT DISTINCT FROM NEW.subject_id
         AND OLD.correlation_id IS NOT DISTINCT FROM NEW.correlation_id
         AND OLD.before_ref IS NOT DISTINCT FROM NEW.before_ref
         AND OLD.after_ref IS NOT DISTINCT FROM NEW.after_ref
         AND OLD.payload_hash = NEW.payload_hash
         AND OLD.schema_version = NEW.schema_version
         AND OLD.inserted_at = NEW.inserted_at THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION
        'audit_events is append-only; % is rejected (schema-level safeguard)',
        TG_OP
        USING ERRCODE = 'read_only_sql_transaction';
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    # Revert to the original strict-deny trigger function. Triggers
    # themselves do not need to be recreated — `CREATE OR REPLACE
    # FUNCTION` swaps the body in place.
    execute("""
    CREATE OR REPLACE FUNCTION audit_events_reject_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION
        'audit_events is append-only; % is rejected (schema-level safeguard)',
        TG_OP
        USING ERRCODE = 'read_only_sql_transaction';
    END;
    $$ LANGUAGE plpgsql;
    """)
  end
end
