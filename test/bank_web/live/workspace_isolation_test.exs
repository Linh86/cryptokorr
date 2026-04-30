defmodule BankWeb.WorkspaceIsolationTest do
  @moduledoc """
  End-to-end LiveView tests for #158c — verify that a logged-in
  operator only sees rows scoped to their own workspace, even when
  the database contains rows from other workspaces.

  These tests deliberately bypass `register_and_log_in_user`'s
  process-dict fixture default and create rows with explicit
  `workspace_id` values so they can assert the LiveView's filter is
  doing the work.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bank.Fixtures

  alias Bank.Accounts
  alias Bank.Workspaces
  alias BankWeb.Plugs.FetchCurrentUser

  defp build_user_in(workspace_slug) do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "iso-#{suffix}",
        email: "iso-#{suffix}@example.com",
        name: "Iso #{suffix}"
      })

    {:ok, ws} =
      Workspaces.create_workspace(%{slug: workspace_slug, name: "WS #{workspace_slug}"})

    {:ok, _} =
      Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: ws.id,
        role: :operator
      })

    {user, ws}
  end

  defp signed_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(FetchCurrentUser.session_key(), user.id)
  end

  describe "/counterparties" do
    test "operator only sees their workspace's counterparties", %{conn: conn} do
      {user_a, ws_a} = build_user_in("iso-cp-a-#{System.unique_integer([:positive])}")
      {_user_b, ws_b} = build_user_in("iso-cp-b-#{System.unique_integer([:positive])}")

      cp_a =
        counterparty(workspace_id: ws_a.id, name: "ACo-#{System.unique_integer([:positive])}")

      cp_b =
        counterparty(workspace_id: ws_b.id, name: "BCo-#{System.unique_integer([:positive])}")

      {:ok, _view, html} = conn |> signed_in(user_a) |> live("/counterparties")

      assert html =~ cp_a.name
      refute html =~ cp_b.name
    end
  end

  describe "/policies" do
    test "operator only sees their workspace's policy rules", %{conn: conn} do
      {user_a, ws_a} = build_user_in("iso-p-a-#{System.unique_integer([:positive])}")
      {_user_b, ws_b} = build_user_in("iso-p-b-#{System.unique_integer([:positive])}")

      rule_a =
        policy_rule(
          workspace_id: ws_a.id,
          rule_type: :amount_limit,
          priority: 100,
          params: %{"max" => "1"}
        )

      rule_b =
        policy_rule(
          workspace_id: ws_b.id,
          rule_type: :amount_limit,
          priority: 200,
          params: %{"max" => "2"}
        )

      {:ok, _view, html} = conn |> signed_in(user_a) |> live("/policies")

      assert html =~ String.slice(rule_a.id, 0, 8)
      refute html =~ String.slice(rule_b.id, 0, 8)
    end
  end

  describe "/intents" do
    test "operator only sees intents for their workspace", %{conn: conn} do
      {user_a, ws_a} = build_user_in("iso-i-a-#{System.unique_integer([:positive])}")
      {_user_b, ws_b} = build_user_in("iso-i-b-#{System.unique_integer([:positive])}")

      cp_a = counterparty(workspace_id: ws_a.id)
      cp_b = counterparty(workspace_id: ws_b.id)

      intent_a =
        agent_intent(workspace_id: ws_a.id, target_counterparty_id: cp_a.id)

      intent_b =
        agent_intent(workspace_id: ws_b.id, target_counterparty_id: cp_b.id)

      {:ok, _view, html} = conn |> signed_in(user_a) |> live("/intents")

      assert html =~ String.slice(intent_a.id, 0, 8)
      refute html =~ String.slice(intent_b.id, 0, 8)
    end
  end

  describe "/queue" do
    test "operator only sees pending approvals from their workspace", %{conn: conn} do
      {user_a, ws_a} = build_user_in("iso-q-a-#{System.unique_integer([:positive])}")
      {_user_b, ws_b} = build_user_in("iso-q-b-#{System.unique_integer([:positive])}")

      cp_a = counterparty(workspace_id: ws_a.id)
      cp_b = counterparty(workspace_id: ws_b.id)
      intent_a = agent_intent(workspace_id: ws_a.id, target_counterparty_id: cp_a.id)
      intent_b = agent_intent(workspace_id: ws_b.id, target_counterparty_id: cp_b.id)

      env_a =
        decision_envelope(
          intent: intent_a,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      env_b =
        decision_envelope(
          intent: intent_b,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, _view, html} = conn |> signed_in(user_a) |> live("/queue")

      assert html =~ String.slice(env_a.id, 0, 8)
      refute html =~ String.slice(env_b.id, 0, 8)
    end
  end

  describe "/" do
    test "operator only sees their workspace's delegations on the connection page",
         %{conn: conn} do
      {user_a, ws_a} = build_user_in("iso-c-a-#{System.unique_integer([:positive])}")
      {_user_b, ws_b} = build_user_in("iso-c-b-#{System.unique_integer([:positive])}")

      del_a = delegation(workspace_id: ws_a.id, smart_account_id: "sa-iso-a")
      del_b = delegation(workspace_id: ws_b.id, smart_account_id: "sa-iso-b")

      {:ok, _view, html} = conn |> signed_in(user_a) |> live("/")

      assert html =~ del_a.smart_account_id
      refute html =~ del_b.smart_account_id
    end
  end

  describe "/counterparties/:id (CounterpartyDetailLive)" do
    test "operator opening another workspace's counterparty url is redirected to the list",
         %{conn: conn} do
      {user_a, _ws_a} = build_user_in("iso-d-a-#{System.unique_integer([:positive])}")
      {_user_b, ws_b} = build_user_in("iso-d-b-#{System.unique_integer([:positive])}")

      cp_b =
        counterparty(
          workspace_id: ws_b.id,
          name: "Forbidden-#{System.unique_integer([:positive])}"
        )

      conn = signed_in(conn, user_a)

      assert {:error, {:redirect, %{to: "/counterparties", flash: flash}}} =
               live(conn, "/counterparties/#{cp_b.id}")

      assert flash["error"] =~ "not found"
    end

    test "operator opening their own counterparty url loads the detail page", %{conn: conn} do
      {user_a, ws_a} = build_user_in("iso-d-own-#{System.unique_integer([:positive])}")

      cp_a =
        counterparty(
          workspace_id: ws_a.id,
          name: "Own-#{System.unique_integer([:positive])}"
        )

      {:ok, _view, html} = conn |> signed_in(user_a) |> live("/counterparties/#{cp_a.id}")
      assert html =~ cp_a.name
    end
  end

  describe "/security (delegation events)" do
    test "delegation audit events from another workspace do not appear", %{conn: conn} do
      {user_a, ws_a} = build_user_in("iso-s-a-#{System.unique_integer([:positive])}")
      {_user_b, ws_b} = build_user_in("iso-s-b-#{System.unique_integer([:positive])}")

      del_a = delegation(workspace_id: ws_a.id, smart_account_id: "sa-iso-sa-a")
      del_b = delegation(workspace_id: ws_b.id, smart_account_id: "sa-iso-sa-b")

      # Two delegation.* audit events — one per workspace's
      # delegation. The current operator should only see ws_a's.
      audit_event(
        event_type: "delegation.revoked",
        subject_type: "delegation",
        subject_id: del_a.id,
        actor: :user
      )

      audit_event(
        event_type: "delegation.revoked",
        subject_type: "delegation",
        subject_id: del_b.id,
        actor: :user
      )

      {:ok, _view, html} = conn |> signed_in(user_a) |> live("/security")

      # The event payload doesn't carry workspace_id today (#161
      # builders haven't been extended). #158c filters by joining the
      # subject_id back to the workspace's own delegations, so the
      # operator never sees another workspace's delegation
      # transitions on their security dashboard. The DOM contains
      # the event_type for ws_a's delegation event but not ws_b's.
      assert html =~ String.slice(del_a.id, 0, 8)
      refute html =~ String.slice(del_b.id, 0, 8)
    end

    test "security.paused / security.resumed events stay global across workspaces",
         %{conn: conn} do
      {user_a, _ws_a} = build_user_in("iso-s-global-a-#{System.unique_integer([:positive])}")

      # Runtime-global event — `correlation_id: nil`. Every
      # workspace's operators see it.
      audit_event(
        event_type: "security.paused",
        subject_type: "runtime",
        subject_id: "global",
        actor: :user
      )

      {:ok, _view, html} = conn |> signed_in(user_a) |> live("/security")
      assert html =~ "security.paused"
    end
  end

  describe "/audit" do
    test "operator only sees audit events tagged to their workspace", %{conn: conn} do
      {user_a, ws_a} = build_user_in("iso-a-a-#{System.unique_integer([:positive])}")
      {_user_b, ws_b} = build_user_in("iso-a-b-#{System.unique_integer([:positive])}")

      evt_a =
        audit_event(
          workspace_id: ws_a.id,
          event_type: "iso.workspace_a.#{System.unique_integer([:positive])}",
          subject_type: "user",
          subject_id: user_a.id,
          correlation_id: Ecto.UUID.generate()
        )

      evt_b =
        audit_event(
          workspace_id: ws_b.id,
          event_type: "iso.workspace_b.#{System.unique_integer([:positive])}",
          subject_type: "user",
          subject_id: user_a.id,
          correlation_id: Ecto.UUID.generate()
        )

      {:ok, _view, html} = conn |> signed_in(user_a) |> live("/audit")

      assert html =~ evt_a.event_type
      refute html =~ evt_b.event_type
    end
  end
end
