defmodule Bank.AccessAdminTest do
  @moduledoc """
  Repo-roundtrip behaviour for the admin approve / reject surface
  added by issue #157.

  Covers:
    * `can_admin_access?/1` against the BANK_ADMIN_EMAILS allowlist
    * `list_pending_access/1` filters and classifies
    * `approve_pending_user/3` matrix: matched / explicit /
      idempotent / inactive-revival / disabled / unauthorized /
      self-action
    * `reject_pending_user/3` matrix: ok / already_disabled /
      unauthorized / self-action
  """

  use Bank.DataCase, async: false

  alias Bank.Access
  alias Bank.Access.AccessInvite
  alias Bank.Accounts
  alias Bank.Accounts.User
  alias Bank.Workspaces
  alias Bank.Workspaces.Membership

  setup do
    # Each test opts into the admin allowlist via `put_admins/1`.
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

  defp create_invite!(actor, attrs) do
    {:ok, invite} = Access.create_invite(Map.new(attrs), actor)
    invite
  end

  defp unique, do: System.unique_integer([:positive])

  describe "can_admin_access?/1" do
    test "is false when admin_emails is empty" do
      put_admins([])
      assert Access.can_admin_access?(create_user()) == false
    end

    test "is true when the user's email is in the allowlist" do
      user = create_user(email: "Alpha-Admin@Example.com")
      put_admins(["alpha-admin@example.com"])

      assert Access.can_admin_access?(user)
    end

    test "lowercase + trim: env var with mixed case still matches" do
      user = create_user(email: "ops@example.com")
      put_admins([" OPS@Example.com "])

      assert Access.can_admin_access?(user)
    end

    test "is false for a disabled user even if their email is in the allowlist" do
      user = create_user(email: "ex-admin@example.com", status: :disabled)
      put_admins(["ex-admin@example.com"])

      refute Access.can_admin_access?(user)
    end

    test "is false for nil and for a user with no email" do
      assert Access.can_admin_access?(nil) == false
      assert Access.can_admin_access?(%User{}) == false
    end
  end

  describe "list_pending_access/1" do
    test "returns users with no active membership and not disabled, classified by invite" do
      ws = create_workspace()

      no_invite_user = create_user(email: "noinvite@example.com")

      domain_user = create_user(email: "alice@customer-corp.com")

      _domain_invite =
        create_invite!(create_user(),
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "customer-corp.com",
          role: :viewer
        )

      # Already a member — should NOT show up.
      member_user = create_user(email: "member@example.com")

      {:ok, _} =
        Workspaces.create_membership(%{
          user_id: member_user.id,
          workspace_id: ws.id,
          role: :viewer
        })

      # Disabled — should NOT show up.
      disabled_user = create_user(email: "ban@example.com", status: :disabled)

      rows = Access.list_pending_access()
      ids = Enum.map(rows, & &1.user.id)

      assert no_invite_user.id in ids
      assert domain_user.id in ids
      refute member_user.id in ids
      refute disabled_user.id in ids

      assert classification_for(rows, no_invite_user.id) == :allowlist_missed
      assert classification_for(rows, domain_user.id) == :domain_match
    end
  end

  describe "approve_pending_user/3 — gating" do
    test "refuses non-admin actor" do
      put_admins([])
      actor = create_user(email: "stranger@example.com")
      target = create_user(email: "victim@example.com")

      assert {:error, :unauthorized} = Access.approve_pending_user(actor, target)

      assert Workspaces.list_active_memberships(target) == []
    end

    test "refuses self-approval" do
      put_admins(["self@example.com"])
      actor = create_user(email: "self@example.com")

      assert {:error, :self_action} = Access.approve_pending_user(actor, actor)
    end

    test "refuses approving a disabled user" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "ban@example.com", status: :disabled)

      assert {:error, :user_disabled} = Access.approve_pending_user(admin, target)
    end
  end

  describe "approve_pending_user/3 — matched domain invite path" do
    test "creates a membership using the domain invite's workspace and role" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("approve-domain")

      _invite =
        create_invite!(admin,
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "customer-corp.com",
          role: :operator
        )

      target = create_user(email: "alice@customer-corp.com")

      assert {:ok, :membership_created, %Membership{} = m} =
               Access.approve_pending_user(admin, target)

      assert m.user_id == target.id
      assert m.workspace_id == ws.id
      assert m.role == :operator
      assert m.status == :active
    end

    test "second approve is :already_member without a duplicate" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("approve-idempotent")

      create_invite!(admin,
        workspace_id: ws.id,
        invite_type: :domain,
        domain: "repeat.example",
        role: :viewer
      )

      target = create_user(email: "alice@repeat.example")
      assert {:ok, :membership_created, _} = Access.approve_pending_user(admin, target)
      assert {:ok, :already_member, _} = Access.approve_pending_user(admin, target)

      assert length(Workspaces.list_active_memberships(target)) == 1
    end

    test "approving a user with an inactive membership reactivates it" do
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

      assert m.status == :inactive

      assert {:ok, :membership_reactivated, reactivated} =
               Access.approve_pending_user(admin, target,
                 workspace_id: ws.id,
                 role: :viewer
               )

      assert reactivated.id == m.id
      assert reactivated.status == :active
    end
  end

  describe "approve_pending_user/3 — explicit-opts path (no matched invite)" do
    test "creates a membership when admin supplies workspace + role" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("explicit")
      target = create_user(email: "no-invite@example.com")

      assert {:ok, :membership_created, m} =
               Access.approve_pending_user(admin, target,
                 workspace_id: ws.id,
                 role: :viewer
               )

      assert m.workspace_id == ws.id
      assert m.role == :viewer
    end

    test "rejects when no matched invite and no opts" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "stranded@example.com")

      assert {:error, :workspace_target_required} =
               Access.approve_pending_user(admin, target)
    end

    test "rejects when workspace is supplied but role is missing" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("partial-opts")
      target = create_user(email: "partial@example.com")

      assert {:error, :role_required} =
               Access.approve_pending_user(admin, target, workspace_id: ws.id)
    end
  end

  describe "reject_pending_user/3" do
    test "flips a pending user to :disabled" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "doomed@example.com")

      assert {:ok, :rejected, disabled} = Access.reject_pending_user(admin, target)
      assert disabled.status == :disabled
      assert Accounts.get_user(target.id).status == :disabled
    end

    test "is idempotent on an already-disabled user" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "ex-doomed@example.com", status: :disabled)

      assert {:ok, :already_disabled, ^target} = Access.reject_pending_user(admin, target)
      assert Accounts.get_user(target.id).status == :disabled
    end

    test "refuses non-admin actor" do
      put_admins([])
      actor = create_user()
      target = create_user()

      assert {:error, :unauthorized} = Access.reject_pending_user(actor, target)
      assert Accounts.get_user(target.id).status != :disabled
    end

    test "refuses self-rejection" do
      put_admins(["self@example.com"])
      actor = create_user(email: "self@example.com")

      assert {:error, :self_action} = Access.reject_pending_user(actor, actor)
      assert Accounts.get_user(actor.id).status != :disabled
    end

    test "does not auto-revoke a domain invite even if one matched" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("reject-keeps-invite")

      invite =
        create_invite!(admin,
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "rejectme.example",
          role: :viewer
        )

      target = create_user(email: "alice@rejectme.example")
      assert {:ok, :rejected, _} = Access.reject_pending_user(admin, target)

      assert Repo.get!(AccessInvite, invite.id).status == :active
    end
  end

  describe "reject_pending_user/3 — notification emission (#421)" do
    alias Bank.Notifications
    alias Bank.Notifications.Notification

    test "emits a workspace-scoped :warning when an exact-email invite matches" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("reject-exact")

      _invite =
        create_invite!(admin,
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "alice@example.com",
          role: :operator
        )

      target = create_user(email: "alice@example.com")

      assert {:ok, :rejected, disabled} = Access.reject_pending_user(admin, target)
      assert disabled.status == :disabled

      [n] = Notifications.list_for_workspace(ws.id)
      assert %Notification{} = n
      assert n.workspace_id == ws.id
      assert n.role_target == :operator
      assert n.user_id == nil
      assert n.event_type == "access.rejected"
      assert n.severity == :warning
      assert n.subject_type == "user"
      assert n.subject_id == target.id
      assert n.correlation_id == target.id
      assert n.action_link == "/admin/access"
      assert n.dedupe_key == "access.rejected:#{target.id}"
      assert n.title =~ "reject-exact"
    end

    test "emits a workspace-scoped :warning when only a domain invite matches" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("reject-domain")

      _invite =
        create_invite!(admin,
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "partner.io",
          role: :viewer
        )

      target = create_user(email: "carol@partner.io")

      assert {:ok, :rejected, _} = Access.reject_pending_user(admin, target)

      [n] = Notifications.list_for_workspace(ws.id)
      assert n.workspace_id == ws.id
      assert n.event_type == "access.rejected"
      assert n.severity == :warning
      assert n.dedupe_key == "access.rejected:#{target.id}"
    end

    test "exact-email invite wins over domain invite when both match in the same workspace" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("reject-precedence")

      _domain =
        create_invite!(admin,
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "example.com",
          role: :viewer
        )

      _exact =
        create_invite!(admin,
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "alice@example.com",
          role: :operator
        )

      target = create_user(email: "alice@example.com")
      assert {:ok, :rejected, _} = Access.reject_pending_user(admin, target)

      # Only one inbox row; lands in the (single) workspace.
      assert [%Notification{} = n] = Notifications.list_for_workspace(ws.id)
      assert n.workspace_id == ws.id
      assert n.dedupe_key == "access.rejected:#{target.id}"
    end

    test "exact-email invite in workspace A beats domain invite in workspace B" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws_exact = create_workspace("reject-exact-ws")
      ws_domain = create_workspace("reject-domain-ws")

      _domain =
        create_invite!(admin,
          workspace_id: ws_domain.id,
          invite_type: :domain,
          domain: "example.com",
          role: :viewer
        )

      _exact =
        create_invite!(admin,
          workspace_id: ws_exact.id,
          invite_type: :exact_email,
          email: "alice@example.com",
          role: :operator
        )

      target = create_user(email: "alice@example.com")
      assert {:ok, :rejected, _} = Access.reject_pending_user(admin, target)

      assert [_] = Notifications.list_for_workspace(ws_exact.id)
      assert Notifications.list_for_workspace(ws_domain.id) == []
    end

    test "no inbox row when no active invite matches the rejected user, but disable still happens" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("reject-no-invite")

      target = create_user(email: "stranger@nowhere.org")
      assert {:ok, :rejected, disabled} = Access.reject_pending_user(admin, target)
      assert disabled.status == :disabled

      assert Notifications.list_for_workspace(ws.id) == []
    end

    test ":already_disabled is a silent no-op (no notification row)" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("reject-already")

      _invite =
        create_invite!(admin,
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "ex@example.com",
          role: :operator
        )

      target = create_user(email: "ex@example.com", status: :disabled)

      assert {:ok, :already_disabled, _} = Access.reject_pending_user(admin, target)
      assert Notifications.list_for_workspace(ws.id) == []
    end

    test "unauthorized actor produces no notification and no disable" do
      put_admins([])
      actor = create_user()
      target = create_user(email: "alice@example.com")
      ws = create_workspace("reject-unauth")

      _invite =
        create_invite!(actor,
          workspace_id: ws.id,
          invite_type: :exact_email,
          email: "alice@example.com",
          role: :operator
        )

      assert {:error, :unauthorized} = Access.reject_pending_user(actor, target)
      assert Accounts.get_user(target.id).status != :disabled
      assert Notifications.list_for_workspace(ws.id) == []
    end

    test "cross-workspace isolation: rejection lands in the invite workspace, not siblings" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws_match = create_workspace("reject-match")
      ws_sibling = create_workspace("reject-sibling")

      _invite =
        create_invite!(admin,
          workspace_id: ws_match.id,
          invite_type: :exact_email,
          email: "alice@example.com",
          role: :operator
        )

      target = create_user(email: "alice@example.com")
      assert {:ok, :rejected, _} = Access.reject_pending_user(admin, target)

      assert [%Notification{workspace_id: match_id}] =
               Notifications.list_for_workspace(ws_match.id)

      assert match_id == ws_match.id
      assert Notifications.list_for_workspace(ws_sibling.id) == []
    end

    test "secret-shaped email/name on the rejected user does not leak into the inbox" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      ws = create_workspace("reject-secret")

      _invite =
        create_invite!(admin,
          workspace_id: ws.id,
          invite_type: :domain,
          domain: "example.com",
          role: :viewer
        )

      target =
        create_user(
          email: "alice@example.com",
          name: "Authorization Bearer LEAKED_PROBE"
        )

      assert {:ok, :rejected, _} = Access.reject_pending_user(admin, target)

      [n] = Notifications.list_for_workspace(ws.id)
      refute n.title =~ "LEAKED_PROBE"
      refute n.body =~ "LEAKED_PROBE"
      refute (n.action_link || "") =~ "LEAKED_PROBE"
      refute n.title =~ "Bearer"
      refute n.body =~ "Bearer"
      refute n.title =~ target.email
      refute n.body =~ target.email
      refute n.dedupe_key =~ "Bearer"
    end
  end

  defp classification_for(rows, user_id) do
    Enum.find(rows, fn row -> row.user.id == user_id end)
    |> Map.get(:classification)
  end

  describe "approve_pending_user/3 — notification emission (#234)" do
    alias Bank.Notifications
    alias Bank.Notifications.Notification

    test "creating a fresh membership lands an :info notification for the new user" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "alice@example.com")
      ws = create_workspace("notif-ws-fresh")

      assert {:ok, :membership_created, m} =
               Access.approve_pending_user(admin, target,
                 workspace_id: ws.id,
                 role: :operator
               )

      [n] = Notifications.list_for_workspace(ws.id)
      assert %Notification{} = n
      assert n.event_type == "access.approved"
      assert n.severity == :info
      assert n.user_id == target.id
      assert n.role_target == nil
      assert n.subject_type == "membership"
      assert n.subject_id == m.id
      assert n.correlation_id == target.id
      assert n.action_link == "/dashboard"
      assert n.dedupe_key == "access:approved:#{target.id}:#{ws.id}"
      assert n.title =~ "notif-ws-fresh"
      assert n.body =~ "operator"
    end

    test "reactivating an inactive membership also lands a notification" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "alice@example.com")
      ws = create_workspace("notif-ws-react")

      {:ok, m} =
        Workspaces.create_membership(%{
          user_id: target.id,
          workspace_id: ws.id,
          role: :operator
        })

      {:ok, _} = Workspaces.set_status(m, :inactive)

      assert {:ok, :membership_reactivated, _reactivated} =
               Access.approve_pending_user(admin, target,
                 workspace_id: ws.id,
                 role: :operator
               )

      [n] = Notifications.list_for_workspace(ws.id)
      assert n.event_type == "access.approved"
      assert n.user_id == target.id
      assert n.dedupe_key == "access:approved:#{target.id}:#{ws.id}"
    end

    test ":already_member is a silent no-op (no second notification row)" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "alice@example.com")
      ws = create_workspace("notif-ws-idem")

      {:ok, _m} =
        Workspaces.create_membership(%{
          user_id: target.id,
          workspace_id: ws.id,
          role: :operator
        })

      # No prior notification rows — the `:already_member` arm
      # short-circuits with no audit and no inbox emission.
      assert {:ok, :already_member, _} =
               Access.approve_pending_user(admin, target,
                 workspace_id: ws.id,
                 role: :operator
               )

      assert Notifications.list_for_workspace(ws.id) == []
    end

    test "cross-workspace isolation: an approval in workspace A does not list under workspace B" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "alice@example.com")
      ws_a = create_workspace("notif-ws-a")
      ws_b = create_workspace("notif-ws-b")

      assert {:ok, :membership_created, _} =
               Access.approve_pending_user(admin, target,
                 workspace_id: ws_a.id,
                 role: :operator
               )

      assert [%Notification{workspace_id: a_id}] = Notifications.list_for_workspace(ws_a.id)
      assert a_id == ws_a.id
      assert Notifications.list_for_workspace(ws_b.id) == []
    end

    test "no inbox row even if Workspaces.create_workspace name carries a free-text-looking value " <>
           "— title is composed from the slug only" do
      put_admins(["admin@example.com"])
      admin = create_user(email: "admin@example.com")
      target = create_user(email: "alice@example.com")
      # Even an operator-supplied workspace name like "Authorization
      # Bearer LEAKED_PROBE" would never reach the inbox because we
      # only embed the validated `slug` (regex `[a-z0-9_-]{1,63}`).
      {:ok, ws} =
        Workspaces.create_workspace(%{
          slug: "notif-ws-secret",
          name: "Authorization: Bearer LEAKED_PROBE",
          mainnet_enabled: true
        })

      assert {:ok, :membership_created, _} =
               Access.approve_pending_user(admin, target,
                 workspace_id: ws.id,
                 role: :operator
               )

      [n] = Notifications.list_for_workspace(ws.id)
      refute n.title =~ "Bearer"
      refute n.title =~ "LEAKED_PROBE"
      refute n.body =~ "Bearer"
      refute n.body =~ "LEAKED_PROBE"
    end
  end
end
