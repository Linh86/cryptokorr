defmodule Bank.Workspaces do
  @moduledoc """
  Workspaces + memberships bounded context (epic #153, issue #155).

  Owns the `workspaces` and `memberships` tables and the read/write
  surface around them. Pairs with `Bank.Accounts` (identity) — this
  module answers "what can this user do, and where?".

  ## Scope resolution

  `resolve_scope/1` is the contract that
  `BankWeb.Plugs.FetchCurrentUser` consumes. Given a user, it
  reports one of three answers:

    * `:no_membership` — zero active memberships. The plug populates
      `current_scope` with `workspace: nil` and the controller is
      free to redirect to `/pending`.
    * `{:single, %Membership{}}` — exactly one active membership.
      The plug auto-selects that workspace.
    * `{:ambiguous, [%Membership{}, ...]}` — two or more active
      memberships. Workspace selection lives in #157 (operator
      console picker); for #155 the plug treats this the same as
      `:no_membership` so the user does not silently land in any
      workspace.

  ## What this module does NOT do

    * Enforce role-based authorization on actions. That's #159.
    * Apply the workspace filter to scoped tables. Counterparties,
      policies, etc. land in #158.
    * Manage invites or admin approval. Those are #156 / #157.
  """

  import Ecto.Query

  alias Bank.Accounts.User
  alias Bank.Repo
  alias Bank.Workspaces.{Membership, Workspace}

  @type uuid :: String.t()
  @type scope_resolution ::
          :no_membership
          | {:single, Membership.t()}
          | {:ambiguous, [Membership.t()]}

  # --- Workspaces ---

  @doc "Fetch a workspace by id. Returns the struct or `nil`."
  @spec get_workspace(uuid()) :: Workspace.t() | nil
  def get_workspace(id) when is_binary(id), do: Repo.get(Workspace, id)
  def get_workspace(_), do: nil

  @doc "Fetch a workspace by slug (case-insensitive). Returns the struct or `nil`."
  @spec get_workspace_by_slug(String.t()) :: Workspace.t() | nil
  def get_workspace_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Workspace, slug: String.downcase(String.trim(slug)))
  end

  def get_workspace_by_slug(_), do: nil

  @doc """
  Create a workspace from `attrs` (`%{slug:, name:}`). Slug is
  normalised to lowercase.
  """
  @spec create_workspace(map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  # --- Memberships ---

  @doc """
  Add a user to a workspace with a role. Returns the membership
  struct (status defaults to `:active`).
  """
  @spec create_membership(map()) :: {:ok, Membership.t()} | {:error, Ecto.Changeset.t()}
  def create_membership(attrs) do
    %Membership{}
    |> Membership.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Set membership role. Operator-only path."
  @spec set_role(Membership.t(), Membership.role()) ::
          {:ok, Membership.t()} | {:error, Ecto.Changeset.t()}
  def set_role(%Membership{} = membership, role) do
    membership |> Membership.role_changeset(role) |> Repo.update()
  end

  @doc "Set membership status (`:active` ↔ `:inactive`)."
  @spec set_status(Membership.t(), Membership.status()) ::
          {:ok, Membership.t()} | {:error, Ecto.Changeset.t()}
  def set_status(%Membership{} = membership, status) do
    membership |> Membership.status_changeset(status) |> Repo.update()
  end

  @doc """
  Look up a membership by `(user, workspace_id)`. Returns the struct
  or `nil`. Used by `Bank.Access.apply_invites_for_user/1` to decide
  whether to insert or accept-as-already-member when an exact-email
  invite matches.
  """
  @spec get_membership(User.t(), uuid()) :: Membership.t() | nil
  def get_membership(%User{id: user_id}, workspace_id)
      when is_binary(workspace_id) do
    Repo.get_by(Membership, user_id: user_id, workspace_id: workspace_id)
  end

  @doc """
  All active memberships for a user, joined with the workspace.
  Ordered by workspace slug for deterministic test output.
  """
  @spec list_active_memberships(User.t()) :: [Membership.t()]
  def list_active_memberships(%User{id: user_id}) do
    from(m in Membership,
      where: m.user_id == ^user_id and m.status == :active,
      join: w in assoc(m, :workspace),
      order_by: w.slug,
      preload: [workspace: w]
    )
    |> Repo.all()
  end

  @doc """
  Resolve the scope for a user, applied by `BankWeb.Plugs.FetchCurrentUser`.

  See module docs for the three return shapes.
  """
  @spec resolve_scope(User.t()) :: scope_resolution()
  def resolve_scope(%User{} = user) do
    case list_active_memberships(user) do
      [] -> :no_membership
      [single] -> {:single, single}
      [_ | _] = many -> {:ambiguous, many}
    end
  end
end
