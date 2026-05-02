defmodule Bank.Repo.Migrations.CreatePauses do
  use Ecto.Migration

  @moduledoc """
  Creates the `pauses` table for #228 Phase 1 — DB-backed per-chain
  pause gate. Workspace-scoped; one workspace pausing a chain cannot
  block a sibling workspace.

  Columns:

    * `id` — binary_id primary key.
    * `workspace_id` — `null: false`. Every Phase 1 scope this issue
      introduces is workspace-scoped, and the partial unique index
      below relies on the column being non-NULL to enforce
      single-active. FK uses `on_delete: :restrict` to match the
      repo's workspace-FK convention (`api_keys`, `memberships`,
      `access_invites`, `add_workspace_id_scoping_foundation`) and
      because `:nilify_all` is invalid against a NOT NULL column.
    * `scope_type` — text discriminator. Phase 1 ships `:chain`
      only; Phase 2/3 extend the schema's `Ecto.Enum`.
    * `scope_value` — chain id (e.g., "base"). Smart-account /
      api-key forms are deferred.
    * `reason` — nullable operator note (capped at 256 chars by
      changeset, mirroring `agent_keys_paused_reason`).
    * `created_by_user_id` — nullable FK to users with
      `on_delete: :nilify_all`, matching the
      `agent_keys_paused_by_user_id` precedent. Pointer is audit
      metadata; user deletion nullifies it without blocking. Audit
      events preserve actor durably.
    * `paused_at` — `null: false`. Required for an active pause.
    * `resumed_at` — nullable. Active pause iff `resumed_at IS NULL`.
    * `resumed_by_user_id` — nullable, mirrors the
      `created_by_user_id` shape. Audit metadata only.
    * `timestamps(:utc_datetime_usec)` per repo convention.

  No `expires_at` in Phase 1: the column and its auto-resume sweeper
  land together as a single Phase 1.5 PR. Shipping the column now
  would force a partial-index predicate that depends on `now()`
  (rejected by Postgres) or leave a row with elapsed `expires_at`
  and NULL `resumed_at` occupying the active slot.

  Indexes:

    * `:pauses_active_uniq` — partial unique index on
      `(workspace_id, scope_type, scope_value) WHERE resumed_at IS
      NULL`. Because `workspace_id` is `null: false`, NULL does not
      participate; the constraint genuinely enforces single-active.
    * Lookup index on `(workspace_id, scope_type, scope_value)` for
      `paused?/3` reads.

  Migration creates a brand-new table and alters no existing tables;
  no backfill, no NOT NULL flips on existing columns.
  """

  def change do
    create table(:pauses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: false

      add :scope_type, :text, null: false
      add :scope_value, :text, null: false

      add :reason, :text, null: true

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all),
          null: true

      add :paused_at, :utc_datetime_usec, null: false
      add :resumed_at, :utc_datetime_usec, null: true

      add :resumed_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all),
          null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pauses, [:workspace_id, :scope_type, :scope_value],
             where: "resumed_at IS NULL",
             name: :pauses_active_uniq
           )

    create index(:pauses, [:workspace_id, :scope_type, :scope_value],
             name: :pauses_workspace_scope_lookup_idx
           )
  end
end
