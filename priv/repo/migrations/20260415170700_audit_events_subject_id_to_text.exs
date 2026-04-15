defmodule Bank.Repo.Migrations.AuditEventsSubjectIdToText do
  @moduledoc """
  Relax `audit_events.subject_id` from a uuid column to a free-form
  text column.

  The audit trail is polymorphic: most subjects today are uuid-keyed
  domain rows (`agent_intent`, `decision_envelope`, ...), but some are
  not. A smart-account id is a short opaque string
  (e.g. `"sa-xyz"`); future on-chain subjects may use hex addresses.
  Keeping `subject_id` as a uuid column would force those emitters to
  invent a fake uuid or skip audit entirely — neither is acceptable.

  The widening is safe in-place: postgres casts the existing uuid
  values to their canonical text representation. The
  `(subject_type, subject_id, ts)` index is preserved automatically
  because a column-type alter keeps dependent indexes and rebuilds
  them when necessary.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE audit_events ALTER COLUMN subject_id TYPE text USING subject_id::text;")
  end

  def down do
    # The reverse cast only works if every stored subject_id is a
    # valid uuid. That will not be true once smart-account and on-chain
    # subjects land, so reverting is best-effort.
    execute("ALTER TABLE audit_events ALTER COLUMN subject_id TYPE uuid USING subject_id::uuid;")
  end
end
