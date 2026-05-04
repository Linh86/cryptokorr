defmodule Bank.Access do
  @moduledoc """
  Invite-only allowlist + pending access semantics + admin
  approve/reject flow (epic #153, issues #156 + #157).

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

  ## Admin approve / reject (issue #157)

    * `list_pending_access/1` — users with no active membership and
      not `:disabled`. Each row is classified (`:domain_match`,
      `:allowlist_missed`, `:exact_match_pending`) so the operator
      console can render context inline.
    * `approve_pending_user/3` — bootstrap-admin grants membership.
      Uses the matching domain invite for `workspace_id` / `role`
      defaults; falls back to explicit opts when no invite exists.
      Idempotent (`:already_member` for an existing active membership;
      `:membership_reactivated` for a revived inactive one).
    * `reject_pending_user/3` — flips the user to `:disabled` so
      future logins are refused at the session boundary. Audit
      history is preserved untouched.
    * `can_admin_access?/1` — bootstrap admin guard backed by the
      `:bank, :admin_emails` config (`BANK_ADMIN_EMAILS` env). This
      is a temporary alpha-only gate that #159 replaces with a real
      role-based authorization matrix.

  ## What this context is NOT

    * It does not start a session — that is the auth controller.
    * It does not enforce role-based authorization on subsequent
      requests — that is issue #159.

  ## Audit

  Each lifecycle transition emits a `Bank.Audit` row through the
  `Bank.Audit.Events` builders (issue #161). Events are appended via
  `safe_emit/1`, which swallows + logs on failure so a transient
  audit-table problem cannot roll back a user-visible action like
  login, approve, or invite create.

  Vocabulary:
    * `access.invite_created` / `access.invite_revoked` — invite
      lifecycle, correlated by invite id.
    * `access.allowlist_matched` — emitted once per real state
      transition; `match_type` distinguishes `:exact_email_accepted`
      from `:domain_matched`.
    * `access.allowlist_missed` — login produced no matching invite.
    * `access.admin_approved` / `access.admin_rejected` — bootstrap
      admin transitions; idempotent no-ops (`:already_member`,
      `:already_disabled`) do NOT emit.

  The login envelope events (`auth.login_succeeded`,
  `auth.login_denied`) live with the auth controller, where the
  user-visible state transition actually happens.
  """

  import Ecto.Query

  alias Bank.Access.AccessInvite
  alias Bank.Accounts
  alias Bank.Accounts.User
  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Repo
  alias Bank.Workspaces
  alias Bank.Workspaces.Membership
  alias Bank.Workspaces.Workspace

  require Logger

  @type uuid :: String.t()
  @type apply_outcome ::
          :no_match
          | :user_disabled
          | {:exact_match_accepted, Membership.t()}
          | {:exact_match_already_member, Membership.t()}
          | {:domain_match_pending, AccessInvite.t()}

  @type pending_classification ::
          :exact_match_pending | :domain_match | :allowlist_missed

  @type pending_row :: %{
          required(:user) => User.t(),
          required(:classification) => pending_classification(),
          required(:invite) => AccessInvite.t() | nil
        }

  @type approve_outcome ::
          :membership_created
          | :already_member
          | :membership_reactivated

  @type approve_result ::
          {:ok, approve_outcome(), Membership.t()}
          | {:error,
             :unauthorized
             | :self_action
             | :user_disabled
             | :workspace_target_required
             | :role_required
             | term()}

  @type reject_result ::
          {:ok, :rejected, User.t()}
          | {:ok, :already_disabled, User.t()}
          | {:error, :unauthorized | :self_action | term()}

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
    changeset = AccessInvite.create_changeset(%AccessInvite{}, attrs, invited_by)

    # Lazy expiry leaves stale rows with `status: :active` but past
    # `expires_at`. The partial unique index treats them as occupying
    # the slot, while `list_active_invites/1` filters them out — so
    # the operator UI says "no active invite" while the DB blocks the
    # re-issue. Eagerly transition any stale row matching the same
    # slot before we insert. The index `WHERE` cannot reference
    # `now()` (Postgres requires IMMUTABLE expressions there), so we
    # have to do it here.
    if changeset.valid?, do: expire_stale_active_invites_for(changeset)

    case Repo.insert(changeset) do
      {:ok, %AccessInvite{} = invite} = ok ->
        safe_emit(Events.access_invite_created(invite, invited_by))
        ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Operator-driven revoke. Refuses to revoke a non-active invite so
  the audit story stays clean. The second argument is the operator
  performing the revoke; it is currently unused but reserved for the
  audit hook in #161.
  """
  @spec revoke_invite(AccessInvite.t(), User.t()) ::
          {:ok, AccessInvite.t()} | {:error, Ecto.Changeset.t()}
  def revoke_invite(%AccessInvite{} = invite, %User{} = revoked_by) do
    case invite
         |> AccessInvite.revoke_changeset(DateTime.utc_now())
         |> Repo.update() do
      {:ok, %AccessInvite{} = revoked} = ok ->
        safe_emit(Events.access_invite_revoked(revoked, revoked_by))
        ok

      {:error, _} = err ->
        err
    end
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
    case extract_match_keys(user) do
      {:ok, email, domain} ->
        invites =
          email
          |> matching_invites_query(domain)
          |> Repo.all()

        outcomes =
          invites
          |> group_by_workspace()
          |> Enum.map(fn {workspace_id, invs} ->
            apply_for_workspace(user, workspace_id, invs)
          end)
          |> Enum.reject(&is_nil/1)

        if outcomes == [], do: safe_emit(Events.access_allowlist_missed(user))
        outcomes

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

    {membership, outcome_tag} =
      case Workspaces.get_membership(user, workspace_id) do
        %Membership{} = m ->
          {m, :exact_match_already_member}

        nil ->
          # NOTE: not wrapped in `Repo.transaction` on purpose. A
          # constraint violation inside an open transaction puts
          # Postgres into an aborted state and any subsequent SQL
          # (the invite update below, the re-fetch on the race path)
          # fails. The two operations are individually safe and the
          # race-recovery path needs working SQL afterwards.
          case Workspaces.create_membership(%{
                 user_id: user.id,
                 workspace_id: workspace_id,
                 role: invite.role
               }) do
            {:ok, m} ->
              {m, :exact_match_accepted}

            {:error, %Ecto.Changeset{} = changeset} ->
              if unique_constraint_violation?(changeset) do
                # A concurrent OAuth callback inserted the membership
                # before us; the `(user_id, workspace_id)` unique
                # index caught the race. Re-fetch and treat the
                # outcome as "already member" — the membership is
                # there, just not from us.
                {Workspaces.get_membership(user, workspace_id), :exact_match_already_member}
              else
                # Genuinely unexpected — surface it rather than
                # silently swallow it as "already member".
                raise "Bank.Access.apply_exact_match: failed to create membership: " <>
                        inspect(changeset.errors)
              end
          end
      end

    {:ok, accepted} =
      invite
      |> AccessInvite.accept_changeset(user, now)
      |> Repo.update()

    # The `accept_changeset` flips status :active → :accepted on every
    # call (with a self-accept escape hatch for the race retry path).
    # Either way, after the update the invite reflects "matched on
    # this login", so the audit row is the right shape.
    safe_emit(Events.access_allowlist_matched(accepted, user, :exact_email_accepted))

    {outcome_tag, membership}
  end

  defp apply_domain_match(user, %AccessInvite{} = invite) do
    now = DateTime.utc_now()
    first_match? = is_nil(invite.matched_at)

    {:ok, updated} =
      invite
      |> AccessInvite.matched_changeset(user, now)
      |> Repo.update()

    # Idempotent: only emit on the first match. Subsequent logins
    # for the same domain invite are no-ops (matched_at preserved by
    # `matched_changeset`) and produce no audit row.
    if first_match?,
      do: safe_emit(Events.access_allowlist_matched(updated, user, :domain_matched))

    {:domain_match_pending, updated}
  end

  defp expire_stale_active_invites_for(%Ecto.Changeset{} = changeset) do
    workspace_id = Ecto.Changeset.get_field(changeset, :workspace_id)

    case Ecto.Changeset.get_field(changeset, :invite_type) do
      :exact_email ->
        email = Ecto.Changeset.get_field(changeset, :email)

        if is_binary(workspace_id) and is_binary(email),
          do: expire_stale_active_email_invites(workspace_id, email)

      :domain ->
        domain = Ecto.Changeset.get_field(changeset, :domain)

        if is_binary(workspace_id) and is_binary(domain),
          do: expire_stale_active_domain_invites(workspace_id, domain)

      _ ->
        :ok
    end

    :ok
  end

  defp expire_stale_active_email_invites(workspace_id, email_lower) do
    now = DateTime.utc_now()

    from(i in AccessInvite,
      where: i.workspace_id == ^workspace_id,
      where: i.invite_type == :exact_email,
      where: i.status == :active,
      where: not is_nil(i.expires_at) and i.expires_at <= ^now,
      where: fragment("lower(?)", i.email) == ^email_lower
    )
    |> Repo.update_all(set: [status: :expired, updated_at: now])
  end

  defp expire_stale_active_domain_invites(workspace_id, domain_lower) do
    now = DateTime.utc_now()

    from(i in AccessInvite,
      where: i.workspace_id == ^workspace_id,
      where: i.invite_type == :domain,
      where: i.status == :active,
      where: not is_nil(i.expires_at) and i.expires_at <= ^now,
      where: fragment("lower(?)", i.domain) == ^domain_lower
    )
    |> Repo.update_all(set: [status: :expired, updated_at: now])
  end

  defp unique_constraint_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_, {msg, _}} -> msg =~ "has already been taken"
    end)
  end

  # --- Admin (issue #157) -------------------------------------------------

  @doc """
  The lowercased + trimmed list of operator emails allowed to use
  the admin approve / reject surface during private alpha. Sourced
  from the `:bank, :admin_emails` config (set from
  `BANK_ADMIN_EMAILS` in `config/runtime.exs`).
  """
  @spec admin_emails() :: [String.t()]
  def admin_emails do
    :bank
    |> Application.get_env(:admin_emails, [])
    |> List.wrap()
    |> Enum.map(&normalise_email/1)
    |> Enum.reject(fn entry -> entry in [nil, ""] end)
  end

  @doc """
  Whether `user` is allowed to use the admin approve / reject
  surface. Backed by the `BANK_ADMIN_EMAILS` allowlist; this is a
  bootstrap-only guard that issue #159 replaces with role-based
  authorization once a workspace has stable owners.

  Returns `false` for `nil`, anonymous, or `:disabled` users.
  """
  @spec can_admin_access?(User.t() | nil) :: boolean()
  def can_admin_access?(nil), do: false
  def can_admin_access?(%User{status: :disabled}), do: false

  def can_admin_access?(%User{email: email}) when is_binary(email) do
    case normalise_email(email) do
      "" -> false
      nil -> false
      addr -> addr in admin_emails()
    end
  end

  def can_admin_access?(_), do: false

  @doc """
  Rows the admin /access page renders. A user is in the result iff:

    * their `status` is not `:disabled`, AND
    * they have zero active memberships.

  Each row carries a classification — `:domain_match` (a live domain
  invite is waiting), `:exact_match_pending` (a live exact-email
  invite is somehow still active despite the apply path; corner
  case), or `:allowlist_missed` (no live invite at all). The
  matching invite, when there is one, is included so the UI can
  show the workspace and role.

  Newest sign-ins first (most recent `last_login_at` then
  `inserted_at`). Capped at `opts[:limit]` (default 100, max 500).
  """
  @spec list_pending_access(keyword()) :: [pending_row()]
  def list_pending_access(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100) |> max(1) |> min(500)

    pending_users =
      from(u in User,
        left_join: m in Membership,
        on: m.user_id == u.id and m.status == :active,
        where: u.status != :disabled and is_nil(m.id),
        order_by: [
          desc_nulls_last: u.last_login_at,
          desc: u.inserted_at
        ],
        limit: ^limit
      )
      |> Repo.all()

    Enum.map(pending_users, &classify_pending/1)
  end

  @doc """
  Classify one user (by re-running the invite-matching read path).
  Useful from the pending-access screen, which has only the current
  user in scope.
  """
  @spec classify_pending(User.t()) :: pending_row()
  def classify_pending(%User{} = user) do
    case find_matching_invite_for_user(user) do
      %AccessInvite{invite_type: :exact_email} = invite ->
        %{user: user, classification: :exact_match_pending, invite: invite}

      %AccessInvite{invite_type: :domain} = invite ->
        %{user: user, classification: :domain_match, invite: invite}

      nil ->
        %{user: user, classification: :allowlist_missed, invite: nil}
    end
  end

  @doc """
  Admin-driven approve. Grants the target user a workspace
  membership.

  Resolution order for the target workspace + role:

    1. Explicit `opts[:workspace_id]` and `opts[:role]` — used as-is
       if both are supplied.
    2. The matching domain invite returned by
       `find_matching_invite_for_user/1` — used to fill in either
       missing field.
    3. Otherwise, returns `{:error, :workspace_target_required}` or
       `{:error, :role_required}` so the caller can prompt the
       admin for the missing piece.

  Idempotent:

    * Existing active membership for `(target, workspace)` →
      `{:ok, :already_member, _}`.
    * Existing inactive membership → reactivated;
      `{:ok, :membership_reactivated, _}`.
    * No membership → fresh insert; `{:ok, :membership_created, _}`.
    * Concurrent admin click that loses the unique-`(user_id,
      workspace_id)` race → re-fetches the membership and reports
      `:already_member` (matches the apply-invites race-handling
      from #264).

  Refuses self-approval (`{:error, :self_action}`) and refuses
  approving a `:disabled` user (`{:error, :user_disabled}`). The
  matched domain invite is left `:active` — domain invites are
  cohort-shaped, not single-use.
  """
  @spec approve_pending_user(User.t(), User.t(), keyword()) :: approve_result()
  def approve_pending_user(actor, target, opts \\ [])

  def approve_pending_user(%User{id: same_id}, %User{id: same_id}, _opts),
    do: {:error, :self_action}

  def approve_pending_user(%User{} = actor, %User{} = target, opts) do
    # Reload the target inside the function so a caller acting on a
    # stale list snapshot still sees current status. The
    # `:user_disabled` and `:already_member` paths both depend on
    # values that may have changed since the LiveView last rendered.
    case Accounts.get_user(target.id) do
      nil ->
        {:error, :not_found}

      %User{} = current ->
        cond do
          not can_admin_access?(actor) -> {:error, :unauthorized}
          current.status == :disabled -> {:error, :user_disabled}
          true -> do_approve(actor, current, opts)
        end
    end
  end

  defp do_approve(%User{} = actor, %User{} = target, opts) do
    matching = find_matching_invite_for_user(target)

    workspace_id =
      Keyword.get(opts, :workspace_id) ||
        (matching && matching.workspace_id)

    role = Keyword.get(opts, :role) || (matching && matching.role)

    cond do
      is_nil(workspace_id) -> {:error, :workspace_target_required}
      is_nil(role) -> {:error, :role_required}
      true -> upsert_membership(actor, target, workspace_id, role)
    end
  end

  defp upsert_membership(%User{} = actor, %User{} = target, workspace_id, role) do
    case Workspaces.get_membership(target, workspace_id) do
      %Membership{status: :active} = m ->
        # Idempotent no-op — no audit row.
        {:ok, :already_member, m}

      %Membership{status: :inactive} = m ->
        case Workspaces.set_status(m, :active) do
          {:ok, reactivated} ->
            safe_emit(Events.access_admin_approved(reactivated, actor, :inactive))
            _ = Bank.Notifications.Emitter.emit_access_approved(reactivated)
            {:ok, :membership_reactivated, reactivated}

          err ->
            err
        end

      nil ->
        case Workspaces.create_membership(%{
               user_id: target.id,
               workspace_id: workspace_id,
               role: role
             }) do
          {:ok, m} ->
            safe_emit(Events.access_admin_approved(m, actor, :no_membership))
            _ = Bank.Notifications.Emitter.emit_access_approved(m)
            {:ok, :membership_created, m}

          {:error, %Ecto.Changeset{} = changeset} ->
            # Same race shape as `apply_exact_match`: a concurrent
            # admin click won the unique-`(user_id, workspace_id)`
            # insert before us. Re-fetch and report idempotently.
            if unique_constraint_violation?(changeset) do
              case Workspaces.get_membership(target, workspace_id) do
                %Membership{status: :active} = m ->
                  # Race winner already emitted; no second event.
                  {:ok, :already_member, m}

                %Membership{} = m ->
                  case Workspaces.set_status(m, :active) do
                    {:ok, reactivated} ->
                      safe_emit(Events.access_admin_approved(reactivated, actor, :inactive))
                      _ = Bank.Notifications.Emitter.emit_access_approved(reactivated)
                      {:ok, :membership_reactivated, reactivated}

                    err ->
                      err
                  end

                nil ->
                  {:error, changeset}
              end
            else
              {:error, changeset}
            end
        end
    end
  end

  @doc """
  Admin-driven reject. Flips the target user to `:disabled` so
  subsequent OAuth callbacks refuse a session and the
  `FetchCurrentUser` plug clears any live session on the next
  request.

  Idempotent: rejecting an already-disabled user returns
  `{:ok, :already_disabled, user}`. Audit history is preserved —
  `access.invite_matched` and `access.allowlist_missed` rows from
  the invite flow stay intact. Domain invites are NOT auto-revoked;
  one rejected user does not revoke the cohort invite.

  Refuses self-rejection (`{:error, :self_action}`).
  """
  @spec reject_pending_user(User.t(), User.t(), keyword()) :: reject_result()
  def reject_pending_user(actor, target, opts \\ [])

  def reject_pending_user(%User{id: same_id}, %User{id: same_id}, _opts),
    do: {:error, :self_action}

  def reject_pending_user(%User{} = actor, %User{} = target, _opts) do
    case Accounts.get_user(target.id) do
      nil ->
        {:error, :not_found}

      %User{} = current ->
        cond do
          not can_admin_access?(actor) ->
            {:error, :unauthorized}

          current.status == :disabled ->
            # Idempotent no-op — no audit row.
            {:ok, :already_disabled, current}

          true ->
            prior_status = current.status

            case Accounts.disable_user(current) do
              {:ok, disabled} ->
                safe_emit(Events.access_admin_rejected(disabled, actor, prior_status))
                {:ok, :rejected, disabled}

              err ->
                err
            end
        end
    end
  end

  # --- Audit emission helper -----------------------------------------------

  # Audit failure must never roll back a committed state transition
  # (login, invite create, approve, reject). Swallow + log so the
  # caller's user-visible action proceeds even when the audit table
  # is briefly unavailable.
  defp safe_emit(attrs) do
    case Audit.append_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("Bank.Access: audit emission failed: #{inspect(reason)}")
        :ok
    end
  end
end
