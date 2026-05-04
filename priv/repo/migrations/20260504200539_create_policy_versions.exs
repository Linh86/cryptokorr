defmodule Bank.Repo.Migrations.CreatePolicyVersions do
  use Ecto.Migration

  @moduledoc """
  Creates the `policy_versions` table for #223 — the workspace-
  scoped, versioned draft/publish/rollback aggregate that bundles
  a set of `policy_rules` ids with a single version number, a
  publication state, and an immutable rule_ids list once
  published.

  ## Why this exists

  `Bank.Policies` already versions individual rules (each
  `policy_rules` row carries `version`, `state`, and a
  `supersedes_id` chain). What's missing — and what this issue
  closes — is a SET-level aggregate that:

    * names the current "published policy" for a workspace as a
      single addressable unit (one row, one version number);
    * supports a draft cycle where edits don't affect runtime;
    * makes publishing produce an IMMUTABLE snapshot a future
      decision can pin against;
    * supports rollback to a prior published version.

  Existing per-rule supersession is unchanged. Existing
  decisions' `policy_snapshot_ref` (pinned rule ids) are
  unchanged — replay determinism is already covered there.

  Runtime wire-up (decisions actually consulting PolicyVersion
  instead of `Bank.Policies.load_active_ruleset/1`) lands in
  #226. This migration ships the data layer only.

  ## Columns

  - `workspace_id` — `null: false`. FK with `on_delete: :restrict`
    to match the convention for workspace-scoped business data.
  - `version_number` — `null: false`. Per-workspace integer that
    increments on each publish (1, 2, 3…). The
    `(workspace_id, version_number)` pair is unique.
  - `status` — `null: false`. Schema enum constrains values to
    `:draft | :published | :superseded`. Default `:draft`.
  - `rule_ids` — `null: false`. JSONB array of `policy_rules.id`
    UUIDs. The bundle's contents. Frozen once `:published` (the
    schema layer rejects updates after publish).
  - `created_by` — `null: false`. Text (mirrors
    `policy_rules.created_by`). The actor that opened the draft.
  - `published_by` — `null: true`. Text. Set when status flips
    to `:published`.
  - `published_at` — `null: true`. UTC timestamp. Set when the
    status flips to `:published` AND when a rollback re-marks an
    older version as `:published` (re-pubbed_at).
  - `effective_at` — `null: true`. UTC timestamp. Same value as
    `published_at` for normal publishes; for rollback this is the
    rollback's effective time, NOT the original publication time
    of the rolled-back version.
  - `supersedes_id` — `null: true`. FK to the prior published
    version that this row replaces. Forms a chain analogous to
    `policy_rules.supersedes_id`.

  ## Indexes

  - **unique** `(workspace_id, version_number)` — guarantees the
    per-workspace version sequence has no holes / collisions.
  - **partial unique** `workspace_id WHERE status = 'published'`
    — at most one published version per workspace at a time. The
    publish/rollback transactions enforce the same invariant in
    the application layer.
  - `(workspace_id, status, version_number DESC)` — listing
    helper for the future operator UI (#224).
  """

  def change do
    create table(:policy_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: false

      add :version_number, :integer, null: false
      add :status, :string, null: false, default: "draft"

      add :rule_ids, :map, null: false, default: %{"items" => []}

      add :created_by, :string, null: false
      add :published_by, :string, null: true

      add :published_at, :utc_datetime_usec, null: true
      add :effective_at, :utc_datetime_usec, null: true

      add :supersedes_id,
          references(:policy_versions, type: :binary_id, on_delete: :restrict),
          null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:policy_versions, [:workspace_id, :version_number],
             name: :policy_versions_workspace_version_uidx
           )

    create unique_index(:policy_versions, [:workspace_id],
             name: :policy_versions_workspace_one_published_uidx,
             where: "status = 'published'"
           )

    create index(:policy_versions, [:workspace_id, :status, :version_number],
             name: :policy_versions_workspace_status_idx
           )
  end
end
