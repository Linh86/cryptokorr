defmodule Bank.Repo.Migrations.CreateMorphoVaultSnapshots do
  use Ecto.Migration

  @moduledoc """
  Persisted Morpho vault snapshots (#199 / Phase 1 of #197).

  One row per `Bank.DefiVenues.Morpho.Client.fetch_vault_by_address/3`
  result the runtime decides to keep for replay/freshness. The
  payload_hash is `sha256(:erlang.term_to_binary(raw_body))` from the
  in-memory `%Bank.DefiVenues.Morpho.VaultSnapshot{}` source — same
  hash the in-memory struct already carries, so a duplicate import
  collapses on the unique index instead of writing a second row.

  ## Columns

    * `workspace_id` — nullable FK to `workspaces`. NULL for
      snapshots fetched ahead of any decision (e.g. background
      refresh); set when a snapshot is loaded for a specific
      workspace decision so replay can scope correctly.
    * `correlation_id` — nullable binary_id linking the snapshot
      to a decision/intent for replay.
    * `venue` — text, defaults to `"morpho"`. Phase 1 only
      surface; future venues (Aave, Spark) will share this table
      shape.
    * `chain_id` — bigint EVM chain id (1, 8453, 84532, …).
    * `vault_address` — text, lowercased.
    * `fetched_at` — wall-clock UTC the upstream client reported,
      used by freshness checks. NOT the row's `inserted_at`.
    * `payload_hash` — lowercase hex SHA-256 of the raw upstream
      body. Stable across identical responses; the partial unique
      index `(workspace_id, payload_hash)` collapses re-imports
      idempotently.

  Identity / state columns are flattened from the in-memory
  struct so `SELECT vault_address, listed, apy, net_apy, ...`
  works without a JSONB drill. Bulk fields (allocations,
  warnings, pending_caps, allocators) stay JSONB so a
  schema-version bump on the upstream API can land without a
  migration.

  Additive migration. No backfill, no NOT NULL flips on existing
  columns.
  """

  def change do
    create table(:morpho_vault_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: true

      add :correlation_id, :binary_id, null: true

      add :venue, :text, null: false, default: "morpho"
      add :chain_id, :bigint, null: false
      add :vault_address, :text, null: false
      add :fetched_at, :utc_datetime_usec, null: false
      add :payload_hash, :text, null: false

      # Identity (flattened from VaultSnapshot)
      add :name, :text
      add :symbol, :text
      add :listed, :boolean
      add :network, :text

      # Deposit asset (flattened)
      add :deposit_asset_address, :text
      add :deposit_asset_symbol, :text
      add :deposit_asset_decimals, :integer

      # State (flattened — numeric strings preserved verbatim per
      # the in-memory struct's precision-preserving contract)
      add :apy, :text
      add :net_apy, :text
      add :total_assets, :text
      add :fee, :text
      add :timelock, :integer

      # Bulk JSONB sections
      add :allocations, :map, null: false, default: %{}
      add :warnings, :map, null: false, default: %{}
      add :pending_caps, :map, null: false, default: %{}
      add :allocators, :map, null: false, default: %{}

      # Source metadata
      add :source_name, :text, null: false
      add :source_schema_version, :text, null: false
      add :source_warnings, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(
             :morpho_vault_snapshots,
             [:venue, :chain_id, :vault_address, :fetched_at],
             name: :morpho_vault_snapshots_lookup
           )

    create index(:morpho_vault_snapshots, [:correlation_id],
             name: :morpho_vault_snapshots_correlation
           )

    create index(:morpho_vault_snapshots, [:workspace_id],
             name: :morpho_vault_snapshots_workspace
           )

    # Two partial unique indexes (Postgres < 15 treats NULLs as
    # distinct in a regular unique index). The workspace-scoped
    # dedupe and the workspace-agnostic dedupe both live in their
    # own partial index keyed off `workspace_id IS NULL`.
    create unique_index(
             :morpho_vault_snapshots,
             [:workspace_id, :payload_hash],
             where: "workspace_id IS NOT NULL",
             name: :morpho_vault_snapshots_workspace_dedupe_idx
           )

    create unique_index(
             :morpho_vault_snapshots,
             [:payload_hash],
             where: "workspace_id IS NULL",
             name: :morpho_vault_snapshots_global_dedupe_idx
           )
  end
end
