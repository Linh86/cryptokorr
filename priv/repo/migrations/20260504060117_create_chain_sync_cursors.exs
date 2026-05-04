defmodule Bank.Repo.Migrations.CreateChainSyncCursors do
  use Ecto.Migration

  @moduledoc """
  Creates the `chain_sync_cursors` table for #245 Phase 1 — read-
  only wallet/smart-account chain activity sync.

  One row per `(workspace_id, chain, source_type, address)` tuple.
  Tracks the last successfully-synced block for that watched
  address so a re-run picks up where the previous left off, plus a
  small last-error envelope so source failures are visible to
  operators (acceptance: "source failures visible") without
  spamming logs.

  ## Columns

    * `workspace_id` — FK to `workspaces`, `null: false`,
      `on_delete: :restrict` per the repo's workspace-FK
      convention.
    * `chain` — text (e.g. `"base-sepolia"`); part of the
      single-active uniqueness tuple.
    * `source_type` — text discriminator. Phase 1 supports
      `"wallet_chain"` and `"smart_account_chain"` — same
      values used by `Bank.Activity.ImportedActivity.source_type`.
    * `address` — text checksum address watched. Lowercased
      by the context layer; the DB stores whatever the caller
      passed.
    * `last_block_number` — last block we successfully synced
      events from (inclusive). Default `0`; `null: false`.
    * `last_synced_at` — wall-clock UTC of the last successful
      sync (any outcome with no error). Nullable.
    * `last_error` — fixed-shape sanitized error label
      (`"rpc_unavailable"`, `"rpc_error_5xx"`, `"timeout"`,
      etc.). Nullable; cleared on success.
    * `last_error_at` — wall-clock UTC of the last error.
      Nullable; cleared on success.
    * timestamps.

  ## Indexes

    * Unique `(workspace_id, chain, source_type, address)` so
      `Bank.Activity.ChainSync.sync_address/4` can do a single
      upsert per watched address.
    * Workspace lookup index for `list/1` reads on the operator
      console (future #246).

  Additive migration. No backfill, no NOT NULL flips on existing
  columns.
  """

  def change do
    create table(:chain_sync_cursors, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: false

      add :chain, :text, null: false
      add :source_type, :text, null: false
      add :address, :text, null: false

      add :last_block_number, :bigint, null: false, default: 0
      add :last_synced_at, :utc_datetime_usec, null: true
      add :last_error, :text, null: true
      add :last_error_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :chain_sync_cursors,
             [:workspace_id, :chain, :source_type, :address],
             name: :chain_sync_cursors_uniq
           )

    create index(:chain_sync_cursors, [:workspace_id])
  end
end
