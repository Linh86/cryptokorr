defmodule Bank.Repo.Migrations.CreateCounterpartyTables do
  @moduledoc """
  Counterparties, address labels, evidence artifacts, and trust
  assertions. These four tables are a cluster: evidence and trust
  records are attached polymorphically to either a counterparty or an
  address label via `(subject_type, subject_id)`.

  Append-only semantics:

    * `evidence_artifacts` — correction is a new superseding row.
    * `trust_assertions` — new assertions supersede overlapping ones;
      an assertion is "effective" while `superseded_at IS NULL` and
      `expires_at` is null-or-future.

  Partial unique index on `address_labels`: the same `(chain, address)`
  pair may not be simultaneously active on two labels. Retired labels
  do not participate in uniqueness.
  """

  use Ecto.Migration

  def change do
    # Counterparties -----------------------------------------------------
    create table(:counterparties, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :ownership_context, :text
      add :notes, :text
      add :active, :boolean, null: false, default: true
      # cached snapshot of the latest broadly-scoped TrustAssertion for
      # fast reads; nullable if no broad assertion exists yet.
      add :current_trust_level, :text
      add :created_by, :text, null: false

      timestamps()
    end

    create constraint(:counterparties, :current_trust_level_valid,
             check:
               "current_trust_level IS NULL OR current_trust_level IN ('trusted','sensitive','unknown','conflicted')"
           )

    create index(:counterparties, [:active])

    # Address labels -----------------------------------------------------
    create table(:address_labels, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :counterparty_id,
          references(:counterparties, type: :binary_id, on_delete: :restrict),
          null: false

      add :chain, :text, null: false
      add :address, :text, null: false
      add :alias, :text
      add :role, :text, null: false, default: "other"
      add :verified, :boolean, null: false, default: false
      add :retired_at, :utc_datetime_usec

      timestamps()
    end

    create constraint(:address_labels, :role_valid,
             check: "role IN ('payout','funding','contract','other')"
           )

    create index(:address_labels, [:counterparty_id])

    # Active (non-retired) (chain, address) pairs are unique. Lowercased
    # because EVM addresses are case-insensitive for equality comparison.
    create unique_index(:address_labels, ["chain", "lower(address)"],
             name: :address_labels_chain_address_active_idx,
             where: "retired_at IS NULL"
           )

    # Evidence artifacts -------------------------------------------------
    create table(:evidence_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      # Polymorphic: points at a counterparty or an address label.
      # Left as plain uuid (no FK constraint) because Postgres doesn't
      # model polymorphic FKs. App-level invariants enforce validity.
      add :subject_type, :text, null: false
      add :subject_id, :binary_id, null: false

      add :kind, :text, null: false
      add :source, :text
      add :content_uri, :text, null: false
      add :payload_hash, :text, null: false
      add :captured_at, :utc_datetime_usec, null: false
      add :captured_by, :text, null: false
      add :weight, :text

      add :supersedes_id,
          references(:evidence_artifacts, type: :binary_id, on_delete: :restrict)

      timestamps()
    end

    create constraint(:evidence_artifacts, :subject_type_valid,
             check: "subject_type IN ('counterparty','address_label')"
           )

    create constraint(:evidence_artifacts, :kind_valid,
             check:
               "kind IN ('user_note','signed_message','external_lookup','transaction_history','contract_classification','prior_successful_transfer')"
           )

    create constraint(:evidence_artifacts, :weight_valid,
             check: "weight IS NULL OR weight IN ('low','medium','high')"
           )

    create constraint(:evidence_artifacts, :captured_by_valid,
             check: "captured_by IN ('user','agent','runtime','adapter')"
           )

    create index(:evidence_artifacts, [:subject_type, :subject_id])
    create index(:evidence_artifacts, [:supersedes_id])

    # Trust assertions ---------------------------------------------------
    create table(:trust_assertions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :subject_type, :text, null: false
      add :subject_id, :binary_id, null: false

      add :level, :text, null: false
      add :scope, :map, null: false, default: %{}
      add :rationale, :text
      # Array of evidence_artifact UUIDs that support this assertion.
      # Not an FK array (Postgres limitation); validated at app level.
      add :evidence_ids, {:array, :binary_id}, null: false, default: []

      add :issued_at, :utc_datetime_usec, null: false
      add :issued_by, :text, null: false
      add :expires_at, :utc_datetime_usec
      # When set, this assertion has been replaced by a newer one.
      add :superseded_at, :utc_datetime_usec

      add :supersedes_id,
          references(:trust_assertions, type: :binary_id, on_delete: :restrict)

      timestamps()
    end

    create constraint(:trust_assertions, :subject_type_valid,
             check: "subject_type IN ('counterparty','address_label')"
           )

    create constraint(:trust_assertions, :level_valid,
             check: "level IN ('trusted','sensitive','unknown','conflicted')"
           )

    create constraint(:trust_assertions, :issued_by_valid,
             check: "issued_by IN ('user','agent','runtime','adapter')"
           )

    create index(:trust_assertions, [:subject_type, :subject_id])

    # "Active" read path: effective (non-superseded) assertions per subject.
    # Scope-match filtering happens at query time against the jsonb scope.
    create index(:trust_assertions, [:subject_type, :subject_id, :level],
             name: :trust_assertions_subject_level_active_idx,
             where: "superseded_at IS NULL"
           )
  end
end
