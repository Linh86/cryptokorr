defmodule Bank.Repo.Migrations.CreateAgentIntents do
  @moduledoc """
  Agent intents — the authoritative input record for the runtime.

  Idempotency: `(agent_id, idempotency_key)` is unique. A duplicate key
  with a matching payload returns the existing intent; a duplicate key
  with a mismatched payload returns `409`. `payload_hash` is the
  stored comparison target.

  Target expression: exactly one of `(target_counterparty_id,
  target_address_label_id)` or `target_raw_address` is set. A raw
  address always evaluates to trust `unknown`. Enforced by a CHECK
  constraint rather than relying only on app-layer validation so that
  invariants survive direct SQL.

  The `current_*_id` pointers at the bottom are cached references to
  the active decision / claim / simulation / plan for this intent and
  are added in a follow-on migration once those tables exist. Keeping
  them as plain uuid columns (no FK) avoids a circular table
  dependency; the invariant — "the pointer resolves to a live row that
  is itself the current record for this intent" — is upheld by the app
  in the same transaction that writes the new version.
  """

  use Ecto.Migration

  def change do
    create table(:agent_intents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, :text, null: false
      add :source, :text, null: false
      add :idempotency_key, :text, null: false
      add :payload_hash, :text, null: false

      add :kind, :text, null: false
      add :asset, :text, null: false
      add :chain, :text, null: false
      # numeric(38,18) covers 18-decimal token values well past any
      # realistic amount; keeps scale for wei-style units on other
      # chains if the runtime ever leaves Base.
      add :amount, :decimal, precision: 38, scale: 18, null: false

      add :target_counterparty_id,
          references(:counterparties, type: :binary_id, on_delete: :restrict)

      add :target_address_label_id,
          references(:address_labels, type: :binary_id, on_delete: :restrict)

      add :target_raw_address, :text

      add :notes, :text
      add :schema_version, :text, null: false, default: "1"
      add :state, :text, null: false, default: "submitted"
      add :submitted_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create constraint(:agent_intents, :kind_valid,
             check: "kind IN ('transfer','swap','scheduled_transfer')"
           )

    create constraint(:agent_intents, :state_valid,
             check:
               "state IN ('submitted','evaluating','decided','executing','executed','blocked','cancelled','expired')"
           )

    # Exactly one of "known target" OR "raw address" is present.
    create constraint(:agent_intents, :target_shape_valid,
             check: """
             (target_counterparty_id IS NOT NULL AND target_raw_address IS NULL)
             OR (target_counterparty_id IS NULL AND target_raw_address IS NOT NULL)
             """
           )

    # Address label is only meaningful when a counterparty is set.
    create constraint(:agent_intents, :address_label_requires_counterparty,
             check: "target_address_label_id IS NULL OR target_counterparty_id IS NOT NULL"
           )

    create unique_index(:agent_intents, [:agent_id, :idempotency_key])
    create index(:agent_intents, [:state])
    create index(:agent_intents, [:target_counterparty_id])
  end
end
