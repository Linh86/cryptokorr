defmodule Bank.Repo.Migrations.CreateImportedActivities do
  use Ecto.Migration

  @moduledoc """
  Creates the `imported_activities` table for #243 — the normalized
  ledger of imported wallet/bank activity. Workspace-scoped; one
  workspace's import cannot leak into a sibling workspace's view.

  ## Why this exists

  #244 will add a CSV upload UI on top of this table; #245 will add
  read-only on-chain wallet/smart-account sync. Both surfaces need a
  single shared row shape so dedupe, query, and accounting reads stay
  consistent. This migration only ships the foundation — no import
  surface, no chain sync, no UI.

  ## Columns

  - `workspace_id` — `null: false`. FK uses `on_delete: :restrict`
    to match the repo convention for workspace-scoped business data.
  - `source_type` — text discriminator. Schema-layer enum
    constrains values to `:csv | :wallet_chain |
    :smart_account_chain | :manual`.
  - `source_ref` — nullable external reference (e.g. CSV row index,
    on-chain `(chain, tx_hash, log_index)` tuple stringified).
  - `source_hash` — nullable SHA-256 hex of the raw source row.
    Either `source_ref` or `source_hash` must be present
    (enforced by changeset).
  - `occurred_at` — `null: false`. Wall-clock time of the activity
    on its source ledger.
  - `asset` — `null: false`. Token / fiat ticker.
  - `chain` — nullable. Off-chain bank entries leave this null.
  - `amount` — `null: false`. Decimal; sign carried in `direction`.
  - `direction` — text discriminator (`:inbound | :outbound`).
  - `from_address` / `to_address` — nullable strings.
  - `counterparty_id` — nullable FK to `counterparties` with
    `on_delete: :nilify_all`. Set when the import resolves the
    counterparty; left null otherwise so a future
    counterparty-resolution job can backfill.
  - `tx_hash` — nullable. Chain transaction hash.
  - `bank_ref` — nullable. External bank ledger reference.
  - `status` — text discriminator (`:confirmed | :pending |
    :failed | :imported`, default `:imported`).
  - `provenance` — nullable short label (e.g. "manual upload by
    operator"). Audit context, not load-bearing.
  - `confidence` — text discriminator (`:high | :medium | :low`,
    default `:medium`).
  - `metadata` — `:map`, default `%{}`. Preserves unknown
    source-side fields. The context redacts well-known secret
    keys (`Authorization`, `Bearer`, `private_key`, etc.) before
    write — see `Bank.Activity` for the contract.
  - `dedupe_key` — `null: false`. Deterministic hex digest
    computed by the context.

  ## Indexes

  - `:imported_activities_workspace_dedupe_uniq` — unique on
    `(workspace_id, dedupe_key)`. Re-importing the same source
    row short-circuits at insert time and the context returns the
    existing row.
  - `:imported_activities_workspace_occurred_idx` — composite on
    `(workspace_id, occurred_at)` for the standard "list newest
    first within a workspace" read.

  ## Migration safety

  - Brand-new table; alters no existing tables.
  - No NOT NULL flips on existing columns.
  - No backfill.
  - Forward-compatible: every nullable column can be filled later
    by a reconciler without breaking existing rows.
  """

  def change do
    create table(:imported_activities, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: false

      add :source_type, :text, null: false
      add :source_ref, :text, null: true
      add :source_hash, :text, null: true

      add :occurred_at, :utc_datetime_usec, null: false

      add :asset, :text, null: false
      add :chain, :text, null: true
      add :amount, :decimal, null: false
      add :direction, :text, null: false

      add :from_address, :text, null: true
      add :to_address, :text, null: true

      add :counterparty_id,
          references(:counterparties, type: :binary_id, on_delete: :nilify_all),
          null: true

      add :tx_hash, :text, null: true
      add :bank_ref, :text, null: true

      add :status, :text, null: false, default: "imported"
      add :provenance, :text, null: true
      add :confidence, :text, null: false, default: "medium"

      add :metadata, :map, null: false, default: %{}

      add :dedupe_key, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:imported_activities, [:workspace_id, :dedupe_key],
             name: :imported_activities_workspace_dedupe_uniq
           )

    create index(:imported_activities, [:workspace_id, :occurred_at],
             name: :imported_activities_workspace_occurred_idx
           )
  end
end
