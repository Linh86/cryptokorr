defmodule Bank.Repo.Migrations.CreateAuditEvents do
  @moduledoc """
  Audit events — append-only, the single shared contract for replay.

  This migration creates the table and the read-path indexes required
  by the `/v1/audit` filter surface and the `/v1/intents/:id/replay`
  bundle. It deliberately does *not* build the writer pipeline,
  integrity anchoring, or PubSub fan-out — that is issue #5.

  Immutability conventions:

    * no `updated_at` — this table is insert-only.
    * no in-place edits. Correction happens by writing a new event
      that references the prior one via `before_ref` / `after_ref`.

  Polymorphic subject: `subject_type` is a free string (e.g.
  `"agent_intent"`, `"decision_envelope"`) and `subject_id` is a plain
  uuid column, no FK. Correlating events back to a full object takes a
  separate read against the owning context.
  """

  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :ts, :utc_datetime_usec, null: false, default: fragment("now()")
      add :actor, :text, null: false
      add :actor_id, :text
      add :event_type, :text, null: false
      add :subject_type, :text, null: false
      add :subject_id, :binary_id, null: false
      # Typically the intent_id; optional for runtime/system events
      # that are not tied to a specific intent (pause / revoke).
      add :correlation_id, :binary_id
      add :before_ref, :map
      add :after_ref, :map
      add :payload_hash, :text, null: false
      add :schema_version, :text, null: false, default: "1"

      timestamps(updated_at: false)
    end

    create constraint(:audit_events, :actor_valid,
             check: "actor IN ('user','agent','runtime','adapter')"
           )

    # Subject drilldown: every lookup by object id is ordered newest-first.
    create index(:audit_events, [:subject_type, :subject_id, :ts])

    # Replay bundle read path: pull every event for an intent in order.
    create index(:audit_events, [:correlation_id, :ts])

    # Event-type time slices for the audit console.
    create index(:audit_events, [:event_type, :ts])
  end
end
