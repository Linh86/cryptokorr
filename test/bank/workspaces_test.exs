defmodule Bank.WorkspacesTest do
  @moduledoc """
  Repo-roundtrip behaviour for `Bank.Workspaces` (epic #153, issue
  #155). Pins the membership uniqueness contract, the role/status
  enums, and the scope-resolution contract that
  `BankWeb.Plugs.FetchCurrentUser` depends on.
  """

  use Bank.DataCase, async: true

  alias Bank.Accounts
  alias Bank.Workspaces
  alias Bank.Workspaces.Membership

  defp create_user(attrs \\ %{}) do
    {:ok, user} =
      Accounts.find_or_create_from_oauth(
        Map.merge(
          %{
            provider: :google,
            subject: "ws-test-#{System.unique_integer([:positive])}",
            email: "ws-#{System.unique_integer([:positive])}@example.com",
            name: "Workspace Test"
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

  describe "create_workspace/1" do
    test "creates a workspace and lower-cases the slug" do
      assert {:ok, ws} =
               Workspaces.create_workspace(%{
                 slug: "Treasury-A",
                 name: "Treasury A",
                 mainnet_enabled: true
               })

      assert ws.slug == "treasury-a"
      assert ws.name == "Treasury A"
    end

    test "rejects slugs with spaces or upper-case mid-word" do
      assert {:error, changeset} =
               Workspaces.create_workspace(%{
                 slug: "treasury A",
                 name: "Treasury A",
                 mainnet_enabled: true
               })

      assert errors_on(changeset)[:slug]
    end

    test "rejects duplicate slugs case-insensitively" do
      assert {:ok, _} =
               Workspaces.create_workspace(%{slug: "ops", name: "Ops", mainnet_enabled: true})

      assert {:error, changeset} =
               Workspaces.create_workspace(%{slug: "OPS", name: "Ops 2", mainnet_enabled: true})

      assert errors_on(changeset)[:slug]
    end
  end

  describe "get_workspace_by_slug/1" do
    test "returns the workspace regardless of slug casing or surrounding whitespace" do
      ws = create_workspace("treasury")
      assert Workspaces.get_workspace_by_slug("treasury").id == ws.id
      assert Workspaces.get_workspace_by_slug(" Treasury ").id == ws.id
    end

    test "returns nil for unknown slugs" do
      refute Workspaces.get_workspace_by_slug("no-such-workspace")
    end
  end

  describe "create_membership/1 — uniqueness" do
    test "(user_id, workspace_id) is unique" do
      user = create_user()
      ws = create_workspace()

      assert {:ok, _} =
               Workspaces.create_membership(%{
                 user_id: user.id,
                 workspace_id: ws.id,
                 role: :operator
               })

      assert {:error, changeset} =
               Workspaces.create_membership(%{
                 user_id: user.id,
                 workspace_id: ws.id,
                 role: :viewer
               })

      assert errors_on(changeset)[:user_id] || errors_on(changeset)[:workspace_id] ||
               errors_on(changeset)[:user_workspace] ||
               Enum.any?(changeset.errors, fn {_, {msg, _}} -> msg =~ "has already been taken" end)
    end

    test "the same user can join multiple workspaces" do
      user = create_user()
      ws1 = create_workspace("a")
      ws2 = create_workspace("b")

      assert {:ok, _} =
               Workspaces.create_membership(%{
                 user_id: user.id,
                 workspace_id: ws1.id,
                 role: :operator
               })

      assert {:ok, _} =
               Workspaces.create_membership(%{
                 user_id: user.id,
                 workspace_id: ws2.id,
                 role: :viewer
               })
    end
  end

  describe "create_membership/1 — role validation" do
    test "accepts every supported role" do
      user = create_user()

      for role <- [:owner, :admin, :operator, :viewer] do
        ws = create_workspace("ws-#{role}-#{System.unique_integer([:positive])}")

        assert {:ok, %Membership{role: ^role}} =
                 Workspaces.create_membership(%{
                   user_id: user.id,
                   workspace_id: ws.id,
                   role: role
                 })
      end
    end

    test "rejects unknown roles" do
      user = create_user()
      ws = create_workspace()

      assert {:error, changeset} =
               Workspaces.create_membership(%{
                 user_id: user.id,
                 workspace_id: ws.id,
                 role: :god
               })

      refute changeset.valid?
    end
  end

  describe "set_role/2 and set_status/2" do
    test "role flips persist" do
      user = create_user()
      ws = create_workspace()

      {:ok, membership} =
        Workspaces.create_membership(%{
          user_id: user.id,
          workspace_id: ws.id,
          role: :viewer
        })

      assert {:ok, %Membership{role: :admin}} = Workspaces.set_role(membership, :admin)
    end

    test "status flips persist" do
      user = create_user()
      ws = create_workspace()

      {:ok, membership} =
        Workspaces.create_membership(%{
          user_id: user.id,
          workspace_id: ws.id,
          role: :operator
        })

      assert {:ok, %Membership{status: :inactive}} = Workspaces.set_status(membership, :inactive)
    end
  end

  describe "resolve_scope/1" do
    test "no membership returns :no_membership" do
      user = create_user()
      assert Workspaces.resolve_scope(user) == :no_membership
    end

    test "single active membership returns {:single, membership}" do
      user = create_user()
      ws = create_workspace()

      {:ok, membership} =
        Workspaces.create_membership(%{
          user_id: user.id,
          workspace_id: ws.id,
          role: :operator
        })

      assert {:single, returned} = Workspaces.resolve_scope(user)
      assert returned.id == membership.id
      # The workspace association must be preloaded for the plug.
      assert returned.workspace.id == ws.id
    end

    test "multiple active memberships return {:ambiguous, memberships}" do
      user = create_user()
      ws1 = create_workspace("alpha")
      ws2 = create_workspace("bravo")

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws1.id, role: :operator})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws2.id, role: :viewer})

      assert {:ambiguous, memberships} = Workspaces.resolve_scope(user)
      assert length(memberships) == 2
      slugs = Enum.map(memberships, & &1.workspace.slug)
      assert "alpha" in slugs
      assert "bravo" in slugs
    end

    test "inactive memberships do not count as ambiguity or membership" do
      user = create_user()
      ws1 = create_workspace("alpha")
      ws2 = create_workspace("bravo")

      {:ok, m1} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws1.id, role: :operator})

      {:ok, m2} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws2.id, role: :viewer})

      # Disable one — the user is now unambiguous.
      {:ok, _} = Workspaces.set_status(m2, :inactive)
      assert {:single, returned} = Workspaces.resolve_scope(user)
      assert returned.id == m1.id

      # Disable both — the user is back to no_membership.
      {:ok, _} = Workspaces.set_status(m1, :inactive)
      assert Workspaces.resolve_scope(user) == :no_membership
    end
  end

  describe "list_active_memberships/1" do
    test "preloads workspace and orders by slug" do
      user = create_user()
      ws_b = create_workspace("bravo")
      ws_a = create_workspace("alpha")

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws_b.id, role: :operator})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws_a.id, role: :viewer})

      memberships = Workspaces.list_active_memberships(user)
      assert Enum.map(memberships, & &1.workspace.slug) == ["alpha", "bravo"]
    end

    test "excludes inactive memberships" do
      user = create_user()
      ws = create_workspace()

      {:ok, m} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :operator})

      assert [_] = Workspaces.list_active_memberships(user)
      {:ok, _} = Workspaces.set_status(m, :inactive)
      assert [] = Workspaces.list_active_memberships(user)
    end
  end
end
