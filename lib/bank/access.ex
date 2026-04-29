defmodule Bank.Access do
  @moduledoc """
  Invite-only allowlist + pending access semantics (epic #153,
  issue #156).

  This context owns the `access_invites` table and the rules that
  decide whether an OAuth-authenticated user crosses the line from
  `:pending_access` (no membership) to a workspace member. Pairs
  with `Bank.Accounts` (identity) and `Bank.Workspaces` (scope) —
  the auth controller calls `apply_invites_for_user/1` between
  identity upsert and scope re-resolution.

  ## Matching rules

    * Email + domain are normalised lowercased + trimmed at every
      boundary.
    * Exact-email match (`invite.email == lower(user.email)`) beats a
      domain match (`invite.domain == domain_of(user.email)`) for the
      same workspace.
    * `:revoked`, `:expired`, and past-`expires_at` invites are
      ignored.
    * Accepted invites are idempotent: a returning login does not
      double-create a membership.
    * No cross-workspace leakage: a membership is always written
      with the workspace id from the matching invite, never some
      other workspace's id.
    * A `:disabled` user is never admitted, regardless of invite.

  ## What this context is NOT

    * It does not start a session — that is the auth controller.
    * It does not enforce role-based authorization on subsequent
      requests — that is issue #159.
    * It does not implement the admin approve/reject UI — that is
      issue #157, which reads from this module.

  ## Audit

  Invite-related audit events (`access_invite.created`,
  `access_invite.accepted`, `access_invite.revoked`) are deferred to
  issue #161 to keep this module small and the OAuth callback path
  free of `Bank.Audit.Envelope` plumbing. The hooks live as TODOs
  in the relevant functions.
  """

  import Ecto.Query

  alias Bank.Access.AccessInvite
  alias Bank.Accounts.User
  alias Bank.Repo
  alias Bank.Workspaces
  alias Bank.Workspaces.Membership
  alias Bank.Workspaces.Workspace

  @type uuid :: String.t()
  @type apply_outcome ::
          :no_match
          | :user_disabled
          | {:exact_match_accepted, Membership.t()}
          | {:exact_match_already_member, Membership.t()}
          | {:domain_match_pending, AccessInvite.t()}

  # --- Public surface -------------------------------------------------------

  @doc """
  Create an invite. The `invited_by` user is recorded as the operator
  who issued the invite (server-side; never read from `attrs`).

  Required `attrs` keys:

    * `:workspace_id` — UUID of the target workspace.
    * `:invite_type` — `:exact_email` or `:domain`.
    * `:role` — one of the `Bank.Workspaces.Membership` roles.
    * `:email` for `:exact_email` invites; `:domain` for `:domain`
      invites.

  Optional:

    * `:expires_at` — UTC datetime; absent means the invite never
      expires.
  """
  @spec create_invite(map(), User.t()) ::
          {:ok, AccessInvite.t()} | {:error, Ecto.Changeset.t()}
  def create_invite(attrs, %User{} = invited_by) when is_map(attrs) do
    # TODO #161: emit `access_invite.created` audit event.
    %AccessInvite{}
    |> AccessInvite.create_changeset(attrs, invited_by)
    |> Repo.insert()
  end

  @doc """
  Operator-driven revoke. Refuses to revoke a non-active invite so
  the audit story stays clean. The second argument is the operator
  performing the revoke; it is currently unused but reserved for the
  audit hook in #161.
  """
  @spec revoke_invite(AccessInvite.t(), User.t()) ::
          {:ok, AccessInvite.t()} | {:error, Ecto.Changeset.t()}
  def revoke_invite(%AccessInvite{} = invite, %User{} = _revoked_by) do
    # TODO #161: emit `access_invite.revoked` audit event.
    invite
    |> AccessInvite.revoke_changeset(DateTime.utc_now())
    |> Repo.update()
  end

  @doc """
  Look up the single highest-priority active invite that matches a
  user. Used by callers (e.g. the pending-access screen in #157)
  that just need a yes/no signal.

  Priority order:

    1. exact-email invite (any workspace).
    2. domain invite (any workspace).
    3. tie-broken by earliest `inserted_at` so the result is stable.

  Returns `nil` if the user is disabled, has no parsable email, or
  has no matching active invite.
  """
  @spec find_matching_invite_for_user(User.t()) :: AccessInvite.t() | nil
  def find_matching_invite_for_user(%User{status: :disabled}), do: nil

  def find_matching_invite_for_user(%User{} = user) do
    case extract_match_keys(user) do
      {:ok, email, domain} ->
        Repo.one(
          from(i in matching_invites_query(email, domain),
            order_by: [
              fragment("CASE WHEN ? = 'exact_email' THEN 0 ELSE 1 END", i.invite_type),
              i.inserted_at
            ],
            limit: 1
          )
        )

      :error ->
        nil
    end
  end

  @doc """
  Apply every active invite that matches a user, in one
  transaction-per-workspace.

  Behaviour per matched invite:

    * **exact-email**: create a membership with the invite's role
      (or surface the existing membership if the user already
      belongs), then flip the invite to `:accepted`.
    * **domain**: stamp `matched_at` on the invite (idempotent) but
      do NOT create a membership. The admin flow in #157 takes it
      from there.

  When both an exact-email and a domain invite match in the same
  workspace, the exact-email invite wins; the domain invite is left
  active.

  Returns a list of outcomes (one per workspace touched). The list
  is empty when no invite matches; this is the common path for a
  user who logged in without a prior invite. The caller is expected
  to re-resolve `Bank.Workspaces.resolve_scope/1` afterwards.
  """
  @spec apply_invites_for_user(User.t()) :: [apply_outcome()]
  def apply_invites_for_user(%User{status: :disabled}), do: [:user_disabled]

  def apply_invites_for_user(%User{} = user) do
    # TODO #161: emit `access_invite.accepted` / `access_invite.matched`
    # audit events for each outcome below.
    case extract_match_keys(user) do
      {:ok, email, domain} ->
        invites =
          email
          |> matching_invites_query(domain)
          |> Repo.all()

        invites
        |> group_by_workspace()
        |> Enum.map(fn {workspace_id, invs} ->
          apply_for_workspace(user, workspace_id, invs)
        end)
        |> Enum.reject(&is_nil/1)

      :error ->
        []
    end
  end

  @doc """
  List all active, unexpired invites for a workspace. Stable order
  by `inserted_at` so the operator console renders deterministically.

  Used by the admin flow in #157 to populate "pending invites" lists.
  """
  @spec list_active_invites(Workspace.t() | uuid()) :: [AccessInvite.t()]
  def list_active_invites(%Workspace{id: workspace_id}),
    do: list_active_invites(workspace_id)

  def list_active_invites(workspace_id) when is_binary(workspace_id) do
    now = DateTime.utc_now()

    from(i in AccessInvite,
      where: i.workspace_id == ^workspace_id,
      where: i.status == :active,
      where: is_nil(i.expires_at) or i.expires_at > ^now,
      order_by: i.inserted_at
    )
    |> Repo.all()
  end

  @doc """
  Lowercase + trim an email at the context boundary so callers do
  not have to know the storage convention.
  """
  @spec normalise_email(String.t() | nil) :: String.t() | nil
  def normalise_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalise_email(_), do: nil

  @doc """
  Lowercase + trim a domain.
  """
  @spec normalise_domain(String.t() | nil) :: String.t() | nil
  def normalise_domain(domain) when is_binary(domain),
    do: domain |> String.trim() |> String.downcase()

  def normalise_domain(_), do: nil

  @doc """
  Extract the after-`@` domain part of an email, lowercased + trimmed.
  Returns `nil` for inputs that don't look like an email.
  """
  @spec domain_of(String.t() | nil) :: String.t() | nil
  def domain_of(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [_local, domain] when domain != "" -> normalise_domain(domain)
      _ -> nil
    end
  end

  def domain_of(_), do: nil

  # --- Internals ------------------------------------------------------------

  defp extract_match_keys(%User{email: email}) do
    normalised_email = normalise_email(email)
    domain = domain_of(normalised_email)

    if is_binary(normalised_email) and normalised_email != "" and is_binary(domain) do
      {:ok, normalised_email, domain}
    else
      :error
    end
  end

  defp matching_invites_query(email, domain) do
    now = DateTime.utc_now()

    from(i in AccessInvite,
      where: i.status == :active,
      where: is_nil(i.expires_at) or i.expires_at > ^now,
      where:
        (i.invite_type == :exact_email and fragment("lower(?)", i.email) == ^email) or
          (i.invite_type == :domain and fragment("lower(?)", i.domain) == ^domain)
    )
  end

  defp group_by_workspace(invites) do
    Enum.group_by(invites, & &1.workspace_id)
  end

  # Per workspace: prefer the exact-email invite if any; otherwise
  # take the first domain invite. Returns the per-workspace outcome
  # or `nil` if nothing actionable happened (shouldn't, but defensive).
  defp apply_for_workspace(user, workspace_id, invites) do
    exact = Enum.find(invites, &(&1.invite_type == :exact_email))

    cond do
      exact != nil ->
        apply_exact_match(user, workspace_id, exact)

      domain = Enum.find(invites, &(&1.invite_type == :domain)) ->
        apply_domain_match(user, domain)

      true ->
        nil
    end
  end

  defp apply_exact_match(user, workspace_id, %AccessInvite{} = invite) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      case Workspaces.get_membership(user, workspace_id) do
        nil ->
          {:ok, membership} =
            Workspaces.create_membership(%{
              user_id: user.id,
              workspace_id: workspace_id,
              role: invite.role
            })

          {:ok, _} =
            invite
            |> AccessInvite.accept_changeset(user, now)
            |> Repo.update()

          {:exact_match_accepted, membership}

        %Membership{} = membership ->
          # User is already a member — accept the invite anyway so
          # the row reflects the fact it has been consumed.
          {:ok, _} =
            invite
            |> AccessInvite.accept_changeset(user, now)
            |> Repo.update()

          {:exact_match_already_member, membership}
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
    end
  end

  defp apply_domain_match(user, %AccessInvite{} = invite) do
    now = DateTime.utc_now()

    {:ok, updated} =
      invite
      |> AccessInvite.matched_changeset(user, now)
      |> Repo.update()

    {:domain_match_pending, updated}
  end
end
