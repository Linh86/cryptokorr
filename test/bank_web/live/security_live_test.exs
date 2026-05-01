defmodule BankWeb.SecurityLiveTest do
  @moduledoc """
  LiveView tests for the security console.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user_as_admin
  import Bank.Fixtures

  alias Bank.Security
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  describe "initial render — running, no delegation" do
    test "renders the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ "Security console"
      assert html =~ "Runtime safety posture"
    end

    test "shows no-delegation posture banner", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(id="posture-banner")
      assert html =~ ~s(data-posture="no-delegation")
      assert html =~ "No active delegation"
    end

    test "renders runtime card showing Running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(id="runtime-card")
      assert html =~ "Running"
      assert html =~ ~s(id="pause-btn")
      refute html =~ ~s(id="resume-btn")
    end

    test "renders empty delegations card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(id="delegations-card")
      assert html =~ "No active delegations"
    end

    test "renders empty safety events card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(id="safety-events-card")
      assert html =~ "No safety events recorded yet"
    end
  end

  describe "pause / resume" do
    test "clicking pause pauses the runtime and updates the banner", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      view |> element("#pause-btn") |> render_click()

      html = render(view)
      assert html =~ ~s(data-posture="paused")
      assert html =~ "Runtime is paused"
      assert html =~ ~s(id="resume-btn")
      refute html =~ ~s(id="pause-btn")
      assert Security.paused?(:global)
    end

    test "clicking resume on a paused runtime resumes it", %{conn: conn} do
      {:ok, _} = Security.pause(:global, reason: :test, actor: :user)
      {:ok, view, html} = live(conn, "/security")

      assert html =~ ~s(data-posture="paused")
      assert html =~ ~s(id="resume-btn")

      view |> element("#resume-btn") |> render_click()

      html = render(view)
      refute html =~ ~s(data-posture="paused")
      refute Security.paused?(:global)
    end

    test "paused runtime card shows reason and actor", %{conn: conn} do
      {:ok, _} = Security.pause(:global, reason: :liveness_check_failed, actor: :user)
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ "liveness_check_failed"
      assert html =~ "user"
    end
  end

  describe "delegations" do
    setup do
      delegation = delegation(state: :active)
      %{delegation: delegation}
    end

    test "ready posture banner appears when delegation is active and runtime running", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(data-posture="ready")
      assert html =~ "execution-ready"
    end

    test "delegations card renders the delegation row with revoke button", %{
      conn: conn,
      delegation: delegation
    } do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ String.slice(delegation.smart_account_id, 0, 8)
      assert html =~ "active"
      assert html =~ "revoke-btn-#{delegation.smart_account_id}"
    end

    test "clicking revoke transitions delegation to revoking", %{
      conn: conn,
      delegation: delegation
    } do
      {:ok, view, _html} = live(conn, "/security")

      view
      |> element("#revoke-btn-#{delegation.smart_account_id}")
      |> render_click()

      html = render(view)
      assert html =~ "revoking"
    end
  end

  describe "delegation in non-active state" do
    test "blocked posture when only revoking delegations exist", %{conn: conn} do
      _delegation = delegation(state: :revoking)
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(data-posture="blocked")
      assert html =~ "Execution blocked"
    end

    test "paused posture takes precedence over delegation state", %{conn: conn} do
      _delegation = delegation(state: :active)
      {:ok, _} = Security.pause(:global, reason: :operator_requested, actor: :user)
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(data-posture="paused")
    end
  end

  describe "safety events" do
    test "shows recent pause and resume events", %{conn: conn} do
      audit_event(
        event_type: "security.paused",
        subject_type: "runtime",
        subject_id: "global",
        actor: :user
      )

      audit_event(
        event_type: "security.resumed",
        subject_type: "runtime",
        subject_id: "global",
        actor: :user
      )

      {:ok, _view, html} = live(conn, "/security")

      assert html =~ "security.paused"
      assert html =~ "security.resumed"
    end

    test "shows delegation revoke events for the operator's workspace", %{conn: conn} do
      # The audit event's subject_id is the delegation uuid (#161
      # convention). #158c filters delegation events on `SecurityLive`
      # to delegations the operator's workspace owns, so the test
      # creates a real delegation first and uses its id as the
      # subject_id.
      del = delegation(smart_account_id: "sa-revoke-#{System.unique_integer([:positive])}")

      audit_event(
        event_type: "delegation.revoke_requested",
        subject_type: "delegation",
        subject_id: del.id,
        actor: :user
      )

      {:ok, _view, html} = live(conn, "/security")

      assert html =~ "delegation.revoke_requested"
    end

    test "ignores non-safety event types", %{conn: conn} do
      audit_event(
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: Ecto.UUID.generate(),
        actor: :agent
      )

      {:ok, _view, html} = live(conn, "/security")

      refute html =~ "intent.submitted"
      assert html =~ "No safety events recorded yet"
    end

    # --- #231-e workspace agent-key safety timeline ---------------------

    test "shows agent_keys.paused / agent_keys.resumed for the current workspace",
         %{conn: conn, workspace: ws} do
      audit_event(
        event_type: "agent_keys.paused",
        subject_type: "workspace",
        subject_id: ws.id,
        workspace_id: ws.id,
        actor: :user
      )

      audit_event(
        event_type: "agent_keys.resumed",
        subject_type: "workspace",
        subject_id: ws.id,
        workspace_id: ws.id,
        actor: :user
      )

      {:ok, _view, html} = live(conn, "/security")

      assert html =~ "agent_keys.paused"
      assert html =~ "agent_keys.resumed"
    end

    test "does NOT leak another workspace's agent_keys.* events",
         %{conn: conn} do
      # Spawn a separate workspace and stamp an agent_keys.paused
      # event against ITS subject_id. The current admin's view must
      # not show this row — pin the workspace boundary.
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{slug: "other-ws-leak", name: "Other"})

      audit_event(
        event_type: "agent_keys.paused",
        subject_type: "workspace",
        subject_id: other_ws.id,
        workspace_id: other_ws.id,
        actor: :user
      )

      {:ok, _view, html} = live(conn, "/security")

      refute html =~ "agent_keys.paused"
      assert html =~ "No safety events recorded yet"
    end
  end

  # --- Risk summary card (#231-e) -----------------------------------------

  describe "risk summary card" do
    test "renders with zero counts and empty-state hint when no delegations exist",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(id="risk-summary-card")
      assert html =~ "Active delegation risk summary"
      assert html =~ ~s(id="risk-total")
      assert html =~ ~s(id="risk-executable")
      assert html =~ "No active delegations to monitor"
      # No per-state cells when every count is zero.
      refute html =~ ~s(id="risk-state-active")
      refute html =~ ~s(id="risk-state-pending")
      refute html =~ ~s(id="risk-state-revoking")
      refute html =~ ~s(id="risk-state-revoke-failed")
    end

    test "renders per-state counts when delegations are in mixed states",
         %{conn: conn} do
      _ = delegation(state: :active)
      _ = delegation(state: :active)
      _ = delegation(state: :pending)
      _ = delegation(state: :revoking)

      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(id="risk-state-active")
      assert html =~ ~s(id="risk-state-pending")
      assert html =~ ~s(id="risk-state-revoking")
      # No revoke_failed row exists, so that cell stays absent.
      refute html =~ ~s(id="risk-state-revoke-failed")
      # The total badge tracks the full active list.
      assert html =~ ~s(data-total="4")
    end

    test "executable count cell reflects Delegations.executable?/1",
         %{conn: conn} do
      del = delegation(state: :active)
      assert Bank.Delegations.executable?(del.smart_account_id)

      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(data-executable="1")
    end

    test "is workspace-scoped — another workspace's delegations don't bleed in",
         %{conn: conn} do
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{slug: "other-ws-risk", name: "Other"})

      _ = delegation(state: :active, workspace_id: other_ws.id)

      {:ok, _view, html} = live(conn, "/security")

      # Total stays at 0 for the current workspace's view.
      assert html =~ ~s(data-total="0")
      assert html =~ "No active delegations to monitor"
    end
  end

  describe "navigation" do
    test "Security nav item is active on /security", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(href="/security")
      assert html =~ "bg-primary/10 text-primary"
    end
  end

  # --- Agent-key pause panel (#231-c) -------------------------------------

  describe "agent-keys pause panel" do
    alias Bank.APIKeys

    test "admin sees pause panel + pause form when unpaused, no resume button",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/security")

      assert html =~ ~s(id="agent-keys-pause-panel")
      assert html =~ ~s(id="agent-keys-pause-form")
      assert has_element?(view, "#agent-keys-pause-submit")
      refute has_element?(view, "#agent-keys-resume")
      refute has_element?(view, "#agent-keys-paused-badge")
    end

    test "admin pauses with reason → flash + paused panel renders",
         %{conn: conn, current_user: user, workspace: ws} do
      {:ok, view, _html} = live(conn, "/security")

      html =
        view
        |> form("#agent-keys-pause-form", %{"reason" => "credential leak smoke"})
        |> render_submit()

      assert html =~ "Agent keys paused"
      assert has_element?(view, "#agent-keys-paused-badge")
      assert has_element?(view, "#agent-keys-paused-since")
      assert has_element?(view, "#agent-keys-paused-reason")
      assert html =~ "credential leak smoke"
      assert html =~ user.email

      reloaded = Bank.Repo.get!(Bank.Workspaces.Workspace, ws.id)
      assert %DateTime{} = reloaded.agent_keys_paused_at
      assert reloaded.agent_keys_paused_reason == "credential leak smoke"
      assert reloaded.agent_keys_paused_by_user_id == user.id
    end

    test "admin clicks resume → panel returns to unpaused render",
         %{conn: conn, current_user: user, workspace: ws} do
      # Seed a paused workspace so resume is the first action.
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user, reason: "seed")

      {:ok, view, html} = live(conn, "/security")
      assert html =~ ~s(id="agent-keys-resume")

      after_resume =
        view |> element("#agent-keys-resume") |> render_click()

      assert after_resume =~ "Agent keys resumed"
      refute has_element?(view, "#agent-keys-paused-badge")
      refute has_element?(view, "#agent-keys-resume")

      reloaded = Bank.Repo.get!(Bank.Workspaces.Workspace, ws.id)
      assert is_nil(reloaded.agent_keys_paused_at)
    end

    test "operator-tier user sees the panel read-only (no pause form, no resume)" do
      # Build a fresh operator-tier conn (override the file-level
      # admin setup) and confirm read-only render.
      {:ok, op_ctx} = register_and_log_in_user_with_role(%{conn: build_conn()}, :operator)
      {:ok, view, html} = live(op_ctx[:conn], "/security")

      assert html =~ ~s(id="agent-keys-pause-panel")
      refute has_element?(view, "#agent-keys-pause-form")
      refute has_element?(view, "#agent-keys-pause-submit")
      refute has_element?(view, "#agent-keys-resume")
    end

    test "hostile pause from operator-tier socket is refused with flash, DB unchanged" do
      {:ok, op_ctx} = register_and_log_in_user_with_role(%{conn: build_conn()}, :operator)
      ws_id = op_ctx[:workspace].id

      {:ok, view, _html} = live(op_ctx[:conn], "/security")

      # Bypass the form by firing the event directly.
      html = render_click(view, "pause_agent_keys", %{"reason" => "hostile"})
      assert html =~ "Admin role required"

      reloaded = Bank.Repo.get!(Bank.Workspaces.Workspace, ws_id)
      assert is_nil(reloaded.agent_keys_paused_at)
    end

    test "paused state survives re-mount (loaded from DB)",
         %{conn: conn, current_user: user, workspace: ws} do
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user, reason: "persist test")

      {:ok, _view, html} = live(conn, "/security")
      assert html =~ ~s(id="agent-keys-paused-badge")
      assert html =~ "persist test"
    end

    test "cross-workspace isolation: pausing A leaves B unpaused in B's panel" do
      # Set up TWO workspaces and confirm B's panel is unaffected.
      {:ok, ctx_a} = register_and_log_in_user_with_role(%{conn: build_conn()}, :admin)
      {:ok, ctx_b} = register_and_log_in_user_with_role(%{conn: build_conn()}, :admin)

      {:ok, :paused, _} =
        APIKeys.pause_workspace(ctx_a[:workspace], ctx_a[:current_user], reason: "ws-a only")

      {:ok, view_b, html_b} = live(ctx_b[:conn], "/security")

      refute html_b =~ ~s(id="agent-keys-paused-badge")
      refute html_b =~ "ws-a only"
      assert has_element?(view_b, "#agent-keys-pause-form")
    end

    test "rendered HTML never contains api-key prefix / secret_hash / Bearer",
         %{conn: conn, current_user: user, workspace: ws} do
      # Mint a key so the workspace has something to leak, then pause.
      {:ok, key, raw} = APIKeys.create_key(ws, user, :viewer, "leak-canary")
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user, reason: "incident")

      {:ok, _view, html} = live(conn, "/security")

      refute html =~ raw, "raw bearer must NOT appear in security console"
      refute html =~ key.prefix, "api-key prefix must NOT appear in security console"
      refute html =~ "secret_hash"
      refute html =~ "Bearer "
    end
  end
end
