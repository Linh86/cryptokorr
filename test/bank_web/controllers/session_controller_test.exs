defmodule BankWeb.SessionControllerTest do
  @moduledoc """
  Pending-page rendering tests for issue #157. Pins the four
  copy variants and their stable DOM ids so test helpers can
  locate state without depending on prose.
  """

  use BankWeb.ConnCase, async: false

  alias Bank.Access
  alias Bank.Accounts
  alias Bank.Workspaces
  alias BankWeb.Plugs.FetchCurrentUser

  defp create_user(opts) do
    email = Keyword.get(opts, :email, "user-#{unique()}@example.com")
    subject = Keyword.get(opts, :subject, "google-#{unique()}")

    {:ok, user} =
      Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: subject,
        email: email,
        name: Keyword.get(opts, :name, "User")
      })

    user
  end

  defp signed_in_conn(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(FetchCurrentUser.session_key(), user.id)
  end

  defp unique, do: System.unique_integer([:positive])

  describe "GET /pending — copy variants" do
    test "domain-match variant when a domain invite matches the user", %{conn: conn} do
      ws = create_workspace("dom-match")
      inviter = create_user(email: "inv-#{unique()}@example.com")

      {:ok, _invite} =
        Access.create_invite(
          %{
            workspace_id: ws.id,
            invite_type: :domain,
            domain: "customer-corp.com",
            role: :viewer
          },
          inviter
        )

      user = create_user(email: "alice@customer-corp.com")

      conn = conn |> signed_in_conn(user) |> get(~p"/pending")

      body = html_response(conn, 200)
      assert body =~ "id=\"pending-status-domain-match\""
      assert body =~ "customer-corp.com"
      refute body =~ "id=\"pending-status-no-invite\""
      refute body =~ "id=\"pending-status-default\""
    end

    test "no-invite variant when the user has no matching invite", %{conn: conn} do
      user = create_user(email: "stranger@example.com")

      conn = conn |> signed_in_conn(user) |> get(~p"/pending")

      body = html_response(conn, 200)
      assert body =~ "id=\"pending-status-no-invite\""
      refute body =~ "id=\"pending-status-domain-match\""
      refute body =~ "id=\"pending-status-default\""
    end

    test "default variant for an anonymous (no current_user) request", %{conn: conn} do
      conn = get(conn, ~p"/pending")

      body = html_response(conn, 200)
      assert body =~ "id=\"pending-status-default\""
      refute body =~ "id=\"pending-status-domain-match\""
      refute body =~ "id=\"pending-status-no-invite\""
    end

    test "ambiguous variant for a user with two active memberships", %{conn: conn} do
      user = create_user(email: "multi@example.com")
      ws_a = create_workspace("ws-a")
      ws_b = create_workspace("ws-b")

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws_a.id, role: :viewer})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws_b.id, role: :operator})

      conn = conn |> signed_in_conn(user) |> get(~p"/pending")

      body = html_response(conn, 200)
      assert body =~ "id=\"pending-status-ambiguous\""
      refute body =~ "id=\"pending-status-default\""
    end
  end

  defp create_workspace(slug) do
    {:ok, ws} = Workspaces.create_workspace(%{slug: slug, name: "Display #{slug}"})
    ws
  end
end
