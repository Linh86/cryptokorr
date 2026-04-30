defmodule Bank.AccessAuditTest do
  @moduledoc """
  Audit emission for the access lifecycle (issue #161). Every test
  exercises a `Bank.Access` entry point and asserts on the resulting
  audit row(s) — shape, idempotency, and (where relevant) the
  absence of an event when the operation was a no-op.

  Lives in its own file so `Bank.AccessTest` and
  `Bank.AccessAdminTest` stay focused on their respective surfaces.
  """

  use Bank.DataCase, async: false

  alias Bank.Access
  alias Bank.Access.AccessInvite
  alias Bank.Accounts
  alias Bank.Audit
  alias Bank.Audit.AuditEvent
  alias Bank.Workspaces

  setup do
    Application.put_env(:bank, :admin_emails, [])
    on_exit(fn -> Application.put_env(:bank, :admin_emails, []) end)
    :ok
  end

  defp put_admins(emails), do: Application.put_env(:bank, :admin_emails, emails)

  defp create_user(opts \\ []) do
    email = Keyword.get(opts, :email, "user-#{unique()}@example.com")
    subject = Keyword.get(opts, :subject, "google-#{unique()}")

    {:ok, user} =
      Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: subject,
        email: email,
        name: Keyword.get(opts, :name, "User")
      })

    case Keyword.get(opts, :status) do
      :disabled ->
        {:ok, u} = Accounts.disable_user(user)
        u

      _ ->
        user
    end
  end

  defp create_workspace(slug \\ nil) do
    slug = slug || "ws-#{unique()}"
    {:ok, ws} = Workspaces.create_workspace(%{slug: slug, name: "Display #{slug}"})
    ws
  end

  defp unique, do: System.unique_integer([:positive])

  defp events_for(filters) do
    Audit.list_events(filters, limit: 100).events
  end

  describe "access.invite_created" do
    test "is emitted when create_invite succeeds" do
      ws = create_workspace()
      admin = create_user()

      {:ok, invite} =
        Access.create_invite(
          %{
            workspace_id: ws.id,
            invite_type: :exact_email,
            email: "alice@example.com",
            role: :operator
          },
          admin
        )

      assert [%AuditEvent{} = event] =
               events_for(%{event_type: "access.invite_created", subject_id: invite.id})

      assert event.actor == :user
      assert event.actor_id == admin.id
      assert event.subject_type == "access_invite"
      assert event.subject_id == invite.id
      assert event.correlation_id == invite.id
      assert event.after_ref["invite_type"] == "exact_email"
      assert event.after_ref["email"] == "alice@example.com"
      assert event.after_ref["role"] == "operator"
      assert event.after_ref["workspace_id"] == ws.id
    end

    test "is NOT emitted on a failed insert" do
      ws = create_workspace()
      admin = create_user()

      assert {:error, _} =
               Access.create_invite(%{workspace_id: ws.id, invite_type: :exact_email}, admin)

      assert [] = events_for(%{event_type: "access.invite_created"})
    end
  end

  describe "access.invite_revoked" do
    test "is emitted when revoke_invite succeeds" do
      ws = create_workspace()
      admin = create_user()

      {:ok, invite} =
        Access.create_invite(
          %{
            workspace_id: ws.id,
            invite_type: :exact_email,
            email: "alice@example.com",
            role: :operator
          },
          admin
        )

      assert {:ok, revoked} = Access.revoke_invite(invite, admin)

      assert [%AuditEvent{} = event] =
               events_for(%{event_type: "access.invite_revoked", subject_id: invite.id})

      assert event.actor == :user
      assert event.actor_id == admin.id
      assert event.subject_id == invite.id
      assert event.correlation_id == invite.id
      assert event.before_ref["status"] == "active"
      assert event.after_ref["status"] == "revoked"
      assert event.after_ref["revoked_by_user_id"] == admin.id
      assert is_binary(event.after_ref["revoked_at"])
      assert revoked.status == :revoked
    end

    test "is NOT emitted when revoke fails (already revoked)" do
      ws = create_workspace()
      admin = create_user()

      {:ok, invite} =
        Access.create_invite(
          %{
            workspace_id: ws.id,
            invite_type: :exact_email,
            email: "alice@example.com",
            role: :viewer
          },
          admin
        )

      {:ok, revoked} = Access.revoke_invite(invite, admin)

      # Pass the post-revoke struct so the changeset's
      # `validate_revokable` guard fires.
      assert {:error, _} = Access.revoke_invite(revoked, admin)
      assert [_one] = events_for(%{event_type: "access.invite_revoked", subject_id: invite.id})
    end
  end

  describe "access.allowlist_matched (exact-email)" do
    test "fires once per exact-email accept on login" do
      ws = create_workspace()
      admin = create_user()
      target = create_user(email: "alice@example.com")

      {:ok, invite} =
        Access.create_invite(
          %{
            workspace_id: ws.id,
            invite_type: :exact_email,
            email: "alice@example.com",
            role: :operator
          },
          admin
        )

      assert [_outcome] = Access.apply_invites_for_user(target)

      assert [%AuditEvent{} = event] =
               events_for(%{event_type: "access.allowlist_matched", subject_id: invite.id})

      assert event.actor_id == target.id
      assert event.correlation_id == target.id
      assert event.after_ref["match_type"] == "exact_email_accepted"
      assert event.after_ref["status"] == "accepted"
      assert event.after_ref["workspace_id"] == ws.id
      assert event.after_ref["role"] == "operator"
    end
  end

  describe "access.allowlist_matched (domain)" do
    test "fires once on the first domain match and is idempotent on repeat login" do
      ws = create_workspace()
      admin = create_user()
      target = create_user(email: "carol@partner.io")

      {:ok, invite} =
        Access.create_invite(
          %{
            workspace_id: ws.id,
            invite_type: :domain,
            domain: "partner.io",
            role: :viewer
          },
          admin
        )

      assert [{:domain_match_pending, _}] = Access.apply_invites_for_user(target)
      assert [_one] = events_for(%{event_type: "access.allowlist_matched", subject_id: invite.id})

      # Returning login: matched_at preserved → no new event.
      assert [{:domain_match_pending, _}] = Access.apply_invites_for_user(target)

      assert [_still_one] =
               events_for(%{event_type: "access.allowlist_matched", subject_id: invite.id})
    end

    test "carries match_type and the user's correlation id" do
      ws = create_workspace()
      admin = create_user()
      target = create_user(email: "carol@partner.io")

      {:ok, _invite} =
        Access.create_invite(
          %{workspace_id: ws.id, invite_type: :domain, domain: "partner.io", role: :viewer},
          admin
        )

      Access.apply_invites_for_user(target)

      assert [event] = events_for(%{event_type: "access.allowlist_matched"})
      assert event.actor_id == target.id
      assert event.correlation_id == target.id
      assert event.after_ref["match_type"] == "domain_matched"
      assert event.after_ref["invite_type"] == "domain"
    end
  end

  describe "access.allowlist_missed" do
    test "fires when login produces no matching invite" do
      _ws = create_workspace()
      target = create_user(email: "stranger@nowhere.org")

      assert [] = Access.apply_invites_for_user(target)

      assert [event] =
               events_for(%{event_type: "access.allowlist_missed", subject_id: target.id})

      assert event.actor_id == target.id
      assert event.subject_type == "user"
      assert event.correlation_id == target.id
      assert event.after_ref["no_matching_invites"] == true
      assert event.after_ref["email"] == "stranger@nowhere.org"
    end

    test "does NOT fire when at least one invite matches" do
      ws = create_workspace()
      admin = create_user()
      target = create_user(email: "alice@example.com")

      {:ok, _} =
        Access.create_invite(
          %{
            workspace_id: ws.id,
            invite_type: :exact_email,
            email: "alice@example.com",
            role: :operator
          },
          admin
        )

      Access.apply_invites_for_user(target)

      assert [] = events_for(%{event_type: "access.allowlist_missed", subject_id: target.id})
    end

    test "is NOT emitted for a disabled user (apply short-circuits)" do
      target = create_user(email: "doomed@example.com", status: :disabled)

      assert [:user_disabled] = Access.apply_invites_for_user(target)
      assert [] = events_for(%{event_type: "access.allowlist_missed", subject_id: target.id})
    end
  end

  describe "access.admin_approved" do
    test "fires when a fresh membership is created via approve" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("approve")

      {:ok, _} =
        Access.create_invite(
          %{
            workspace_id: ws.id,
            invite_type: :domain,
            domain: "match.example",
            role: :operator
          },
          admin
        )

      target = create_user(email: "alice@match.example")

      assert {:ok, :membership_created, membership} =
               Access.approve_pending_user(admin, target)

      assert [event] =
               events_for(%{event_type: "access.admin_approved", subject_id: membership.id})

      assert event.actor == :user
      assert event.actor_id == admin.id
      assert event.subject_type == "membership"
      assert event.correlation_id == target.id
      assert event.before_ref["status"] == "no_membership"
      assert event.after_ref["status"] == "active"
      assert event.after_ref["role"] == "operator"
      assert event.after_ref["workspace_id"] == ws.id
      assert event.after_ref["user_id"] == target.id
    end

    test "fires with prior_status = inactive when reactivating" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("reactivate")
      target = create_user(email: "alice@reactivate.example")

      {:ok, m} =
        Workspaces.create_membership(%{
          user_id: target.id,
          workspace_id: ws.id,
          role: :viewer,
          status: :inactive
        })

      assert {:ok, :membership_reactivated, _} =
               Access.approve_pending_user(admin, target,
                 workspace_id: ws.id,
                 role: :viewer
               )

      assert [event] = events_for(%{event_type: "access.admin_approved", subject_id: m.id})
      assert event.before_ref["status"] == "inactive"
      assert event.after_ref["status"] == "active"
    end

    test "does NOT fire on the :already_member idempotent path" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("idempotent")

      {:ok, _} =
        Access.create_invite(
          %{
            workspace_id: ws.id,
            invite_type: :domain,
            domain: "idem.example",
            role: :viewer
          },
          admin
        )

      target = create_user(email: "alice@idem.example")
      assert {:ok, :membership_created, _} = Access.approve_pending_user(admin, target)
      assert {:ok, :already_member, _} = Access.approve_pending_user(admin, target)

      # Exactly one approved event despite two approve calls.
      assert [_one] = events_for(%{event_type: "access.admin_approved"})
    end

    test "does NOT fire on unauthorized actor" do
      put_admins([])
      actor = create_user(email: "stranger@example.com")
      target = create_user(email: "victim@example.com")

      assert {:error, :unauthorized} = Access.approve_pending_user(actor, target)
      assert [] = events_for(%{event_type: "access.admin_approved"})
    end
  end

  describe "access.admin_rejected" do
    test "fires when a pending user is disabled" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "doomed@example.com")

      assert {:ok, :rejected, disabled} = Access.reject_pending_user(admin, target)

      assert [event] = events_for(%{event_type: "access.admin_rejected", subject_id: target.id})
      assert event.actor == :user
      assert event.actor_id == admin.id
      assert event.subject_type == "user"
      assert event.correlation_id == target.id
      assert event.before_ref["status"] == "pending_access"
      assert event.after_ref["status"] == "disabled"
      assert event.after_ref["email"] == disabled.email
    end

    test "does NOT fire on the :already_disabled idempotent path" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "ex@example.com", status: :disabled)

      assert {:ok, :already_disabled, _} = Access.reject_pending_user(admin, target)
      assert [] = events_for(%{event_type: "access.admin_rejected", subject_id: target.id})
    end

    test "does NOT fire on unauthorized actor" do
      put_admins([])
      actor = create_user()
      target = create_user()

      assert {:error, :unauthorized} = Access.reject_pending_user(actor, target)
      assert [] = events_for(%{event_type: "access.admin_rejected"})
    end
  end
end
