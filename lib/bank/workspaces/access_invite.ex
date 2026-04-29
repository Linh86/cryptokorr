defmodule Bank.Workspaces.AccessInvite do
  @moduledoc """
  Invite / allowlist row for the private-alpha gate (epic #153,
  issue #156).

  Two invite shapes:

    * `:exact_email` — names one address. The strongest signal; a
      successful match creates a membership immediately.
    * `:domain` — names a domain (e.g. `customer-corp.com`). Treated
      conservatively: a match is recorded in audit but membership
      creation is deferred to admin approval (#157).

  ## Status

    * `:active` — eligible to match.
    * `:accepted` — exact-email invite has produced its membership.
      Stays for audit; never matches again.
    * `:revoked` — operator action; never matches again.
    * `:expired` — `expires_at` lapsed. Set lazily on read in
      `Bank.Workspaces.find_matching_invite_for_email/1`.

  ## Polymorphic shape

  The DB enforces (via the `:shape_valid` CHECK):

    * `invite_type == :exact_email` ⇒ `email` set, `domain` nil
    * `invite_type == :domain`     ⇒ `domain` set, `email` nil

  The schema mirrors that constraint at the changeset layer for a
  friendlier validation error than the bare check violation.
  """

  use Bank.Schema

  alias Bank.Accounts.User
  alias Bank.Workspaces.Workspace

  @invite_types [:exact_email, :domain]
  @roles [:owner, :admin, :operator, :viewer]
  @statuses [:active, :accepted, :revoked, :expired]

  @type t :: %__MODULE__{}
  @type invite_type :: :exact_email | :domain
  @type role :: :owner | :admin | :operator | :viewer
  @type status :: :active | :accepted | :revoked | :expired

  schema "access_invites" do
    belongs_to :workspace, Workspace

    field :invite_type, Ecto.Enum, values: @invite_types

    field :email, :string
    field :domain, :string

    field :role, Ecto.Enum, values: @roles
    field :status, Ecto.Enum, values: @statuses, default: :active

    belongs_to :invited_by_user, User, foreign_key: :invited_by_user_id
    belongs_to :accepted_by_user, User, foreign_key: :accepted_by_user_id

    field :expires_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for a freshly-issued invite. The caller supplies the
  workspace, role, and exactly one of `email` / `domain` (the
  `invite_type` is inferred and pinned).
  """
  def create_changeset(invite, attrs) do
    invite
    |> cast(attrs, [
      :workspace_id,
      :invite_type,
      :email,
      :domain,
      :role,
      :invited_by_user_id,
      :expires_at
    ])
    |> validate_required([:workspace_id, :invite_type, :role])
    |> validate_inclusion(:invite_type, @invite_types)
    |> validate_inclusion(:role, @roles)
    |> normalise_email_field()
    |> normalise_domain_field()
    |> validate_shape()
    |> validate_email_format()
    |> validate_domain_format()
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:invited_by_user_id)
    |> unique_constraint([:workspace_id, :email],
      name: :access_invites_active_email_idx,
      message: "an active exact-email invite already exists for this workspace"
    )
    |> unique_constraint([:workspace_id, :domain],
      name: :access_invites_active_domain_idx,
      message: "an active domain invite already exists for this workspace"
    )
  end

  @doc """
  Changeset for an operator revoke. Pins `status: :revoked` and
  `revoked_at` to the supplied timestamp.
  """
  def revoke_changeset(invite, revoked_at \\ DateTime.utc_now()) do
    change(invite, status: :revoked, revoked_at: revoked_at)
  end

  @doc """
  Changeset for marking an invite accepted. Used by
  `Bank.Workspaces.apply_invite_for_user/1` on the exact-email
  match path.
  """
  def accept_changeset(invite, %User{id: user_id}, accepted_at \\ DateTime.utc_now()) do
    change(invite,
      status: :accepted,
      accepted_at: accepted_at,
      accepted_by_user_id: user_id
    )
  end

  @doc """
  Changeset for marking an invite expired (lazy set during the
  matching read path).
  """
  def expire_changeset(invite) do
    change(invite, status: :expired)
  end

  @doc "Returns the supported invite types."
  @spec invite_types() :: [invite_type()]
  def invite_types, do: @invite_types

  @doc "Returns the supported roles."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc "Returns the supported statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  # --- private helpers ---

  defp normalise_email_field(changeset) do
    case get_field(changeset, :email) do
      email when is_binary(email) ->
        put_change(changeset, :email, email |> String.trim() |> String.downcase())

      _ ->
        changeset
    end
  end

  defp normalise_domain_field(changeset) do
    case get_field(changeset, :domain) do
      domain when is_binary(domain) ->
        put_change(changeset, :domain, domain |> String.trim() |> String.downcase())

      _ ->
        changeset
    end
  end

  defp validate_shape(changeset) do
    case {get_field(changeset, :invite_type), get_field(changeset, :email),
          get_field(changeset, :domain)} do
      {:exact_email, email, nil} when is_binary(email) and email != "" ->
        changeset

      {:exact_email, _email, _domain} ->
        add_error(changeset, :email, "exact_email invite requires email and forbids domain")

      {:domain, nil, domain} when is_binary(domain) and domain != "" ->
        changeset

      {:domain, _email, _domain} ->
        add_error(changeset, :domain, "domain invite requires domain and forbids email")

      _ ->
        changeset
    end
  end

  defp validate_email_format(changeset) do
    case {get_field(changeset, :invite_type), get_field(changeset, :email)} do
      {:exact_email, email} when is_binary(email) ->
        validate_format(changeset, :email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)

      _ ->
        changeset
    end
  end

  defp validate_domain_format(changeset) do
    case {get_field(changeset, :invite_type), get_field(changeset, :domain)} do
      {:domain, domain} when is_binary(domain) ->
        validate_format(
          changeset,
          :domain,
          ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/,
          message: "must be a lowercase domain like example.com"
        )

      _ ->
        changeset
    end
  end
end
