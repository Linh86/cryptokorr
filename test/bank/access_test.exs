defmodule Bank.AccessTest do
  @moduledoc """
  Repo-roundtrip behaviour for `Bank.Access` (epic #153, issue
  #156). Pins the invite matching rules and the
  `apply_invites_for_user/1` contract that the auth controller
  depends on.
  """

  use Bank.DataCase, async: true

  alias Bank.Access
  alias Bank.Access.AccessInvite
  alias Bank.Accounts
  alias Bank.Accounts.User
  alias Bank.Workspaces
  alias Bank.Workspaces.Membership

  defp create_user(attrs) do
    {:ok, user} =
      Accounts.find_or_create_from_oauth(
        Map.merge(
          %{
            provider: :google,
            subject: "access-test-#{System.unique_integer([:positive])}",
            email: "user-#{System.unique_integer([:positive])}@example.com",
            name: "Access Test"
          },
          attrs
        )
      )

    user
  end

  defp create_workspace(slug \\ nil) do
    slug = slug || "ws-#{System.unique_integer([:positive])}"
    {:ok, workspace} = Workspaces.create_workspace(%{slug: slug, name: "Display: #{slug}"})
    workspace
  end

  defp create_admin do
    create_user(%{
      subject: "admin-#{System.unique_integer([:positive])}",
      email: "admin-#{System.unique_integer([:positive])}@cryptobank.test"
    })
  end

  defp create_invite(workspace, attrs), do: create_invite(workspace, attrs, create_admin())

  defp create_invite(workspace, attrs, %User{} = admin) do
    base = %{
      workspace_id: workspace.id,
      role: :operator
    }

    Access.create_invite(Map.merge(base, attrs), admin)
  end

  describe "create_invite/2 — basics" do
    test "creates an active exact-email invite normalised to lowercase" do
      ws = create_workspace()

      assert {:ok, %AccessInvite{} = invite} =
               create_invite(ws, %{invite_type: :exact_email, email: "  Alice@Example.COM  "})

      assert invite.status == :active
      assert invite.email == "alice@example.com"
      assert invite.domain == nil
      assert invite.role == :operator
      assert is_binary(invite.invited_by_user_id)
    end

    test "creates an active domain invite normalised to lowercase" do
      ws = create_workspace()

      assert {:ok, %AccessInvite{} = invite} =
               create_invite(ws, %{invite_type: :domain, domain: " EXAMPLE.com ", role: :viewer})

      assert invite.status == :active
      assert invite.domain == "example.com"
      assert invite.email == nil
      assert invite.role == :viewer
    end

    test "rejects an exact-email invite with no email" do
      ws = create_workspace()

      assert {:error, changeset} = create_invite(ws, %{invite_type: :exact_email})
      assert errors_on(changeset)[:email]
    end

    test "rejects a domain invite with no domain" do
      ws = create_workspace()

      assert {:error, changeset} = create_invite(ws, %{invite_type: :domain})
      assert errors_on(changeset)[:domain]
    end

    test "rejects a malformed email" do
      ws = create_workspace()

      assert {:error, changeset} =
               create_invite(ws, %{invite_type: :exact_email, email: "not-an-email"})

      assert errors_on(changeset)[:email]
    end

    test "rejects a malformed domain" do
      ws = create_workspace()

      assert {:error, changeset} = create_invite(ws, %{invite_type: :domain, domain: "no-tld"})
      assert errors_on(changeset)[:domain]
    end

    test "rejects an exact-email invite that also carries a domain" do
      ws = create_workspace()

      assert {:error, changeset} =
               create_invite(ws, %{
                 invite_type: :exact_email,
                 email: "alice@example.com",
                 domain: "example.com"
               })

      assert errors_on(changeset)[:domain]
    end

    test "rejects a second active exact-email invite for the same workspace+email" do
      ws = create_workspace()

      assert {:ok, _} =
               create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})

      assert {:error, changeset} =
               create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})

      assert Enum.any?(changeset.errors, fn {_, {msg, _}} -> msg =~ "has already been taken" end)
    end

    test "allows the same email in two different workspaces" do
      ws1 = create_workspace("a")
      ws2 = create_workspace("b")

      assert {:ok, _} =
               create_invite(ws1, %{invite_type: :exact_email, email: "alice@example.com"})

      assert {:ok, _} =
               create_invite(ws2, %{invite_type: :exact_email, email: "alice@example.com"})
    end
  end

  describe "revoke_invite/2" do
    test "flips an active invite to :revoked and stamps revoked_at" do
      ws = create_workspace()
      admin = create_admin()

      {:ok, invite} =
        create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"}, admin)

      assert {:ok, %AccessInvite{status: :revoked, revoked_at: %DateTime{}}} =
               Access.revoke_invite(invite, admin)
    end

    test "refuses to revoke an already-revoked invite" do
      ws = create_workspace()
      admin = create_admin()

      {:ok, invite} =
        create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"}, admin)

      assert {:ok, revoked} = Access.revoke_invite(invite, admin)
      assert {:error, changeset} = Access.revoke_invite(revoked, admin)
      assert errors_on(changeset)[:status]
    end

    test "after revoke, a new active invite for the same workspace+email is allowed" do
      ws = create_workspace()
      admin = create_admin()

      {:ok, invite} =
        create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"}, admin)

      {:ok, _} = Access.revoke_invite(invite, admin)

      assert {:ok, %AccessInvite{status: :active}} =
               create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"}, admin)
    end
  end

  describe "find_matching_invite_for_user/1" do
    test "returns nil for a disabled user" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})
      {:ok, _} = create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})

      {:ok, disabled} = Accounts.disable_user(user)
      refute Access.find_matching_invite_for_user(disabled)
    end

    test "matches an exact-email invite case-insensitively" do
      ws = create_workspace()
      user = create_user(%{email: "Alice@Example.COM"})

      {:ok, invite} =
        create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})

      assert %AccessInvite{id: id} = Access.find_matching_invite_for_user(user)
      assert id == invite.id
    end

    test "matches a domain invite when no exact-email invite exists" do
      ws = create_workspace()
      user = create_user(%{email: "carol@partner.io"})
      {:ok, invite} = create_invite(ws, %{invite_type: :domain, domain: "partner.io"})

      assert %AccessInvite{id: id} = Access.find_matching_invite_for_user(user)
      assert id == invite.id
    end

    test "exact-email beats domain when both match" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})

      {:ok, _} = create_invite(ws, %{invite_type: :domain, domain: "example.com"})

      {:ok, exact} =
        create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})

      assert %AccessInvite{id: id, invite_type: :exact_email} =
               Access.find_matching_invite_for_user(user)

      assert id == exact.id
    end

    test "ignores expired invites" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        create_invite(ws, %{
          invite_type: :exact_email,
          email: "alice@example.com",
          expires_at: past
        })

      refute Access.find_matching_invite_for_user(user)
    end

    test "ignores revoked invites" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})

      {:ok, invite} =
        create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})

      {:ok, _} = Access.revoke_invite(invite, create_admin())

      refute Access.find_matching_invite_for_user(user)
    end

    test "returns nil for a user with no matching invite" do
      _ws = create_workspace()
      user = create_user(%{email: "stranger@nowhere.org"})
      refute Access.find_matching_invite_for_user(user)
    end
  end

  describe "apply_invites_for_user/1 — exact-email" do
    test "creates a membership and accepts the invite" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})

      {:ok, invite} =
        create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com", role: :admin})

      assert [{:exact_match_accepted, %Membership{} = membership}] =
               Access.apply_invites_for_user(user)

      assert membership.user_id == user.id
      assert membership.workspace_id == ws.id
      assert membership.role == :admin
      assert membership.status == :active

      assert %AccessInvite{
               status: :accepted,
               accepted_by_user_id: accepted_by_id,
               accepted_at: %DateTime{}
             } =
               Bank.Repo.reload(invite)

      assert accepted_by_id == user.id
    end

    test "post-apply, scope resolution returns the new membership" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})
      {:ok, _} = create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})

      assert [_] = Access.apply_invites_for_user(user)
      assert {:single, %Membership{workspace_id: workspace_id}} = Workspaces.resolve_scope(user)
      assert workspace_id == ws.id
    end

    test "is idempotent on a returning login" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})
      {:ok, _} = create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})

      assert [{:exact_match_accepted, _}] = Access.apply_invites_for_user(user)
      # Returning login: the invite is already accepted, no membership is duplicated.
      assert [] = Access.apply_invites_for_user(user)
      assert [_one] = Workspaces.list_active_memberships(user)
    end

    test "exact-email beats domain in the same workspace" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})

      {:ok, domain_invite} =
        create_invite(ws, %{invite_type: :domain, domain: "example.com", role: :viewer})

      {:ok, exact_invite} =
        create_invite(ws, %{
          invite_type: :exact_email,
          email: "alice@example.com",
          role: :operator
        })

      assert [{:exact_match_accepted, %Membership{role: :operator}}] =
               Access.apply_invites_for_user(user)

      # Exact invite consumed; domain invite stays active and unmatched.
      assert %AccessInvite{status: :accepted} = Bank.Repo.reload(exact_invite)
      assert %AccessInvite{status: :active, matched_at: nil} = Bank.Repo.reload(domain_invite)
    end

    test "honours invites across multiple workspaces in one login" do
      ws1 = create_workspace("alpha")
      ws2 = create_workspace("bravo")
      user = create_user(%{email: "alice@example.com"})

      {:ok, _} =
        create_invite(ws1, %{
          invite_type: :exact_email,
          email: "alice@example.com",
          role: :viewer
        })

      {:ok, _} =
        create_invite(ws2, %{
          invite_type: :exact_email,
          email: "alice@example.com",
          role: :admin
        })

      outcomes = Access.apply_invites_for_user(user)
      assert length(outcomes) == 2
      assert Enum.all?(outcomes, &match?({:exact_match_accepted, _}, &1))
      assert length(Workspaces.list_active_memberships(user)) == 2
    end
  end

  describe "apply_invites_for_user/1 — domain" do
    test "stamps matched_at and leaves the invite active without creating a membership" do
      ws = create_workspace()
      user = create_user(%{email: "carol@partner.io"})
      {:ok, invite} = create_invite(ws, %{invite_type: :domain, domain: "partner.io"})

      assert [{:domain_match_pending, %AccessInvite{} = touched}] =
               Access.apply_invites_for_user(user)

      assert touched.id == invite.id
      assert touched.matched_by_user_id == user.id
      assert %DateTime{} = touched.matched_at

      # No membership was created — domain invites are pending until #157.
      assert [] = Workspaces.list_active_memberships(user)
      assert Workspaces.resolve_scope(user) == :no_membership
    end

    test "preserves the original matched_at on a returning login" do
      ws = create_workspace()
      user = create_user(%{email: "carol@partner.io"})
      {:ok, _} = create_invite(ws, %{invite_type: :domain, domain: "partner.io"})

      assert [{:domain_match_pending, %AccessInvite{matched_at: first_match}}] =
               Access.apply_invites_for_user(user)

      assert [{:domain_match_pending, %AccessInvite{matched_at: ^first_match}}] =
               Access.apply_invites_for_user(user)
    end
  end

  describe "apply_invites_for_user/1 — non-matching cases" do
    test "no matching invite returns []" do
      _ws = create_workspace()
      user = create_user(%{email: "stranger@nowhere.org"})
      assert [] = Access.apply_invites_for_user(user)
      assert Workspaces.resolve_scope(user) == :no_membership
    end

    test "expired invite is ignored" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        create_invite(ws, %{
          invite_type: :exact_email,
          email: "alice@example.com",
          expires_at: past
        })

      assert [] = Access.apply_invites_for_user(user)
      assert Workspaces.resolve_scope(user) == :no_membership
    end

    test "revoked invite is ignored" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})
      admin = create_admin()

      {:ok, invite} =
        create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"}, admin)

      {:ok, _} = Access.revoke_invite(invite, admin)

      assert [] = Access.apply_invites_for_user(user)
    end

    test "disabled user is never admitted, even when an exact invite exists" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})
      {:ok, _} = create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})
      {:ok, disabled} = Accounts.disable_user(user)

      assert [:user_disabled] = Access.apply_invites_for_user(disabled)
      assert [] = Workspaces.list_active_memberships(disabled)
    end

    test "no cross-workspace leakage when a different workspace's invite exists" do
      ws_other = create_workspace()
      _user_target_ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})

      {:ok, _} =
        create_invite(ws_other, %{
          invite_type: :exact_email,
          email: "carol@example.com"
        })

      assert [] = Access.apply_invites_for_user(user)
      assert [] = Workspaces.list_active_memberships(user)
    end
  end

  describe "apply_invites_for_user/1 — pre-existing membership" do
    test "exact-email invite for a workspace where the user already belongs is idempotent" do
      ws = create_workspace()
      user = create_user(%{email: "alice@example.com"})

      {:ok, _} =
        Workspaces.create_membership(%{
          user_id: user.id,
          workspace_id: ws.id,
          role: :viewer
        })

      {:ok, _} =
        create_invite(ws, %{
          invite_type: :exact_email,
          email: "alice@example.com",
          role: :operator
        })

      assert [{:exact_match_already_member, %Membership{role: :viewer}}] =
               Access.apply_invites_for_user(user)

      # Still exactly one membership.
      assert [_one] = Workspaces.list_active_memberships(user)
    end
  end

  describe "list_active_invites/1" do
    test "returns only active, unexpired invites for the workspace" do
      ws = create_workspace()
      other = create_workspace("other")

      {:ok, active} =
        create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})

      # Expired
      {:ok, _} =
        create_invite(ws, %{
          invite_type: :exact_email,
          email: "bob@example.com",
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      # Revoked
      {:ok, to_revoke} =
        create_invite(ws, %{invite_type: :exact_email, email: "carol@example.com"})

      {:ok, _} = Access.revoke_invite(to_revoke, create_admin())

      # Different workspace
      {:ok, _} = create_invite(other, %{invite_type: :domain, domain: "stranger.com"})

      results = Access.list_active_invites(ws)
      assert Enum.map(results, & &1.id) == [active.id]
    end

    test "accepts a Workspace struct" do
      ws = create_workspace()
      {:ok, _} = create_invite(ws, %{invite_type: :exact_email, email: "alice@example.com"})

      assert [_] = Access.list_active_invites(ws)
    end
  end

  describe "normalisation helpers" do
    test "normalise_email lowercases and trims" do
      assert Access.normalise_email("  Alice@Example.COM  ") == "alice@example.com"
      assert Access.normalise_email(nil) == nil
    end

    test "normalise_domain lowercases and trims" do
      assert Access.normalise_domain(" EXAMPLE.com ") == "example.com"
      assert Access.normalise_domain(nil) == nil
    end

    test "domain_of returns the after-@ part lowercased" do
      assert Access.domain_of("alice@Example.COM") == "example.com"
      assert Access.domain_of("not-an-email") == nil
      assert Access.domain_of("alice@") == nil
      assert Access.domain_of(nil) == nil
    end
  end

  describe "edge cases" do
    test "find_matching_invite_for_user returns nil for a User with no email" do
      refute Access.find_matching_invite_for_user(%User{})
    end
  end
end
