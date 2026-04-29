defmodule Bank.Workspaces.Membership do
  @moduledoc """
  Joins a `Bank.Accounts.User` to a `Bank.Workspaces.Workspace` with
  a role and status (epic #153, issue #155).

  ## Roles

  Listed in `roles/0`. Capability matrix lives in
  `Bank.Workspaces` and is enforced by future authz plugs / on_mount
  hooks (issue #159).

  ## Status

    * `:active` — counts as "the user can act in this workspace".
    * `:inactive` — the row stays for audit but the user is not in
      the workspace today.

  ## Uniqueness

  `(user_id, workspace_id)` is unique — a user has at most one
  membership per workspace, regardless of status.
  """

  use Bank.Schema

  alias Bank.Accounts.User
  alias Bank.Workspaces.Workspace

  @roles [:owner, :admin, :operator, :viewer]
  @statuses [:active, :inactive]

  @type t :: %__MODULE__{}
  @type role :: :owner | :admin | :operator | :viewer
  @type status :: :active | :inactive

  schema "memberships" do
    belongs_to :user, User
    belongs_to :workspace, Workspace

    field :role, Ecto.Enum, values: @roles
    field :status, Ecto.Enum, values: @statuses, default: :active

    timestamps()
  end

  @doc "Changeset for creating a fresh membership."
  def create_changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :workspace_id, :role, :status])
    |> validate_required([:user_id, :workspace_id, :role])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:user_id, :workspace_id],
      name: :memberships_user_workspace_idx
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:workspace_id)
  end

  @doc "Changeset for an operator role flip — keeps user / workspace pinned."
  def role_changeset(membership, role) when role in @roles do
    change(membership, role: role)
  end

  @doc "Changeset for an operator status flip — keeps user / workspace pinned."
  def status_changeset(membership, status) when status in @statuses do
    change(membership, status: status)
  end

  @doc "Returns the supported role list — used by the context for validation."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc "Returns the supported status list."
  @spec statuses() :: [status()]
  def statuses, do: @statuses
end
