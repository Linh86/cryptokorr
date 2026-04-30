defmodule BankWeb.APIKeysAdminLiveTest do
  @moduledoc """
  LiveView tests for `/admin/api_keys` (#218 admin UI).

  Covers:
    * mount gates (BANK_ADMIN_EMAILS allowlist + workspace required);
    * list shows only the current workspace's keys;
    * create returns + displays the raw secret EXACTLY ONCE;
    * raw secret never appears in the post-dismiss page nor in
      a fresh re-mount;
    * admin role cannot mint owner; owner role can mint owner;
    * revoke updates the row and refreshes the list;
    * a cross-workspace id is invisible AND not revocable;
    * the rendered HTML never contains `secret_hash`.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bank.APIKeys
  alias Bank.APIKeys.APIKey
  alias Bank.Audit
  alias Bank.Workspaces

  defp setup_admin_user(role) do
    suffix = System.unique_integer([:positive])
    email = "ui-admin-#{suffix}@example.com"

    Application.put_env(:bank, :admin_emails, [email])
    on_exit(fn -> Application.put_env(:bank, :admin_emails, []) end)

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "ui-admin-#{suffix}",
        email: email,
        name: "UI Admin"
      })

    {:ok, ws} =
      Workspaces.create_workspace(%{slug: "ui-admin-#{suffix}", name: "UI Admin #{suffix}"})

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: role})

    Process.put(:bank_test_workspace_id, ws.id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, user: user, workspace: ws}
  end

  defp setup_non_admin_user() do
    # Workspace admin role but NOT in BANK_ADMIN_EMAILS — UI gate
    # should refuse.
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "ui-non-admin-#{suffix}",
        email: "ui-non-admin-#{suffix}@example.com",
        name: "Non Admin"
      })

    {:ok, ws} =
      Workspaces.create_workspace(%{
        slug: "ui-non-admin-#{suffix}",
        name: "UI Non Admin #{suffix}"
      })

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :admin})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, user: user, workspace: ws}
  end

  # --- Mount gates ----------------------------------------------------------

  describe "mount gates" do
    test "anonymous → /login" do
      conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin/api_keys")
    end

    test "user not in BANK_ADMIN_EMAILS is bounced with a flash" do
      %{conn: conn} = setup_non_admin_user()

      assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, "/admin/api_keys")
      assert flash["error"] =~ "don't have access"
    end

    test "BANK_ADMIN_EMAILS user with no workspace is redirected to /pending" do
      suffix = System.unique_integer([:positive])
      email = "no-ws-#{suffix}@example.com"
      Application.put_env(:bank, :admin_emails, [email])
      on_exit(fn -> Application.put_env(:bank, :admin_emails, []) end)

      {:ok, user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "no-ws-#{suffix}",
          email: email,
          name: "No WS Admin"
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)

      assert {:error, {:redirect, %{to: "/pending"}}} = live(conn, "/admin/api_keys")
    end

    test "BANK_ADMIN_EMAILS admin with workspace can mount" do
      %{conn: conn} = setup_admin_user(:admin)

      assert {:ok, view, html} = live(conn, "/admin/api_keys")
      assert html =~ "API keys"
      assert has_element?(view, "#api-keys-page")
      assert has_element?(view, "#api-key-create-form")
    end

    test "sidebar exposes the API Keys nav link for bootstrap admins" do
      %{conn: conn} = setup_admin_user(:admin)

      {:ok, _view, html} = live(conn, "/admin/api_keys")

      assert html =~ ~s(href="/admin/api_keys")
      assert html =~ "API Keys"
    end
  end

  # --- List scoping ---------------------------------------------------------

  describe "list" do
    test "lists only the current workspace's keys", %{} do
      %{conn: conn, user: user, workspace: ws} = setup_admin_user(:admin)

      {:ok, k1, _} = APIKeys.create_key(ws, user, :viewer, "in-ws")

      # Other workspace owned by a DIFFERENT user — the admin
      # caller must not get a membership there, otherwise
      # `resolve_scope/1` would return `:ambiguous` and the
      # mount would redirect to /pending.
      {:ok, other_ws} =
        Workspaces.create_workspace(%{slug: "ui-other", name: "UI Other"})

      suffix = System.unique_integer([:positive])

      {:ok, other_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "ui-other-#{suffix}",
          email: "ui-other-#{suffix}@example.com",
          name: "Other User"
        })

      {:ok, _} =
        Workspaces.create_membership(%{
          user_id: other_user.id,
          workspace_id: other_ws.id,
          role: :admin
        })

      {:ok, k_other, _} = APIKeys.create_key(other_ws, other_user, :viewer, "other-ws")

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      assert has_element?(view, "#api-key-row-" <> k1.id)
      refute has_element?(view, "#api-key-row-" <> k_other.id)
    end

    test "rendered HTML never contains the literal `secret_hash`", %{} do
      %{conn: conn, user: user, workspace: ws} = setup_admin_user(:admin)
      {:ok, _, _} = APIKeys.create_key(ws, user, :viewer, "render-check")

      {:ok, _view, html} = live(conn, "/admin/api_keys")

      refute html =~ "secret_hash",
             "the page must NEVER expose the field name `secret_hash` (defense-in-depth)"
    end
  end

  # --- Create flow ----------------------------------------------------------

  describe "create" do
    test "shows the raw secret EXACTLY ONCE on success", %{} do
      %{conn: conn, workspace: ws} = setup_admin_user(:admin)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      html =
        view
        |> form("#api-key-create-form", api_key: %{name: "ci-runner", role: "operator"})
        |> render_submit()

      # The raw key panel is visible AND contains a `cb_…` secret
      # whose body matches a freshly-persisted key.
      assert html =~ ~s(id="api-key-raw-secret")
      assert html =~ ~r/cb_[a-z2-7]{40,}/

      # The persisted row matches.
      [latest | _] = APIKeys.list_keys_with_creator(ws.id)
      assert latest.name == "ci-runner"
      assert latest.role == :operator
    end

    test "raw secret disappears after dismiss + after re-mount", %{} do
      %{conn: conn} = setup_admin_user(:admin)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      html =
        view
        |> form("#api-key-create-form", api_key: %{name: "dismiss-me", role: "viewer"})
        |> render_submit()

      assert html =~ "api-key-raw-secret"
      raw_match = Regex.run(~r/cb_[a-z2-7]{40,}/, html) || []
      raw_secret = List.first(raw_match)
      assert is_binary(raw_secret)

      # Dismiss the panel → secret disappears.
      html_after_dismiss = view |> element("#api-key-raw-dismiss") |> render_click()
      refute html_after_dismiss =~ "api-key-raw-secret-value"
      refute html_after_dismiss =~ raw_secret

      # Fresh mount → no raw secret either.
      {:ok, _view2, html2} = live(conn, "/admin/api_keys")
      refute html2 =~ raw_secret
      refute html2 =~ "api-key-raw-secret-value"
    end

    test "admin caller cannot mint an owner key (UI defense)", %{} do
      # UI-layer defense: the role <select> for an admin caller
      # MUST NOT include the "owner" option. A hostile client
      # bypassing the dropdown lands on the server-side gate
      # tested in the next case.
      %{conn: conn} = setup_admin_user(:admin)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      role_select_html = view |> element("#api-key-role") |> render()

      assert role_select_html =~ ~s(value="viewer")
      assert role_select_html =~ ~s(value="operator")
      assert role_select_html =~ ~s(value="admin")
      refute role_select_html =~ ~s(value="owner")
    end

    test "admin caller cannot mint an owner key (server defense)", %{} do
      # Server-side gate: even if a hostile client crafts the
      # event with `role: "owner"`, `enforce_creator_role/2`
      # refuses. We bypass the form's option-set validation by
      # invoking the event directly.
      %{conn: conn, workspace: ws} = setup_admin_user(:admin)
      keys_before = APIKeys.list_keys_with_creator(ws.id)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      html =
        render_submit(view, "create", %{
          "api_key" => %{"name" => "too-strong", "role" => "owner"}
        })

      assert html =~ "only mint keys at or below your own role"
      refute html =~ "api-key-raw-secret"
      assert APIKeys.list_keys_with_creator(ws.id) == keys_before
    end

    test "owner caller CAN mint an owner key", %{} do
      %{conn: conn, workspace: ws} = setup_admin_user(:owner)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      html =
        view
        |> form("#api-key-create-form", api_key: %{name: "owner-mgmt", role: "owner"})
        |> render_submit()

      assert html =~ "api-key-raw-secret"
      assert Enum.any?(APIKeys.list_keys_with_creator(ws.id), &(&1.role == :owner))
    end

    test "empty name surfaces a form error", %{} do
      %{conn: conn} = setup_admin_user(:admin)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      html =
        view
        |> form("#api-key-create-form", api_key: %{name: "   ", role: "viewer"})
        |> render_submit()

      assert html =~ "name is required" or html =~ "Could not create"
      refute html =~ "api-key-raw-secret"
    end
  end

  # --- Revoke flow ----------------------------------------------------------

  describe "revoke" do
    test "marks the key revoked and updates the UI", %{} do
      %{conn: conn, user: user, workspace: ws} = setup_admin_user(:admin)
      {:ok, key, _} = APIKeys.create_key(ws, user, :operator, "to-revoke")

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      html = view |> element("#api-key-revoke-" <> key.id) |> render_click()

      reloaded = Bank.Repo.get!(APIKey, key.id)
      assert %DateTime{} = reloaded.revoked_at

      # The row stays in the list but the revoke button is gone;
      # a "Revoked" status is shown instead.
      assert has_element?(view, "#api-key-row-" <> key.id)
      refute has_element?(view, "#api-key-revoke-" <> key.id)
      assert html =~ "Revoked"
    end

    test "is idempotent on an already-revoked key", %{} do
      %{conn: conn, user: user, workspace: ws} = setup_admin_user(:admin)
      {:ok, key, _} = APIKeys.create_key(ws, user, :viewer, "dup-revoke")
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      # Re-fetch to load the post-revoke state into the LiveView.
      {:ok, _view, html} = live(conn, "/admin/api_keys")

      # The row is shown but with "Revoked" status, no button.
      assert html =~ "api-key-row-" <> key.id
      refute html =~ "api-key-revoke-" <> key.id
    end

    test "cross-workspace id is invisible AND not revocable", %{} do
      %{conn: conn} = setup_admin_user(:admin)

      # A key in another workspace owned by a DIFFERENT user —
      # giving the admin caller a membership in both workspaces
      # would make `resolve_scope/1` return `:ambiguous` and the
      # mount would redirect to /pending.
      suffix = System.unique_integer([:positive])
      {:ok, other_ws} = Workspaces.create_workspace(%{slug: "iso-#{suffix}", name: "Iso"})

      {:ok, other_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "iso-other-#{suffix}",
          email: "iso-other-#{suffix}@example.com",
          name: "Iso Other"
        })

      {:ok, _} =
        Workspaces.create_membership(%{
          user_id: other_user.id,
          workspace_id: other_ws.id,
          role: :admin
        })

      {:ok, foreign_key, _} = APIKeys.create_key(other_ws, other_user, :viewer, "foreign")

      {:ok, view, html} = live(conn, "/admin/api_keys")

      # Foreign id is NOT in the listing.
      refute html =~ "api-key-row-" <> foreign_key.id
      refute has_element?(view, "#api-key-revoke-" <> foreign_key.id)

      # Even if a hostile click somehow targets the foreign id,
      # the handler refuses and leaves the foreign row untouched.
      _ = render_click(view, "revoke", %{"id" => foreign_key.id})

      reloaded = Bank.Repo.get!(APIKey, foreign_key.id)
      assert is_nil(reloaded.revoked_at), "cross-workspace revoke MUST be a no-op"
    end
  end

  # --- Rotate flow (#220) ---------------------------------------------------

  describe "rotate" do
    test "rotate button mints a new key, revokes old, shows raw secret once", %{} do
      %{conn: conn, user: user, workspace: ws} = setup_admin_user(:admin)
      {:ok, old_key, _} = APIKeys.create_key(ws, user, :operator, "ci-runner")

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      html = view |> element("#api-key-rotate-" <> old_key.id) |> render_click()

      # Old key is now revoked.
      reloaded_old = Bank.Repo.get!(APIKey, old_key.id)
      assert %DateTime{} = reloaded_old.revoked_at

      # A new active key sits in the workspace.
      [new_key] = APIKeys.list_active_keys(ws.id)
      refute new_key.id == old_key.id
      assert new_key.name == old_key.name

      # Raw secret panel rendered exactly once with a `cb_` value.
      assert html =~ "api-key-raw-secret"
      assert html =~ "api-key-raw-secret-value"
      assert html =~ "cb_"

      # The rotate button on the OLD row is gone (revoked).
      refute has_element?(view, "#api-key-rotate-" <> old_key.id)
      refute has_element?(view, "#api-key-revoke-" <> old_key.id)

      # The new row offers Rotate + Revoke.
      assert has_element?(view, "#api-key-rotate-" <> new_key.id)
      assert has_element?(view, "#api-key-revoke-" <> new_key.id)
    end

    test "raw secret panel is removed after dismiss; raw secret value is gone", %{} do
      %{conn: conn, user: user, workspace: ws} = setup_admin_user(:admin)
      {:ok, old_key, _} = APIKeys.create_key(ws, user, :operator, "dismissable")

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      after_rotate = view |> element("#api-key-rotate-" <> old_key.id) |> render_click()

      # Pull the raw secret rendered inside the panel so we can
      # later refute its presence — it must be gone after dismiss.
      assert [_, raw_secret] =
               Regex.run(
                 ~r/id="api-key-raw-secret-value"[^>]*>\s*([^<\s]+)\s*</,
                 after_rotate
               )

      assert String.starts_with?(raw_secret, "cb_")

      after_dismiss = view |> element("#api-key-raw-dismiss") |> render_click()

      refute after_dismiss =~ "api-key-raw-secret-value"
      refute after_dismiss =~ raw_secret
    end

    test "audit event has no raw key, no secret_hash, and links old → new", %{} do
      %{conn: conn, user: user, workspace: ws} = setup_admin_user(:admin)
      {:ok, old_key, _} = APIKeys.create_key(ws, user, :operator, "audited-via-ui")

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      _ = view |> element("#api-key-rotate-" <> old_key.id) |> render_click()

      [new_key] = APIKeys.list_active_keys(ws.id)

      %{events: events} = Audit.list_events(%{event_type: "api_key.rotated"})
      [event] = Enum.filter(events, &(&1.subject_id == new_key.id))

      assert event.before_ref["id"] == old_key.id
      assert event.after_ref["id"] == new_key.id

      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ "cb_"
      refute json =~ "secret_hash"
    end

    test "rotate on an already-revoked key surfaces a flash error", %{} do
      %{conn: conn, user: user, workspace: ws} = setup_admin_user(:admin)
      {:ok, key, _} = APIKeys.create_key(ws, user, :viewer, "stale-row")
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      # The row should already render in the revoked state without
      # a rotate button. Even if a hostile click targets the id,
      # the handler refuses with an error flash.
      refute has_element?(view, "#api-key-rotate-" <> key.id)

      html = render_click(view, "rotate", %{"id" => key.id})
      assert html =~ "Cannot rotate a revoked key"
    end

    test "cross-workspace rotate is refused with not-found flash", %{} do
      %{conn: conn} = setup_admin_user(:admin)

      suffix = System.unique_integer([:positive])

      {:ok, other_ws} =
        Workspaces.create_workspace(%{slug: "rot-iso-#{suffix}", name: "Rot Iso"})

      {:ok, other_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "rot-iso-other-#{suffix}",
          email: "rot-iso-other-#{suffix}@example.com",
          name: "Rot Iso Other"
        })

      {:ok, _} =
        Workspaces.create_membership(%{
          user_id: other_user.id,
          workspace_id: other_ws.id,
          role: :admin
        })

      {:ok, foreign_key, _} = APIKeys.create_key(other_ws, other_user, :viewer, "foreign")

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      html = render_click(view, "rotate", %{"id" => foreign_key.id})
      assert html =~ "API key not found"

      reloaded = Bank.Repo.get!(APIKey, foreign_key.id)
      assert is_nil(reloaded.revoked_at), "cross-workspace rotate MUST be a no-op"
    end

    test "admin caller cannot rotate an owner key (creator-role parity #220 P2)", %{} do
      # The bootstrap admin LiveView caller has workspace role
      # `:admin`. An owner key must not be refreshable from below.
      %{conn: conn, workspace: ws} = setup_admin_user(:admin)

      {:ok, owner_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "owner-ui-rot",
          email: "owner-ui-rot@example.com",
          name: "Owner UI Rot"
        })

      {:ok, _} =
        Workspaces.create_membership(%{
          user_id: owner_user.id,
          workspace_id: ws.id,
          role: :owner
        })

      {:ok, owner_key, _} = APIKeys.create_key(ws, owner_user, :owner, "ui-owner")

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      # Hostile event firing directly (UI button is also gated by
      # role_options/1 server-side enforcement is what matters).
      html = render_click(view, "rotate", %{"id" => owner_key.id})
      assert html =~ "cannot rotate a key whose role exceeds your own"

      # Owner key must still be active.
      reloaded = Bank.Repo.get!(APIKey, owner_key.id)
      assert is_nil(reloaded.revoked_at)
    end
  end

  # --- Create with expires_at (#220) ----------------------------------------

  describe "create with expires_at" do
    test "form exposes #api-key-expires-at input", %{} do
      %{conn: conn} = setup_admin_user(:admin)

      {:ok, view, html} = live(conn, "/admin/api_keys")

      assert html =~ ~s(id="api-key-expires-at")
      assert has_element?(view, "#api-key-expires-at")
    end

    test "honours an HTML datetime-local value (UTC normalised)", %{} do
      %{conn: conn, workspace: ws} = setup_admin_user(:admin)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      _html =
        view
        |> form("#api-key-create-form",
          api_key: %{
            name: "with-ttl",
            role: "viewer",
            expires_at: "2030-01-15T12:00"
          }
        )
        |> render_submit()

      [created] = APIKeys.list_active_keys(ws.id)
      assert created.name == "with-ttl"
      assert %DateTime{} = created.expires_at
      assert created.expires_at.year == 2030
      assert created.expires_at.month == 1
      assert created.expires_at.day == 15
    end

    test "blank expires_at means 'no expiry'", %{} do
      %{conn: conn, workspace: ws} = setup_admin_user(:admin)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      _html =
        view
        |> form("#api-key-create-form",
          api_key: %{name: "no-ttl", role: "viewer", expires_at: ""}
        )
        |> render_submit()

      [created] = APIKeys.list_active_keys(ws.id)
      assert is_nil(created.expires_at)
    end

    test "invalid expires_at surfaces a form error and does NOT create a key", %{} do
      %{conn: conn, workspace: ws} = setup_admin_user(:admin)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      html =
        view
        |> form("#api-key-create-form",
          api_key: %{name: "bad-ttl", role: "viewer", expires_at: "not-a-date"}
        )
        |> render_submit()

      assert html =~ "expires_at"
      assert APIKeys.list_active_keys(ws.id) == []
    end

    test "past expires_at is refused with a form error (#220 P2)", %{} do
      %{conn: conn, workspace: ws} = setup_admin_user(:admin)

      {:ok, view, _html} = live(conn, "/admin/api_keys")

      html =
        view
        |> form("#api-key-create-form",
          api_key: %{name: "past-ttl", role: "viewer", expires_at: "2000-01-01T00:00"}
        )
        |> render_submit()

      assert html =~ "must be in the future"
      assert APIKeys.list_active_keys(ws.id) == []
    end
  end
end
