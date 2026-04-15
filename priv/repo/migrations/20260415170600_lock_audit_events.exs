defmodule Bank.Repo.Migrations.LockAuditEvents do
  @moduledoc """
  DB-level safeguard that rejects any `UPDATE` or `DELETE` on
  `audit_events`. The app-level `Bank.Audit` API never exposes a
  mutation path, but a stray `Repo.update/1` or a psql session with
  admin creds would otherwise be able to tamper with the audit trail.
  A trigger that raises an exception on those operations turns any
  accidental mutation into a loud failure.

  Kept narrow on purpose: no audit-of-audit table, no checksums, no
  row-version counters. Those belong to a future integrity-anchoring
  pass.
  """

  use Ecto.Migration

  def up do
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

    execute("""
    CREATE TRIGGER audit_events_no_update
    BEFORE UPDATE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION audit_events_reject_mutation();
    """)

    execute("""
    CREATE TRIGGER audit_events_no_delete
    BEFORE DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION audit_events_reject_mutation();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS audit_events_no_update ON audit_events;")
    execute("DROP TRIGGER IF EXISTS audit_events_no_delete ON audit_events;")
    execute("DROP FUNCTION IF EXISTS audit_events_reject_mutation();")
  end
end
