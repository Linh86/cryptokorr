defmodule Bank.Repo.Migrations.CreateMemberships do
  @moduledoc """
  Memberships join `users` to `workspaces` with a role (epic #153,
  issue #155).

  ## Roles

    * `owner` — workspace creator / billing principal. There can be
      more than one in v1; the first owner is set by the workspace
      bootstrap path (operator-driven in alpha).
    * `admin` — full operator powers, except removing/demoting other
      owners.
    * `operator` — day-to-day intent / decision approval and
      counterparty / policy management.
    * `viewer` — read-only.

  ## Status

    * `active` — counts toward "may enter the workspace".
    * `inactive` — operator-paused or invite-revoked. The row stays
      for audit; the user simply can't act in this workspace.

  ## Uniqueness

  `(user_id, workspace_id)` is unique — a user has at most one
  membership per workspace.
  """
  use Ecto.Migration

  def change do
    create table(:memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: false

      add :role, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memberships, [:user_id, :workspace_id],
             name: :memberships_user_workspace_idx
           )

    create index(:memberships, [:workspace_id], name: :memberships_workspace_idx)
    create index(:memberships, [:user_id, :status], name: :memberships_user_status_idx)

    create constraint(:memberships, :role_valid,
             check: "role IN ('owner', 'admin', 'operator', 'viewer')"
           )

    create constraint(:memberships, :status_valid, check: "status IN ('active', 'inactive')")
  end
end
