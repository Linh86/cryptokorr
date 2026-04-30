defmodule BankWeb.LiveAuthRBACTest do
  @moduledoc """
  Browser-side RBAC coverage for #159a.

  The `:require_role` `on_mount` hook gates LiveView access by role
  hierarchy `viewer < operator < admin < owner`. These tests cover:

    * Anonymous → `/login` redirect on every gated route.
    * Pending / no-workspace → `/pending` redirect.
    * Insufficient role → `/unauthorized` redirect.
    * Sufficient role mounts the page normally.
    * Action-level admin gates (`pause_runtime`, `revoke_delegation`,
      `archive`) refuse operator role even on operator-mounted pages.
    * `BANK_ADMIN_EMAILS` bootstrap admin path stays intact.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bank.Accounts
  alias Bank.Workspaces

  # --- Helpers --------------------------------------------------------------

  defp authed_conn_with_role(role) do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "rbac-#{suffix}",
        email: "rbac-#{suffix}@example.com",
        name: "RBAC #{suffix}"
      })

    {:ok, ws} =
      Workspaces.create_workspace(%{
        slug: "rbac-#{suffix}",
        name: "RBAC #{suffix}"
      })

    {:ok, _} =
      Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: ws.id,
        role: role
      })

    Process.put(:bank_test_workspace_id, ws.id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    {conn, user, ws}
  end

  # --- Anonymous → /login ---------------------------------------------------

  describe "anonymous user (no session)" do
    test "every operator-required LiveView redirects to /login", %{conn: conn} do
      for path <- ["/", "/queue", "/counterparties", "/policies", "/security"] do
        assert {:error, {:redirect, %{to: "/login"}}} = live(conn, path),
               "expected #{path} to redirect anonymous to /login"
      end
    end

    test "viewer-readable LiveView also redirects anonymous to /login", %{conn: conn} do
      for path <- ["/dashboard", "/intents", "/audit"] do
        assert {:error, {:redirect, %{to: "/login"}}} = live(conn, path),
               "expected #{path} to redirect anonymous to /login"
      end
    end
  end

  # --- Pending / no-workspace → /pending ------------------------------------

  describe "authenticated but no workspace" do
    test "redirects to /pending on every gated route" do
      suffix = System.unique_integer([:positive])

      {:ok, user} =
        Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "no-ws-#{suffix}",
          email: "no-ws-#{suffix}@example.com",
          name: "No WS"
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)

      for path <- ["/", "/dashboard", "/queue", "/policies"] do
        assert {:error, {:redirect, %{to: "/pending"}}} = live(conn, path)
      end
    end
  end

  # --- Insufficient role → /unauthorized -----------------------------------

  describe ":viewer role" do
    test "can mount viewer-readable explorer pages" do
      {conn, _user, _ws} = authed_conn_with_role(:viewer)

      for path <- ["/dashboard", "/intents", "/audit"] do
        assert {:ok, _view, _html} = live(conn, path), "expected viewer to mount #{path}"
      end
    end

    test "is redirected from operator-required pages to /unauthorized" do
      {conn, _user, _ws} = authed_conn_with_role(:viewer)

      for path <- ["/", "/queue", "/counterparties", "/policies", "/security"] do
        assert {:error, {:redirect, %{to: "/unauthorized"}}} = live(conn, path),
               "expected viewer at #{path} to redirect to /unauthorized"
      end
    end
  end

  describe ":operator role" do
    test "mounts every operator console page" do
      {conn, _user, _ws} = authed_conn_with_role(:operator)

      for path <- ["/", "/queue", "/counterparties", "/policies", "/security"] do
        assert {:ok, _view, _html} = live(conn, path), "expected operator to mount #{path}"
      end
    end

    test "also mounts viewer-readable pages (role hierarchy)" do
      {conn, _user, _ws} = authed_conn_with_role(:operator)

      for path <- ["/dashboard", "/intents", "/audit"] do
        assert {:ok, _view, _html} = live(conn, path)
      end
    end
  end

  describe ":admin and :owner roles" do
    test "admin mounts every operator and viewer page" do
      {conn, _user, _ws} = authed_conn_with_role(:admin)

      for path <- ["/", "/queue", "/counterparties", "/policies", "/security", "/dashboard"] do
        assert {:ok, _view, _html} = live(conn, path)
      end
    end

    test "owner mounts every operator and viewer page" do
      {conn, _user, _ws} = authed_conn_with_role(:owner)

      for path <- ["/", "/queue", "/counterparties", "/policies", "/security", "/dashboard"] do
        assert {:ok, _view, _html} = live(conn, path)
      end
    end
  end

  # --- /unauthorized page renders -------------------------------------------

  describe "/unauthorized page" do
    test "renders 403 with helpful copy", %{conn: conn} do
      conn = get(conn, "/unauthorized")
      assert html_response(conn, 403) =~ "permission"
      assert html_response(conn, 403) =~ "viewer"
      assert html_response(conn, 403) =~ "operator"
      assert html_response(conn, 403) =~ "admin"
      assert html_response(conn, 403) =~ "owner"
    end
  end

  # --- Action-level admin gates --------------------------------------------

  describe "operator on Control/Security cannot perform admin-only actions" do
    test "pause_runtime is rejected with admin-required flash" do
      {conn, _user, _ws} = authed_conn_with_role(:operator)
      {:ok, view, _html} = live(conn, "/security")

      result = render_click(view, "pause_runtime")
      assert result =~ "Admin role required"

      # Sanity: view rendered, runtime banner did not flip to paused.
      refute result =~ "Runtime paused"
    end

    test "resume_runtime is rejected with admin-required flash" do
      {conn, _user, _ws} = authed_conn_with_role(:operator)
      {:ok, view, _html} = live(conn, "/")

      result = render_click(view, "resume_runtime")
      assert result =~ "Admin role required"
    end

    test "revoke_delegation on Control is rejected with admin-required flash" do
      {conn, _user, _ws} = authed_conn_with_role(:operator)
      {:ok, view, _html} = live(conn, "/")

      result = render_click(view, "revoke_delegation", %{"smart-account-id" => "sa-bogus"})
      assert result =~ "Admin role required"
    end
  end

  describe "operator on Counterparty / Policies cannot archive" do
    test "policies archive_rule is rejected" do
      {conn, _user, ws} = authed_conn_with_role(:operator)
      rule = Bank.Fixtures.policy_rule(workspace_id: ws.id)

      {:ok, view, _html} = live(conn, "/policies")

      result = render_click(view, "archive_rule", %{"rule-id" => rule.id})
      assert result =~ "Admin role required"
    end
  end

  # --- BANK_ADMIN_EMAILS bootstrap (#157) ----------------------------------

  describe "BANK_ADMIN_EMAILS bootstrap admin (#157) still gates /admin/access" do
    test "user in allowlist can mount /admin/access regardless of membership role" do
      suffix = System.unique_integer([:positive])
      email = "bootstrap-admin-#{suffix}@example.com"

      original = Application.get_env(:bank, :admin_emails, [])
      Application.put_env(:bank, :admin_emails, [email])
      on_exit(fn -> Application.put_env(:bank, :admin_emails, original) end)

      {:ok, user} =
        Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "bootstrap-#{suffix}",
          email: email,
          name: "Bootstrap"
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)

      assert {:ok, _view, _html} = live(conn, "/admin/access")
    end

    test "user NOT in allowlist is bounced from /admin/access even with operator role" do
      {conn, _user, _ws} = authed_conn_with_role(:operator)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/access")
    end
  end
end
