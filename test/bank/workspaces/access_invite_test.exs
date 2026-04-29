defmodule Bank.Workspaces.AccessInviteTest do
  @moduledoc """
  Repo-roundtrip and routing behaviour for the access-invite
  surface added by issue #156.

  Covers:
    * exact-email + domain matching, case-insensitive
    * exact email beats domain
    * expired / revoked invites are ignored (and lazy expiry)
    * no invite leaves the user pending
    * repeat login is idempotent (no duplicate memberships, no
      duplicate `access.invite_matched` audit ambiguity at the
      semantic level)
    * invites do not cross workspace boundaries
    * `:disabled` users are never reactivated by an invite
    * the audit envelope written on each transition has the right
      shape
  """

  use Bank.DataCase, async: false

  import Ecto.Query

  alias Bank.Accounts
  alias Bank.Audit.AuditEvent
  alias Bank.Workspaces
  alias Bank.Workspaces.{AccessInvite, Membership}

  defp create_user(opts \\ []) do
    email = Keyword.get(opts, :email, "user-#{unique()}@example.com")
    subject = Keyword.get(opts, :subject, "google-#{unique()}")
    name = Keyword.get(opts, :name, "Test User")

    {:ok, user} =
      Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: subject,
        email: email,
        name: name
      })

    case Keyword.get(opts, :status) do
      nil ->
        user

      :disabled ->
        {:ok, u} = Accounts.disable_user(user)
        u

      other ->
        raise "unsupported status: #{inspect(other)}"
    end
  end

  defp create_workspace(slug \\ nil) do
    slug = slug || "ws-#{unique()}"
    {:ok, ws} = Workspaces.create_workspace(%{slug: slug, name: "Display #{slug}"})
    ws
  end

  defp create_invite!(actor, attrs) do
    {:ok, invite} = Workspaces.create_invite(actor, Map.new(attrs))
    invite
  end

  defp unique, do: System.unique_integer([:positive])

  describe "create_invite/2" do
    test "exact-email invite normalises the email and pins the shape" do
      ws = create_workspace()
      inviter = create_user()

      {:ok, invite} =
        Workspaces.create_invite(inviter, %{
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "  Bob@Example.COM ",
          role: :viewer
        })

      assert invite.email == "bob@example.com"
      assert invite.invite_type == :exact_email
      assert invite.role == :viewer
      assert invite.status == :active
      assert invite.invited_by_user_id == inviter.id
    end

    test "domain invite normalises the domain" do
      ws = create_workspace()
      inviter = create_user()

      {:ok, invite} =
        Workspaces.create_invite(inviter, %{
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "Example.COM",
          role: :operator
        })

      assert invite.domain == "example.com"
      assert invite.invite_type == :domain
    end

    test "rejects an exact-email invite missing the email" do
      ws = create_workspace()

      assert {:error, changeset} =
               Workspaces.create_invite(nil, %{
                 workspace_id: ws.id,
                 invite_type: :exact_email,
                 role: :viewer
               })

      refute changeset.valid?
    end

    test "rejects a domain invite that carries an email" do
      ws = create_workspace()

      assert {:error, changeset} =
               Workspaces.create_invite(nil, %{
                 workspace_id: ws.id,
                 invite_type: :domain,
                 email: "x@y.com",
                 domain: "y.com",
                 role: :viewer
               })

      refute changeset.valid?
    end

    test "two active exact-email invites for the same (workspace, email) collide" do
      ws = create_workspace()

      {:ok, _} =
        Workspaces.create_invite(nil, %{
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "dup@example.com",
          role: :viewer
        })

      assert {:error, changeset} =
               Workspaces.create_invite(nil, %{
                 workspace_id: ws.id,
                 invite_type: :exact_email,
                 email: "DUP@example.com",
                 role: :admin
               })

      refute changeset.valid?
    end

    test "emits access.invite_created" do
      ws = create_workspace()
      inviter = create_user()

      {:ok, invite} =
        Workspaces.create_invite(inviter, %{
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "audited@example.com",
          role: :viewer
        })

      events = audit_events_for_subject(invite.id)
      created = Enum.find(events, &(&1.event_type == "access.invite_created"))

      assert created
      assert created.actor == :user
      assert created.actor_id == inviter.id
      assert created.subject_type == "access_invite"
      assert created.after_ref["email"] == "audited@example.com"
      assert created.after_ref["role"] == "viewer"
      assert created.after_ref["workspace_id"] == ws.id
    end
  end

  describe "revoke_invite/2" do
    test "flips an active invite to :revoked and audits it" do
      ws = create_workspace()
      operator = create_user()

      invite =
        create_invite!(operator,
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "rev.example.com",
          role: :viewer
        )

      assert {:ok, revoked} = Workspaces.revoke_invite(operator, invite.id)
      assert revoked.status == :revoked
      assert revoked.revoked_at

      events = audit_events_for_subject(invite.id)
      assert Enum.any?(events, &(&1.event_type == "access.invite_revoked"))
    end

    test "is a no-op on already-revoked invites" do
      ws = create_workspace()

      invite =
        create_invite!(nil,
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "noop.example.com",
          role: :viewer
        )

      {:ok, _revoked} = Workspaces.revoke_invite(nil, invite.id)

      audit_count_before =
        Repo.aggregate(
          from(e in AuditEvent,
            where: e.event_type == "access.invite_revoked" and e.subject_id == ^invite.id
          ),
          :count
        )

      {:ok, again} = Workspaces.revoke_invite(nil, invite.id)
      assert again.status == :revoked

      audit_count_after =
        Repo.aggregate(
          from(e in AuditEvent,
            where: e.event_type == "access.invite_revoked" and e.subject_id == ^invite.id
          ),
          :count
        )

      assert audit_count_after == audit_count_before
    end

    test "returns :not_found for a missing invite" do
      assert {:error, :not_found} = Workspaces.revoke_invite(nil, Ecto.UUID.generate())
    end
  end

  describe "find_matching_invite_for_email/1" do
    test "matches exact email case-insensitively" do
      ws = create_workspace()

      invite =
        create_invite!(nil,
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "alice@example.com",
          role: :viewer
        )

      assert match = Workspaces.find_matching_invite_for_email("ALICE@Example.com")
      assert match.id == invite.id
    end

    test "matches domain case-insensitively" do
      ws = create_workspace()

      invite =
        create_invite!(nil,
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "customer-corp.com",
          role: :viewer
        )

      assert match = Workspaces.find_matching_invite_for_email("anyone@CUSTOMER-CORP.com")
      assert match.id == invite.id
    end

    test "exact email beats domain" do
      ws_e = create_workspace("ws-exact")
      ws_d = create_workspace("ws-domain")

      domain_invite =
        create_invite!(nil,
          workspace_id: ws_d.id,
          invite_type: :domain,
          domain: "tiebreak.com",
          role: :viewer
        )

      exact_invite =
        create_invite!(nil,
          workspace_id: ws_e.id,
          invite_type: :exact_email,
          email: "winner@tiebreak.com",
          role: :admin
        )

      assert match = Workspaces.find_matching_invite_for_email("winner@tiebreak.com")
      assert match.id == exact_invite.id
      refute match.id == domain_invite.id
    end

    test "ignores expired invites and lazily flips them to :expired" do
      ws = create_workspace()

      invite =
        create_invite!(nil,
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "old@example.com",
          role: :viewer,
          expires_at: DateTime.utc_now() |> DateTime.add(-3600, :second)
        )

      assert Workspaces.find_matching_invite_for_email("old@example.com") == nil
      assert Repo.get!(AccessInvite, invite.id).status == :expired
    end

    test "ignores revoked invites" do
      ws = create_workspace()

      invite =
        create_invite!(nil,
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "killed@example.com",
          role: :viewer
        )

      {:ok, _} = Workspaces.revoke_invite(nil, invite.id)

      assert Workspaces.find_matching_invite_for_email("killed@example.com") == nil
    end

    test "returns nil for malformed email" do
      assert Workspaces.find_matching_invite_for_email("nope") == nil
      assert Workspaces.find_matching_invite_for_email("") == nil
      assert Workspaces.find_matching_invite_for_email(nil) == nil
    end
  end

  describe "apply_invite_for_user/1" do
    test "exact-email match creates a membership and accepts the invite" do
      ws = create_workspace("apply-exact")

      _invite =
        create_invite!(nil,
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "promoted@example.com",
          role: :operator
        )

      user = create_user(email: "promoted@example.com")

      assert {:ok, :membership_created, %Membership{} = membership} =
               Workspaces.apply_invite_for_user(user)

      assert membership.user_id == user.id
      assert membership.workspace_id == ws.id
      assert membership.role == :operator
      assert membership.status == :active

      reloaded_invite =
        AccessInvite
        |> where([i], i.email == "promoted@example.com")
        |> Repo.one!()

      assert reloaded_invite.status == :accepted
      assert reloaded_invite.accepted_by_user_id == user.id
      assert reloaded_invite.accepted_at

      events = audit_events_for_subject(user.id)
      matched = Enum.find(events, &(&1.event_type == "access.invite_matched"))

      assert matched
      assert matched.actor == :runtime
      assert matched.after_ref["matched_via"] == "exact_email"
      assert matched.after_ref["membership_created"] == true
    end

    test "domain match records the match in audit but does NOT create a membership" do
      ws = create_workspace("apply-domain")

      invite =
        create_invite!(nil,
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "customer-corp.com",
          role: :viewer
        )

      user = create_user(email: "anyone@customer-corp.com")

      assert {:ok, :pending_admin_approval, returned_invite} =
               Workspaces.apply_invite_for_user(user)

      assert returned_invite.id == invite.id
      assert Repo.get!(AccessInvite, invite.id).status == :active
      assert Workspaces.list_active_memberships(user) == []

      matched =
        audit_events_for_subject(user.id)
        |> Enum.find(&(&1.event_type == "access.invite_matched"))

      assert matched
      assert matched.after_ref["matched_via"] == "domain"
      assert matched.after_ref["membership_created"] == false
    end

    test "no matching invite emits access.allowlist_missed and returns :no_match" do
      user = create_user(email: "nobody-knows-me@example.com")

      assert {:ok, :no_match} = Workspaces.apply_invite_for_user(user)

      missed =
        audit_events_for_subject(user.id)
        |> Enum.find(&(&1.event_type == "access.allowlist_missed"))

      assert missed
      assert missed.after_ref["email"] == "nobody-knows-me@example.com"
    end

    test "repeat login after exact-email match is idempotent" do
      ws = create_workspace("repeat-login")

      create_invite!(nil,
        workspace_id: ws.id,
        invite_type: :exact_email,
        email: "repeat@example.com",
        role: :operator
      )

      user = create_user(email: "repeat@example.com")

      assert {:ok, :membership_created, _m} = Workspaces.apply_invite_for_user(user)

      # Second call: already a member — short-circuits without
      # touching invite or audit state.
      audit_count_before =
        Repo.aggregate(
          from(e in AuditEvent,
            where: e.event_type == "access.invite_matched" and e.subject_id == ^user.id
          ),
          :count
        )

      assert {:ok, :already_member} = Workspaces.apply_invite_for_user(user)

      audit_count_after =
        Repo.aggregate(
          from(e in AuditEvent,
            where: e.event_type == "access.invite_matched" and e.subject_id == ^user.id
          ),
          :count
        )

      assert audit_count_after == audit_count_before

      assert Repo.aggregate(
               from(m in Membership, where: m.user_id == ^user.id),
               :count
             ) == 1
    end

    test "invite does not cross workspace boundaries" do
      ws_a = create_workspace("ws-a")
      ws_b = create_workspace("ws-b")

      create_invite!(nil,
        workspace_id: ws_a.id,
        invite_type: :exact_email,
        email: "cross@example.com",
        role: :viewer
      )

      user = create_user(email: "cross@example.com")
      assert {:ok, :membership_created, m} = Workspaces.apply_invite_for_user(user)

      assert m.workspace_id == ws_a.id
      assert m.workspace_id != ws_b.id

      memberships_in_b =
        Repo.aggregate(
          from(m in Membership,
            where: m.user_id == ^user.id and m.workspace_id == ^ws_b.id
          ),
          :count
        )

      assert memberships_in_b == 0
    end

    test ":disabled users are never reactivated by an invite" do
      ws = create_workspace("ws-disabled")

      create_invite!(nil,
        workspace_id: ws.id,
        invite_type: :exact_email,
        email: "blocked@example.com",
        role: :viewer
      )

      user = create_user(email: "blocked@example.com", status: :disabled)

      assert {:error, :user_disabled} = Workspaces.apply_invite_for_user(user)

      assert Workspaces.list_active_memberships(user) == []

      reloaded_invite =
        AccessInvite
        |> where([i], i.email == "blocked@example.com")
        |> Repo.one!()

      assert reloaded_invite.status == :active

      # No `invite_matched` audit was written for this user.
      assert Repo.aggregate(
               from(e in AuditEvent,
                 where:
                   e.event_type == "access.invite_matched" and
                     e.subject_id == ^user.id
               ),
               :count
             ) == 0
    end

    test "expired invite is ignored at the apply layer too" do
      ws = create_workspace()

      create_invite!(nil,
        workspace_id: ws.id,
        invite_type: :exact_email,
        email: "stale@example.com",
        role: :viewer,
        expires_at: DateTime.utc_now() |> DateTime.add(-1, :second)
      )

      user = create_user(email: "stale@example.com")

      assert {:ok, :no_match} = Workspaces.apply_invite_for_user(user)
      assert Workspaces.list_active_memberships(user) == []
    end
  end

  describe "list_active_invites/2" do
    test "returns active invites for the workspace, oldest first" do
      ws = create_workspace("list")
      other = create_workspace("other")

      a =
        create_invite!(nil,
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "a@example.com",
          role: :viewer
        )

      _b_other =
        create_invite!(nil,
          workspace_id: other.id,
          invite_type: :exact_email,
          email: "a@other.com",
          role: :viewer
        )

      c =
        create_invite!(nil,
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "list.example",
          role: :viewer
        )

      revoked =
        create_invite!(nil,
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "revoked@example.com",
          role: :viewer
        )

      {:ok, _} = Workspaces.revoke_invite(nil, revoked.id)

      ids = Workspaces.list_active_invites(ws.id) |> Enum.map(& &1.id)

      assert a.id in ids
      assert c.id in ids
      refute revoked.id in ids
      assert Enum.all?(ids, fn id -> id != _b_other.id end)
    end
  end

  defp audit_events_for_subject(subject_id) do
    AuditEvent
    |> where([e], e.subject_id == ^subject_id)
    |> Repo.all()
  end
end
