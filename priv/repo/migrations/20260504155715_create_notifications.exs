defmodule Bank.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  @moduledoc """
  Creates the `notifications` table for #233 — the workspace-scoped
  inbox event model that domain code can write into without
  triggering external delivery (#234 will add runtime emitters,
  #235 the inbox UI, #236 delivery channels).

  ## Why this exists

  The runtime needs a way to record "operator should look at this
  intent / decision / pause / abort" as a first-class data point
  that survives restarts, replays cleanly, and can be deduped per
  workspace. The audit log is append-only and event-shaped; an
  operator inbox needs read/archive state and per-event uniqueness.
  Splitting the data model now (this issue) from delivery and
  emitters (next issues) keeps the storage contract stable while
  the channel surface area grows.

  ## Columns

  - `workspace_id` — `null: false`. FK with `on_delete: :restrict`
    to match the repo convention for workspace-scoped business
    data (no cascade — workspace deletion is a manual operator
    action that must clear children explicitly).
  - `user_id` — `null: true`. FK with `on_delete: :nilify_all`.
    Nullable because notifications can be addressed to a role
    target instead of a specific user (`role_target` column).
  - `role_target` — `null: true`. Text discriminator; the schema
    layer constrains values to `:viewer | :operator | :admin |
    :owner`. Mutually exclusive with `user_id` at the changeset
    layer (one of the two must be set; both null is rejected).
  - `event_type` — `null: false`. Programmer-set, e.g.
    `"intent.held"`, `"decision.approval_required"`,
    `"execution.aborted"`. Free text at the column level so this
    issue does not bake in a closed enum that #234 emitters will
    have to negotiate against.
  - `severity` — `null: false`, default `"info"`. Schema enum
    constrains to `:info | :warning | :critical`.
  - `status` — `null: false`, default `"unread"`. Schema enum
    constrains to `:unread | :read | :archived`.
  - `subject_type` / `subject_id` — both nullable. Optional pointer
    back to the row that triggered the notification (e.g.
    `"agent_intent"` + UUID).
  - `correlation_id` — nullable UUID. Typically the intent id, so
    the inbox can be cross-linked with `Bank.Audit.replay/1`.
  - `title` — `null: false`. Capped at 200 chars at the changeset
    layer. Secret-rejected before persistence.
  - `body` — `null: false`. Capped at 2000 chars. Secret-rejected.
  - `action_link` — `null: true`. Restricted to a relative path
    (must start with `/`) at the changeset layer. No external
    URLs, no schemes, no userinfo.
  - `dedupe_key` — `null: false`. Per-workspace unique. Repeated
    `create/1` calls with the same `(workspace_id, dedupe_key)`
    return `{:duplicate, existing}` instead of inserting a second
    row — that is how dedupe prevents inbox spam.
  - `read_at` / `archived_at` — nullable timestamps; set when the
    matching `mark_read/2` / `archive/2` helper is called.
  - `inserted_at` / `updated_at` — standard.

  ## Indexes

  - **unique** `(workspace_id, dedupe_key)` — the dedupe gate.
    Per-workspace so two workspaces can use the same dedupe key
    independently.
  - `(workspace_id, status, inserted_at DESC)` — inbox listing
    by recency, filtered by status.
  - `(workspace_id, user_id, status, inserted_at DESC)` — same,
    but for user-scoped inbox queries.

  ## Scope

  Internal-only data model. No HTTP endpoint, no LiveView, no
  external delivery channel, no runtime emitter. Those land in
  #234 / #235 / #236 / #237.
  """

  def change do
    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all), null: true
      add :role_target, :string, null: true

      add :event_type, :string, null: false
      add :severity, :string, null: false, default: "info"
      add :status, :string, null: false, default: "unread"

      add :subject_type, :string, null: true
      add :subject_id, :binary_id, null: true
      add :correlation_id, :binary_id, null: true

      add :title, :string, null: false, size: 200
      add :body, :text, null: false
      add :action_link, :string, null: true, size: 512

      add :dedupe_key, :string, null: false, size: 200

      add :read_at, :utc_datetime_usec, null: true
      add :archived_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notifications, [:workspace_id, :dedupe_key],
             name: :notifications_workspace_dedupe_key_uidx
           )

    create index(:notifications, [:workspace_id, :status, :inserted_at],
             name: :notifications_workspace_status_idx
           )

    create index(:notifications, [:workspace_id, :user_id, :status, :inserted_at],
             name: :notifications_workspace_user_status_idx
           )
  end
end
