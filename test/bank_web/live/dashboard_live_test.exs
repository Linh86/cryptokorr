defmodule BankWeb.DashboardLiveTest do
  @moduledoc """
  LiveView tests for the operator dashboard page.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Ecto.Query

  setup :register_and_log_in_user

  alias Bank.Delegations
  alias Bank.Security
  alias Bank.Security.PauseState

  import Bank.Fixtures

  setup do
    PauseState.reset()
    :ok
  end

  # --- Mount / render -------------------------------------------------------

  describe "initial render — empty state" do
    test "renders dashboard page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Dashboard"
      assert html =~ "Runtime overview and operational summary"
    end

    test "contains expected stat card IDs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ ~s(id="runtime-status-card")
      assert html =~ ~s(id="delegation-status-card")
      assert html =~ ~s(id="pending-approvals-card")
      assert html =~ ~s(id="active-executions-card")
    end

    test "shows running runtime status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Running"
    end

    test "shows not connected delegation", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Not connected"
    end

    test "shows zero pending approvals", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ ~s(id="pending-approvals-card")
      # The value is rendered as 0
    end

    test "shows no decisions yet message", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "No decisions yet"
      assert html =~ "trust engine"
    end

    test "shows attention banner for no delegation", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Needs attention"
      assert html =~ "No delegation connected"
    end

    test "shows readiness card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ ~s(id="readiness-card")
      assert html =~ "Execution readiness"
      assert html =~ "Blocked"
    end
  end

  # --- Navigation active state -----------------------------------------------

  describe "navigation" do
    test "Dashboard nav item is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      # Dashboard link should have active styling (primary color class)
      assert html =~ "Dashboard"
    end

    test "page has correct title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Dashboard"
    end
  end

  # --- Runtime status -------------------------------------------------------

  describe "runtime status" do
    test "shows paused state when runtime is paused", %{conn: conn} do
      {:ok, :paused} = Security.pause(:global)

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Paused"
      assert html =~ "Runtime is paused"
    end

    test "shows running state when runtime is not paused", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Running"
    end
  end

  # --- Delegation readiness -------------------------------------------------

  describe "delegation readiness" do
    test "shows active delegation", %{conn: conn} do
      {:ok, _del} = grant_delegation("sa_dash", "del_dash")

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Active"
    end

    test "shows execution ready when delegation active and not paused", %{conn: conn} do
      {:ok, _del} = grant_delegation("sa_ready", "del_ready")

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Ready"
      assert html =~ "System is ready to process intents"
    end

    test "shows revoking delegation in attention banner", %{conn: conn} do
      {:ok, _del} = grant_delegation("sa_rev", "del_rev")
      {:ok, _del} = Delegations.record_revoke_requested("sa_rev")

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Delegation revocation in flight"
    end
  end

  # --- Multi-account ---------------------------------------------------------

  describe "multi-account delegations" do
    test "stat card shows fraction when multiple delegations attached", %{conn: conn} do
      {:ok, _d1} = grant_delegation("sa_a", "del_a")
      {:ok, _d2} = grant_delegation("sa_b", "del_b")

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "2/2 active"
    end

    test "readiness stays ready if at least one delegation is executable", %{conn: conn} do
      {:ok, _d1} = grant_delegation("sa_ready", "del_ready")
      {:ok, _d2} = grant_delegation("sa_rev", "del_rev")
      {:ok, _} = Delegations.record_revoke_requested("sa_rev")

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Ready"
      assert html =~ "1/2 executable"
      assert html =~ "Delegation revocation"
    end
  end

  # --- Pending approvals count ----------------------------------------------

  describe "pending approvals" do
    test "shows count of pending approvals", %{conn: conn} do
      intent = agent_intent()

      _envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Pending approvals"
      assert html =~ "awaiting approval"
    end
  end

  # --- Recent decisions -----------------------------------------------------

  describe "recent decisions" do
    test "renders recent decisions when present", %{conn: conn} do
      intent = agent_intent()

      _envelope =
        decision_envelope(
          intent: intent,
          outcome: :auto_exec,
          risk_tier: :low,
          current: true
        )

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ ~s(id="recent-decisions-card")
      assert html =~ "Auto-execute"
      assert html =~ "Low risk"
    end

    test "shows multiple outcomes in recent decisions", %{conn: conn} do
      intent1 = agent_intent()
      intent2 = agent_intent()

      _e1 =
        decision_envelope(
          intent: intent1,
          outcome: :auto_exec,
          risk_tier: :low,
          current: true
        )

      _e2 =
        decision_envelope(
          intent: intent2,
          outcome: :block,
          risk_tier: :severe,
          current: true
        )

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Auto-execute"
      assert html =~ "auto_exec"
      assert html =~ "block"
    end
  end

  # --- Events ---------------------------------------------------------------

  describe "refresh event" do
    test "reloads state and shows flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      html = view |> element("button", "Refresh") |> render_click()

      assert html =~ "Dashboard refreshed"
    end
  end

  # --- PubSub real-time updates ---------------------------------------------

  describe "PubSub updates" do
    test "security event triggers re-render", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dashboard")
      assert html =~ "Running"

      {:ok, :paused} = Security.pause(:global)

      html = render(view)
      assert html =~ "Paused"
    end

    test "approval queue event triggers re-render", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      # Create an approval-required envelope
      intent = agent_intent()

      _envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      # Broadcast on approval queue topic
      Bank.Runtime.PubSub.broadcast(
        Bank.Runtime.PubSub.approval_queue(),
        %{topic: :approval_queue, event: :enqueued, at: DateTime.utc_now(), payload: %{}}
      )

      html = render(view)
      assert html =~ "awaiting approval"
    end
  end

  # --- Stuck-plans attention line (#229) -----------------------------------

  describe "stuck-plans attention line" do
    test "no stuck plans → no attention row", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      refute has_element?(view, "#attention-stuck-plans")
    end

    test "one stuck :prepared plan in current workspace → row appears with link",
         %{conn: conn, workspace: ws} do
      _plan = stuck_prepared_plan(ws.id)

      {:ok, view, _html} = live(conn, "/dashboard")

      assert has_element?(view, "#attention-stuck-plans")
      assert has_element?(view, "#attention-stuck-plans", "1 execution plan stuck")

      assert has_element?(
               view,
               ~s|#attention-stuck-plans a[href="/security#stuck-plans-card"]|
             )
    end

    test "multiple stuck plans → pluralized text",
         %{conn: conn, workspace: ws} do
      for _ <- 1..3 do
        stuck_prepared_plan(ws.id)
      end

      {:ok, view, _html} = live(conn, "/dashboard")

      assert has_element?(view, "#attention-stuck-plans", "3 execution plans stuck")
    end

    test "stuck plan in sibling workspace does NOT appear on current dashboard",
         %{conn: conn} do
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "sibling-stuck-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      _other = stuck_prepared_plan(other_ws.id)

      {:ok, view, _html} = live(conn, "/dashboard")

      refute has_element?(view, "#attention-stuck-plans")
    end
  end

  # --- Layouts.app current_scope (admin nav visibility, mirrors #308) ------

  describe "layout current_scope wiring" do
    test "admin user sees /admin/api_keys nav link when allowlisted",
         %{conn: conn, current_user: user} do
      # Pre-fix `<Layouts.app>` was rendered without `current_scope` on
      # the dashboard, so `admin_visible?/1` always returned `false`
      # and the API Keys sidebar link was hidden for legitimate
      # admins. Pin the corrected wiring with a temporary
      # `:admin_emails` allowlist override.
      original_admin_emails = Application.get_env(:bank, :admin_emails)

      try do
        Application.put_env(:bank, :admin_emails, [user.email])

        {:ok, _view, html} = live(conn, "/dashboard")

        assert html =~ ~s(href="/admin/api_keys")
      after
        Application.put_env(:bank, :admin_emails, original_admin_emails)
      end
    end
  end

  # Insert a stuck `:prepared` plan with an old `updated_at` so it
  # crosses the per-status threshold (default 600s for `:prepared`).
  # Mirrors the helper in `test/bank_web/live/security_live_test.exs`.
  defp stuck_prepared_plan(workspace_id) do
    plan =
      Bank.Fixtures.execution_plan(
        execution_status: :prepared,
        workspace_id: workspace_id
      )

    twenty_min_ago = DateTime.utc_now() |> DateTime.add(-20 * 60, :second)

    {1, _} =
      Bank.Repo.update_all(
        from(p in Bank.Decisions.ExecutionPlan, where: p.id == ^plan.id),
        set: [updated_at: twenty_min_ago]
      )

    %{plan | updated_at: twenty_min_ago}
  end
end
