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

  `mainnet_enabled` is intentionally NOT cast here — it's an
  admin-only security flip that travels through
  `set_mainnet_enabled/2` so a creation path cannot accidentally
  grant mainnet eligibility. Default is `false` (the schema
  default), enforced by the `:mainnet_enabled NOT NULL DEFAULT false`
  column added in #178.
  """
  @spec create_workspace(map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Flip a workspace's Base mainnet eligibility flag (#178).

  Returns `{:ok, workspace}` with the updated row, or
  `{:error, changeset}` on validation failure. Audit emission
  is the caller's responsibility — this context function is the
  data-layer boundary.

  Accepts a `%Workspace{}` struct or a workspace id.
  """
  @spec set_mainnet_enabled(Workspace.t() | uuid(), boolean()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_mainnet_enabled(%Workspace{} = workspace, enabled) when is_boolean(enabled) do
    workspace
    |> Workspace.mainnet_changeset(%{mainnet_enabled: enabled})
    |> Repo.update()
  end

  def set_mainnet_enabled(workspace_id, enabled)
      when is_binary(workspace_id) and is_boolean(enabled) do
    case get_workspace(workspace_id) do
      %Workspace{} = workspace -> set_mainnet_enabled(workspace, enabled)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Flip the `notify_execution_confirmed` opt-in flag (#234).

  When `true`, `Bank.Notifications.Emitter.emit_execution_outcome/1`
  surfaces an `:info` notification on every successful
  `Bank.Decisions.apply_execution_callback/1` transition to
  `:confirmed`. Default is `false` (the workspace stays
  silent-on-success), matching today's posture for workspaces
  that have not opted in.

  Mirrors `set_mainnet_enabled/2`'s shape: this is an admin-only
  setting flip, kept apart from the user-editable
  `changeset/2`'s slug/name path. Accepts a `%Workspace{}` struct
  or a workspace id.
  """
  @spec set_notify_execution_confirmed(Workspace.t() | uuid(), boolean()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_notify_execution_confirmed(%Workspace{} = workspace, enabled)
      when is_boolean(enabled) do
    workspace
    |> Workspace.notification_changeset(%{notify_execution_confirmed: enabled})
    |> Repo.update()
  end

  def set_notify_execution_confirmed(workspace_id, enabled)
      when is_binary(workspace_id) and is_boolean(enabled) do
    case get_workspace(workspace_id) do
      %Workspace{} = workspace -> set_notify_execution_confirmed(workspace, enabled)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  True iff `workspace_id` has Base mainnet eligibility explicitly
  enabled (#178).

  `nil` and unknown ids return `false` — the legacy-safe default
  for any code path that has not been workspace-scoped yet.

  Used by `Bank.Chains.mainnet_allowed_for?/2` (the canonical gate
  every chain-touching boundary consults). Callers should prefer
  the `Bank.Chains` helpers; reading `mainnet_enabled?/1` directly
  is fine when only the workspace state matters and the chain is
  already known to be mainnet.
  """
  @spec mainnet_enabled?(uuid() | nil) :: boolean()
  def mainnet_enabled?(workspace_id) when is_binary(workspace_id) do
    case get_workspace(workspace_id) do
      %Workspace{mainnet_enabled: true} -> true
      _ -> false
    end
  end

  def mainnet_enabled?(_), do: false

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
