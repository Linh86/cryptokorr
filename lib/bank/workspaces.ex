defmodule Bank.Workspaces do
  @moduledoc """
  Workspaces + memberships + access invites bounded context (epic
  #153, issues #155 + #156).

  Owns the `workspaces`, `memberships`, and `access_invites` tables
  and the read/write surface around them. Pairs with `Bank.Accounts`
  (identity) — this module answers "what can this user do, and
  where?".

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

  ## Invite / allowlist (issue #156)

    * `create_invite/2` — operator-driven; produces an `:active`
      invite for a workspace.
    * `revoke_invite/2` — terminal flip to `:revoked`.
    * `find_matching_invite_for_email/1` — pure read; lazily flips
      expired rows to `:expired` and returns the best (`:exact_email`
      preferred over `:domain`) live match, or `nil`.
    * `apply_invite_for_user/1` — auth-callback hook. On an
      `:exact_email` match it creates the membership and marks the
      invite `:accepted`. On a `:domain` match it records the match
      in audit but leaves the user in `:pending_access` (admin
      approval, #157, is what flips it). Always idempotent against
      a returning login.
    * `list_active_invites/2` — paged read for #157.

  ## What this module does NOT do

    * Enforce role-based authorization on actions. That's #159.
    * Apply the workspace filter to scoped tables. Counterparties,
      policies, etc. land in #158.
    * Render the admin approval UI. That's #157.
  """

  import Ecto.Query

  alias Bank.Accounts.User
  alias Bank.Audit
  alias Bank.Repo
  alias Bank.Workspaces.{AccessInvite, Membership, Workspace}
  alias Ecto.Multi

  require Logger

  @type uuid :: String.t()
  @type scope_resolution ::
          :no_membership
          | {:single, Membership.t()}
          | {:ambiguous, [Membership.t()]}

  @type apply_invite_result ::
          {:ok, :membership_created, Membership.t()}
          | {:ok, :pending_admin_approval, AccessInvite.t()}
          | {:ok, :no_match}
          | {:ok, :already_member}
          | {:error, :user_disabled}
          | {:error, term()}

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

  # --- Access invites (issue #156) ---

  @doc """
  Issue a new invite. Operator-driven. The acting user (the
  inviter) is required for the audit trail.

  `attrs` accepts either `:email` (with `invite_type: :exact_email`)
  or `:domain` (with `invite_type: :domain`). Email and domain
  values are normalised to lowercase and the schema's CHECK
  constraint enforces the (type, presence) shape.

  Emits `access.invite_created`.
  """
  @spec create_invite(User.t() | nil, map()) ::
          {:ok, AccessInvite.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_invite(actor, attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :invited_by_user_id, actor && actor.id)

    %AccessInvite{}
    |> AccessInvite.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, invite} ->
        emit_audit("access.invite_created", invite_audit_attrs(invite, actor))
        {:ok, invite}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Revoke an invite. No-op (`{:ok, invite}`) if it's already in a
  terminal state. Emits `access.invite_revoked` only on the actual
  state flip.
  """
  @spec revoke_invite(User.t() | nil, uuid() | AccessInvite.t()) ::
          {:ok, AccessInvite.t()} | {:error, term()}
  def revoke_invite(actor, %AccessInvite{} = invite), do: do_revoke(actor, invite)

  def revoke_invite(actor, invite_id) when is_binary(invite_id) do
    case Repo.get(AccessInvite, invite_id) do
      nil -> {:error, :not_found}
      %AccessInvite{} = invite -> do_revoke(actor, invite)
    end
  end

  defp do_revoke(_actor, %AccessInvite{status: status} = invite)
       when status in [:revoked, :accepted, :expired] do
    {:ok, invite}
  end

  defp do_revoke(actor, %AccessInvite{status: :active} = invite) do
    case invite |> AccessInvite.revoke_changeset() |> Repo.update() do
      {:ok, revoked} ->
        emit_audit("access.invite_revoked", %{
          actor: audit_actor(actor),
          actor_id: audit_actor_id(actor),
          subject_type: "access_invite",
          subject_id: revoked.id,
          correlation_id: revoked.id,
          before_ref: %{"status" => "active"},
          after_ref: %{"status" => "revoked"}
        })

        {:ok, revoked}

      err ->
        err
    end
  end

  @doc """
  Find the best invite that matches `email`. Returns `nil` if none.

  Matching rules:

    * Email is normalised to lowercase + trimmed.
    * Exact-email match (case-insensitive) beats domain match.
    * Only `:active` invites with `expires_at` either nil or in the
      future are eligible.
    * If an `:active` invite is encountered with `expires_at` in the
      past, it is flipped to `:expired` here (lazy expiry) and not
      returned.

  This function never creates memberships or audit events; it is the
  pure read used by `apply_invite_for_user/1` and (later, #157) by
  the admin UI.
  """
  @spec find_matching_invite_for_email(String.t()) :: AccessInvite.t() | nil
  def find_matching_invite_for_email(email) when is_binary(email) do
    normalised = email |> String.trim() |> String.downcase()

    case {normalised, extract_domain(normalised)} do
      {"", _} ->
        nil

      {_, nil} ->
        nil

      {addr, domain} ->
        case best_active_invite(:exact_email, addr) do
          %AccessInvite{} = invite -> invite
          nil -> best_active_invite(:domain, domain)
        end
    end
  end

  def find_matching_invite_for_email(_), do: nil

  defp best_active_invite(:exact_email, email) do
    AccessInvite
    |> where([i], i.invite_type == :exact_email and i.status == :active)
    |> where([i], fragment("lower(?)", i.email) == ^email)
    |> order_by([i], asc: i.inserted_at)
    |> Repo.all()
    |> first_eligible_or_expire()
  end

  defp best_active_invite(:domain, domain) do
    AccessInvite
    |> where([i], i.invite_type == :domain and i.status == :active)
    |> where([i], fragment("lower(?)", i.domain) == ^domain)
    |> order_by([i], asc: i.inserted_at)
    |> Repo.all()
    |> first_eligible_or_expire()
  end

  defp first_eligible_or_expire([]), do: nil

  defp first_eligible_or_expire([%AccessInvite{} = invite | rest]) do
    cond do
      expired?(invite) ->
        {:ok, _} = invite |> AccessInvite.expire_changeset() |> Repo.update()
        first_eligible_or_expire(rest)

      true ->
        invite
    end
  end

  defp expired?(%AccessInvite{expires_at: nil}), do: false

  defp expired?(%AccessInvite{expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  @doc """
  Apply any matching invite for `user` against their email.

  Outcomes (also documented on `@type apply_invite_result/0`):

    * `{:ok, :membership_created, %Membership{}}` — exact-email
      invite matched and a fresh membership was created. The invite
      is marked `:accepted`. Emits `access.invite_matched`.
    * `{:ok, :pending_admin_approval, %AccessInvite{}}` — domain
      invite matched but membership is deferred to admin approval
      (#157). The invite stays `:active`. Emits
      `access.invite_matched`.
    * `{:ok, :no_match}` — no live invite for this email. Emits
      `access.allowlist_missed`.
    * `{:ok, :already_member}` — the user is already in at least
      one workspace. No invite work is performed; no audit. The
      caller's `resolve_scope/1` already handles the routing.
    * `{:error, :user_disabled}` — `:disabled` users are never
      reactivated by an invite. No state change, no audit beyond
      the disabled-user log.
  """
  @spec apply_invite_for_user(User.t()) :: apply_invite_result()
  def apply_invite_for_user(%User{status: :disabled}), do: {:error, :user_disabled}

  def apply_invite_for_user(%User{} = user) do
    case list_active_memberships(user) do
      [] -> apply_invite_with_no_membership(user)
      _ -> {:ok, :already_member}
    end
  end

  defp apply_invite_with_no_membership(%User{email: email} = user) do
    case find_matching_invite_for_email(email) do
      nil ->
        emit_audit("access.allowlist_missed", %{
          actor: :runtime,
          actor_id: nil,
          subject_type: "user",
          subject_id: user.id,
          correlation_id: user.id,
          after_ref: %{"email" => email}
        })

        {:ok, :no_match}

      %AccessInvite{invite_type: :exact_email} = invite ->
        accept_exact_email_invite(user, invite)

      %AccessInvite{invite_type: :domain} = invite ->
        emit_match_audit(user, invite, false)
        {:ok, :pending_admin_approval, invite}
    end
  end

  defp accept_exact_email_invite(%User{} = user, %AccessInvite{} = invite) do
    multi =
      Multi.new()
      |> Multi.insert(:membership, fn _ ->
        Membership.create_changeset(%Membership{}, %{
          user_id: user.id,
          workspace_id: invite.workspace_id,
          role: invite.role,
          status: :active
        })
      end)
      |> Multi.update(:invite, AccessInvite.accept_changeset(invite, user))

    case Repo.transaction(multi) do
      {:ok, %{membership: membership}} ->
        emit_match_audit(user, invite, true)
        {:ok, :membership_created, membership}

      {:error, :membership, %Ecto.Changeset{errors: errors} = changeset, _} ->
        # If a membership already exists (race or replay), treat the
        # invite as already accepted and return :already_member.
        if Keyword.has_key?(errors, :user_id) or Keyword.has_key?(errors, :workspace_id) do
          {:ok, :already_member}
        else
          {:error, changeset}
        end

      {:error, step, reason, _} ->
        Logger.warning(
          "Workspaces.apply_invite_for_user: multi failed at #{step}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Page through `:active` invites for a workspace. Used by the admin
  console (#157). Ordered oldest-first.

  Pass `:limit` to cap the result; default 50, max 500.
  """
  @spec list_active_invites(uuid(), keyword()) :: [AccessInvite.t()]
  def list_active_invites(workspace_id, opts \\ []) when is_binary(workspace_id) do
    limit = Keyword.get(opts, :limit, 50) |> max(1) |> min(500)

    AccessInvite
    |> where([i], i.workspace_id == ^workspace_id and i.status == :active)
    |> order_by([i], asc: i.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # --- internals ---

  defp extract_domain(normalised_email) do
    case String.split(normalised_email, "@", parts: 2) do
      [_local, domain] when domain != "" -> domain
      _ -> nil
    end
  end

  defp invite_audit_attrs(%AccessInvite{} = invite, actor) do
    after_ref =
      %{
        "invite_type" => Atom.to_string(invite.invite_type),
        "workspace_id" => invite.workspace_id,
        "role" => Atom.to_string(invite.role),
        "expires_at" => invite.expires_at && DateTime.to_iso8601(invite.expires_at)
      }
      |> Map.merge(invite_target_ref(invite))

    %{
      actor: audit_actor(actor),
      actor_id: audit_actor_id(actor),
      subject_type: "access_invite",
      subject_id: invite.id,
      correlation_id: invite.id,
      after_ref: after_ref
    }
  end

  defp invite_target_ref(%AccessInvite{invite_type: :exact_email, email: email}),
    do: %{"email" => email}

  defp invite_target_ref(%AccessInvite{invite_type: :domain, domain: domain}),
    do: %{"domain" => domain}

  defp emit_match_audit(%User{} = user, %AccessInvite{} = invite, membership_created?) do
    emit_audit("access.invite_matched", %{
      actor: :runtime,
      actor_id: nil,
      subject_type: "user",
      subject_id: user.id,
      correlation_id: invite.id,
      after_ref:
        %{
          "matched_via" => Atom.to_string(invite.invite_type),
          "workspace_id" => invite.workspace_id,
          "membership_created" => membership_created?,
          "user_id" => user.id
        }
        |> Map.merge(invite_target_ref(invite))
    })
  end

  defp audit_actor(nil), do: :runtime
  defp audit_actor(%User{}), do: :user

  defp audit_actor_id(nil), do: nil
  defp audit_actor_id(%User{id: id}), do: id

  defp emit_audit(event_type, attrs) do
    case Audit.append_event(Map.put(attrs, :event_type, event_type)) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        # Audit failure must never silently corrupt the invite flow,
        # but it must also not roll the membership/invite write back
        # — those have already committed by the time we get here.
        # Log it loudly so an operator can reconcile.
        Logger.error(
          "Workspaces audit emit failed (event=#{event_type}, reason=#{inspect(reason)})"
        )

        :ok
    end
  end
end
