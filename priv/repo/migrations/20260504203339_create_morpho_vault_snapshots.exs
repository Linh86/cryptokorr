defmodule Bank.Repo.Migrations.CreateMorphoVaultSnapshots do
  use Ecto.Migration

  def change do
    create table(:morpho_vault_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      # Vault identity. `vault_address` is stored lowercased at the
      # context boundary so the unique-(chain_id, address) index
      # never trips on a mixed-case re-fetch.
      add :chain_id, :integer, null: false
      add :vault_address, :string, null: false
      add :network, :string

      add :name, :string
      add :symbol, :string
      add :listed, :boolean

      # Normalized struct fields (#198) projected verbatim into JSON
      # columns. We deliberately do NOT store the raw GraphQL
      # response body — only the normalized projection plus the
      # payload_hash sentinel, per the issue's "Snapshot
      # persistence does not store unnecessary large raw API bodies
      # unless explicitly justified" acceptance bullet.
      add :deposit_asset, :map, null: false, default: %{}
      add :state, :map, null: false, default: %{}
      add :allocations, {:array, :map}, null: false, default: []
      add :warnings, {:array, :map}, null: false, default: []
      add :pending_caps, {:array, :map}, null: false, default: []
      add :allocators, {:array, :map}, null: false, default: []

      # Source metadata block. Carries source_name,
      # source_schema_version, and any deprecation notes
      # observed on the upstream response. Denormalized
      # `fetched_at` and `payload_hash` columns below give us
      # cheap freshness / dedupe lookups without a JSON probe.
      add :source, :map, null: false, default: %{}

      add :fetched_at, :utc_datetime_usec, null: false
      add :payload_hash, :string, null: false

      # Per-field freshness TTLs (issue #199 design defaults).
      # Stored as discrete columns for easy SQL-side filtering and
      # ALTER TABLE evolution. Defaults match the design doc:
      # 24h identity, 5m allocation, 5m warnings, 1h APY.
      add :freshness_seconds_identity, :integer, null: false, default: 86_400
      add :freshness_seconds_allocation, :integer, null: false, default: 300
      add :freshness_seconds_warnings, :integer, null: false, default: 300
      add :freshness_seconds_apy, :integer, null: false, default: 3600

      # Supersession chain. `current` is the read-pointer for "the
      # snapshot a decision should consume right now"; the rest are
      # historical and reachable via `supersedes_id`.
      add :current, :boolean, null: false, default: false

      add :supersedes_id,
          references(:morpho_vault_snapshots, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:morpho_vault_snapshots, [:chain_id, :vault_address])

    # Single current snapshot per (chain_id, vault_address). The
    # context's persist path demotes the prior current row before
    # inserting a successor inside the same transaction, so this
    # partial unique index is safe under concurrent writers.
    create unique_index(
             :morpho_vault_snapshots,
             [:chain_id, :vault_address],
             where: "\"current\" = TRUE",
             name: :morpho_vault_snapshots_current_uidx
           )

    create index(:morpho_vault_snapshots, [:payload_hash])
    create index(:morpho_vault_snapshots, [:fetched_at])
  end
end
