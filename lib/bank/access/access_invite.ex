defmodule Bank.Access.AccessInvite do
  @moduledoc """
  An invite record that admits an authenticated user into a
  workspace (epic #153, issue #156).

  Two `invite_type` shapes:

    * `:exact_email` — `email` is set, `domain` is `nil`. On the
      first OAuth login whose normalised email matches, the invite
      is consumed (`status: :accepted`) and a membership is created.
    * `:domain` — `domain` is set, `email` is `nil`. Matches any
      authenticated user whose email's after-`@` part equals the
      stored domain. Domain matches do NOT auto-create memberships;
      they remain pending until an operator approves the request via
      the admin flow that lands with issue #157.

  ## Status

    * `:active` — eligible to match a login.
    * `:accepted` — exact-email invite already consumed; idempotent.
    * `:revoked` — operator-cancelled; never matches.
    * `:expired` — past `expires_at`; never matches.

  ## Normalisation

  Email + domain are stored lowercased + trimmed at the changeset
  boundary so the partial unique indexes (functional on `lower(...)`)
  stay consistent. Callers that want to query by raw casing are
  expected to use `Bank.Access.normalise_email/1` and
  `Bank.Access.normalise_domain/1`.
  """

  use Bank.Schema

  alias Bank.Accounts.User
  alias Bank.Workspaces.Membership
  alias Bank.Workspaces.Workspace

  @invite_types [:exact_email, :domain]
  @roles [:owner, :admin, :operator, :viewer]
  @statuses [:active, :accepted, :revoked, :expired]

  @type t :: %__MODULE__{}
  @type invite_type :: :exact_email | :domain
  @type role :: Membership.role()
  @type status :: :active | :accepted | :revoked | :expired

  schema "access_invites" do
    belongs_to :workspace, Workspace
    belongs_to :invited_by, User, foreign_key: :invited_by_user_id
    belongs_to :accepted_by, User, foreign_key: :accepted_by_user_id
    belongs_to :matched_by, User, foreign_key: :matched_by_user_id

    field :invite_type, Ecto.Enum, values: @invite_types
    field :email, :string
    field :domain, :string
    field :role, Ecto.Enum, values: @roles
    field :status, Ecto.Enum, values: @statuses, default: :active

    field :expires_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :matched_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for creating a fresh invite. Trusted server-side fields
  (`invited_by_user_id`) are NOT cast — the context sets them from
  the actor struct.

  Email / domain are normalised here so callers can pass user-typed
  input and the partial unique indexes still work.
  """
  def create_changeset(invite, attrs, %User{} = invited_by) do
    invite
    |> cast(attrs, [
      :workspace_id,
      :invite_type,
      :email,
      :domain,
      :role,
      :expires_at
    ])
    |> validate_required([:workspace_id, :invite_type, :role])
    |> validate_inclusion(:invite_type, @invite_types)
    |> validate_inclusion(:role, @roles)
    |> normalise_email_change()
    |> normalise_domain_change()
    |> validate_invite_type_fields()
    |> put_change(:invited_by_user_id, invited_by.id)
    |> put_change(:status, :active)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:invited_by_user_id)
    |> unique_constraint([:workspace_id, :email],
      name: :access_invites_active_workspace_email_idx
    )
    |> unique_constraint([:workspace_id, :domain],
      name: :access_invites_active_workspace_domain_idx
    )
  end

  @doc """
  Changeset that flips an `:active` invite to `:accepted` and stamps
  the consuming user. Refuses to act on a non-active invite so the
  caller can rely on idempotent accept paths.
  """
  def accept_changeset(%__MODULE__{} = invite, %User{} = user, %DateTime{} = now) do
    invite
    |> change(
      status: :accepted,
      accepted_by_user_id: user.id,
      accepted_at: now
    )
    |> validate_active_or_self_accept(invite, user)
  end

  @doc """
  Changeset for an operator revoke. Refuses to revoke an already
  terminal invite so the audit story stays clean.
  """
  def revoke_changeset(%__MODULE__{} = invite, %DateTime{} = now) do
    invite
    |> change(status: :revoked, revoked_at: now)
    |> validate_revokable(invite)
  end

  @doc """
  Changeset that records the first time a domain invite saw a
  matching user. Used so the admin flow in #157 can render "this
  user is waiting on a domain invite". Idempotent: writing it twice
  preserves the original `matched_at`.
  """
  def matched_changeset(%__MODULE__{} = invite, %User{} = user, %DateTime{} = now) do
    case invite.matched_at do
      nil ->
        change(invite,
          matched_by_user_id: user.id,
          matched_at: now
        )

      _ ->
        change(invite, [])
    end
  end

  @doc "Returns the supported invite types — used by `Bank.Access` for validation."
  @spec invite_types() :: [invite_type()]
  def invite_types, do: @invite_types

  @doc "Returns the supported invite statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  # --- Internal validations -------------------------------------------------

  defp normalise_email_change(changeset) do
    case get_change(changeset, :email) do
      nil -> changeset
      email -> put_change(changeset, :email, Bank.Access.normalise_email(email))
    end
  end

  defp normalise_domain_change(changeset) do
    case get_change(changeset, :domain) do
      nil -> changeset
      domain -> put_change(changeset, :domain, Bank.Access.normalise_domain(domain))
    end
  end

  # Mirror the DB-side XOR check so callers see a friendly changeset
  # error instead of a raw constraint violation.
  defp validate_invite_type_fields(changeset) do
    case get_field(changeset, :invite_type) do
      :exact_email ->
        changeset
        |> validate_required([:email])
        |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
        |> validate_no_domain_for_exact()

      :domain ->
        changeset
        |> validate_required([:domain])
        |> validate_format(:domain, ~r/^[a-z0-9.-]+\.[a-z]{2,}$/)
        |> validate_no_email_for_domain()

      _ ->
        changeset
    end
  end

  defp validate_no_domain_for_exact(changeset) do
    case get_field(changeset, :domain) do
      nil -> changeset
      _ -> add_error(changeset, :domain, "must be blank for exact_email invites")
    end
  end

  defp validate_no_email_for_domain(changeset) do
    case get_field(changeset, :email) do
      nil -> changeset
      _ -> add_error(changeset, :email, "must be blank for domain invites")
    end
  end

  defp validate_active_or_self_accept(changeset, %__MODULE__{status: :active}, _user),
    do: changeset

  defp validate_active_or_self_accept(
         changeset,
         %__MODULE__{status: :accepted, accepted_by_user_id: same_user_id},
         %User{id: same_user_id}
       )
       when not is_nil(same_user_id),
       do: changeset

  defp validate_active_or_self_accept(changeset, _invite, _user),
    do: add_error(changeset, :status, "is not active")

  defp validate_revokable(changeset, %__MODULE__{status: :active}), do: changeset

  defp validate_revokable(changeset, _),
    do: add_error(changeset, :status, "is not active")
end
