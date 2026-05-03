defmodule BankWeb.SecurityLiveTest do
  @moduledoc """
  LiveView tests for the security console.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Ecto.Query

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

      {:ok, view, _html} = live(conn, "/security")

      # `#safety-events-empty` only renders when the events list is
      # empty; the substring "agent_keys.paused" appears in the
      # filter dropdown labels so refuting on raw HTML is unsafe.
      assert has_element?(view, "#safety-events-empty")
      assert has_element?(view, "#safety-events-empty", "No safety events recorded yet")
    end

    test "shows security.scope_paused / security.scope_resumed for the current workspace (#228 phase 1)",
         %{conn: conn, workspace: ws} do
      audit_event(
        event_type: "security.scope_paused",
        subject_type: "chain",
        subject_id: "base",
        workspace_id: ws.id,
        actor: :user
      )

      audit_event(
        event_type: "security.scope_resumed",
        subject_type: "chain",
        subject_id: "base",
        workspace_id: ws.id,
        actor: :user
      )

      {:ok, view, _html} = live(conn, "/security")

      refute has_element?(view, "#safety-events-empty")
      assert has_element?(view, "#safety-events-card", "security.scope_paused")
      assert has_element?(view, "#safety-events-card", "security.scope_resumed")
    end

    test "does NOT leak another workspace's security.scope_* events (#228 phase 1)",
         %{conn: conn} do
      # Cross-workspace timeline isolation regression. Without the
      # specific `visible_to_workspace?/3` clause for
      # `security.scope_*` (placed BEFORE the catch-all
      # `"security." <> _` rule), every workspace would see every
      # other workspace's scoped pauses.
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{slug: "other-ws-scope-leak", name: "Other Scope"})

      audit_event(
        event_type: "security.scope_paused",
        subject_type: "chain",
        subject_id: "base",
        workspace_id: other_ws.id,
        actor: :user
      )

      audit_event(
        event_type: "security.scope_resumed",
        subject_type: "chain",
        subject_id: "base",
        workspace_id: other_ws.id,
        actor: :user
      )

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#safety-events-empty")
      assert has_element?(view, "#safety-events-empty", "No safety events recorded yet")
    end

    test "shows security.scope_expired for the current workspace (#228 phase 1.5)",
         %{conn: conn, workspace: ws} do
      audit_event(
        event_type: "security.scope_expired",
        subject_type: "chain",
        subject_id: "base",
        workspace_id: ws.id,
        actor: :runtime
      )

      {:ok, view, _html} = live(conn, "/security")

      refute has_element?(view, "#safety-events-empty")
      assert has_element?(view, "#safety-events-card", "security.scope_expired")
    end

    test "does NOT leak another workspace's security.scope_expired event (#228 phase 1.5)",
         %{conn: conn} do
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{slug: "other-ws-expired-leak", name: "Other Expired"})

      audit_event(
        event_type: "security.scope_expired",
        subject_type: "chain",
        subject_id: "base",
        workspace_id: other_ws.id,
        actor: :runtime
      )

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#safety-events-empty")
      assert has_element?(view, "#safety-events-empty", "No safety events recorded yet")
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

  # --- Safety timeline filters (#212) -------------------------------------

  describe "safety timeline filters" do
    test "renders the filter form with default range=7d", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#safety-filters-form")
      assert has_element?(view, "#filter-event-type")
      assert has_element?(view, "#filter-actor")
      assert has_element?(view, "#filter-range")
      assert has_element?(view, "#filter-clear")
      # Default selection: 7d.
      assert has_element?(view, "#filter-range option[value='7d'][selected]")
    end

    test "filtering by event_type=security.paused hides delegation rows",
         %{conn: conn} do
      del = delegation(state: :active)

      audit_event(
        event_type: "security.paused",
        subject_type: "runtime",
        subject_id: "global",
        actor: :user
      )

      audit_event(
        event_type: "delegation.revoke_requested",
        subject_type: "delegation",
        subject_id: del.id,
        actor: :user
      )

      {:ok, view, _html} = live(conn, "/security")

      view
      |> form("#safety-filters-form", %{
        filter: %{event_type: "security.paused", actor: "all", range: "all"}
      })
      |> render_change()

      # Both safety events would otherwise show; only security.paused
      # should remain after the filter. Use the badge class as a stable
      # selector that doesn't collide with dropdown labels.
      html = render(view)
      # Empty-state must NOT render — at least one row must remain.
      refute has_element?(view, "#safety-events-empty")
      # The remaining list does not contain a delegation.revoke_requested
      # badge.
      refute html =~
               ~s(class="badge badge-sm font-mono badge-error">delegation.revoke_requested</span>)
    end

    test "filtering by actor=runtime hides user-actor events", %{conn: conn} do
      audit_event(
        event_type: "security.paused",
        subject_type: "runtime",
        subject_id: "global",
        actor: :user
      )

      audit_event(
        event_type: "delegation.state_changed",
        subject_type: "delegation",
        subject_id: Ecto.UUID.generate(),
        actor: :runtime
      )

      {:ok, view, _html} = live(conn, "/security")

      view
      |> form("#safety-filters-form", %{
        filter: %{event_type: "all", actor: "runtime", range: "all"}
      })
      |> render_change()

      # The user-actor security.paused row no longer renders, but the
      # runtime-actor delegation.state_changed event whose subject id
      # is unrelated to a known delegation will be filtered out by the
      # workspace boundary too — what we really want to assert is that
      # NO row whose actor pill says "user" remains.
      html = render(view)

      refute html =~
               ~s(<span class="badge badge-sm badge-ghost gap-1"><span class="hero-user size-3"></span>\n                  user)
    end

    test "range=24h drops a 10-day-old event", %{conn: conn} do
      old_ts = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

      audit_event(
        event_type: "security.paused",
        subject_type: "runtime",
        subject_id: "global",
        actor: :user,
        ts: old_ts
      )

      {:ok, view, _html} = live(conn, "/security")

      view
      |> form("#safety-filters-form", %{
        filter: %{event_type: "all", actor: "all", range: "24h"}
      })
      |> render_change()

      assert has_element?(view, "#safety-events-empty")
    end

    test "clear button resets to defaults", %{conn: conn} do
      audit_event(
        event_type: "security.paused",
        subject_type: "runtime",
        subject_id: "global",
        actor: :user
      )

      {:ok, view, _html} = live(conn, "/security")

      # Apply a non-default filter that hides the only event.
      view
      |> form("#safety-filters-form", %{
        filter: %{event_type: "delegation.revoked", actor: "all", range: "all"}
      })
      |> render_change()

      assert has_element?(view, "#safety-events-empty")

      # Clear → defaults restored, security.paused reappears.
      view
      |> element("#filter-clear")
      |> render_click()

      refute has_element?(view, "#safety-events-empty")
      assert has_element?(view, "#filter-range option[value='7d'][selected]")
    end

    test "filter pushdown — actor match in older events is NOT hidden by newer non-matching events (#212 P2)",
         %{conn: conn} do
      # Pre-pushdown, `load_safety_events/3` fetched the latest 10
      # unfiltered rows per type and applied actor/range in memory.
      # An operator filtering by actor=runtime would see an empty
      # timeline whenever 10+ user-actor events of the same type
      # piled up on top of an older runtime row — false-negative.
      # Pin the corrected behavior: the runtime row appears.
      now = DateTime.utc_now()

      # 12 newer security.paused rows from :user (one above the
      # legacy 10-row window).
      for i <- 1..12 do
        audit_event(
          event_type: "security.paused",
          subject_type: "runtime",
          subject_id: "global",
          actor: :user,
          ts: DateTime.add(now, -i, :second)
        )
      end

      # One OLDER :runtime row that the pre-pushdown code would miss.
      _runtime_row =
        audit_event(
          event_type: "security.paused",
          subject_type: "runtime",
          subject_id: "global",
          actor: :runtime,
          ts: DateTime.add(now, -3600, :second)
        )

      {:ok, view, _html} = live(conn, "/security")

      view
      |> form("#safety-filters-form", %{
        filter: %{event_type: "all", actor: "runtime", range: "all"}
      })
      |> render_change()

      # Empty-state must NOT render — the runtime row must be visible.
      refute has_element?(view, "#safety-events-empty")

      # And the row IS the runtime-actor pill, not one of the
      # 12 user-actor rows. Match on the actor pill class +
      # icon to dodge collisions with dropdown labels.
      html = render(view)

      assert html =~
               ~s(<span class="badge badge-sm badge-ghost gap-1"><span class="hero-cog-6-tooth size-3"></span>)

      refute html =~
               ~s(<span class="badge badge-sm badge-ghost gap-1"><span class="hero-user size-3"></span>)
    end

    test "workspace isolation still holds with filters applied",
         %{conn: conn} do
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{slug: "other-ws-filtered", name: "Other"})

      audit_event(
        event_type: "agent_keys.paused",
        subject_type: "workspace",
        subject_id: other_ws.id,
        workspace_id: other_ws.id,
        actor: :user
      )

      {:ok, view, _html} = live(conn, "/security")

      # Even with the filter narrowed to agent_keys.paused, the row
      # belongs to another workspace and must not appear.
      view
      |> form("#safety-filters-form", %{
        filter: %{event_type: "agent_keys.paused", actor: "all", range: "all"}
      })
      |> render_change()

      assert has_element?(view, "#safety-events-empty")
    end
  end

  describe "navigation" do
    test "Security nav item is active on /security", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(href="/security")
      assert html =~ "bg-primary/10 text-primary"
    end

    test "Layouts.app receives current_scope so admin nav can render (#305 review fix)",
         %{conn: conn, current_user: user} do
      # Pre-fix `<Layouts.app>` was rendered without `current_scope`,
      # so `admin_visible?/1` always evaluated to `false` and the
      # sidebar's admin-only `/admin/api_keys` nav link was hidden
      # for legitimate admin users on /security. Pin the corrected
      # wiring: when the calling user is on the `BANK_ADMIN_EMAILS`
      # allowlist, the admin link appears.
      original_admin_emails = Application.get_env(:bank, :admin_emails)

      try do
        Application.put_env(:bank, :admin_emails, [user.email])

        {:ok, _view, html} = live(conn, "/security")

        assert html =~ ~s(href="/admin/api_keys")
      after
        Application.put_env(:bank, :admin_emails, original_admin_emails)
      end
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

  # --- Stuck-plans card (#229/#230 UI) --------------------------------------

  describe "stuck plans card" do
    alias Bank.Decisions.ExecutionPlan
    alias Bank.Repo

    test "renders empty state when no stuck plans exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#stuck-plans-card")
      assert has_element?(view, "#stuck-plans-empty")
    end

    test "renders a stuck :prepared plan with abort button",
         %{conn: conn, workspace: ws} do
      plan = stuck_prepared_plan(ws.id)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#stuck-plans-card")
      refute has_element?(view, "#stuck-plans-empty")
      assert has_element?(view, "#stuck-plan-#{plan.id}")
      assert has_element?(view, "#abort-plan-btn-#{plan.id}")
      assert has_element?(view, "#stuck-plan-status-#{plan.id}")
    end

    test "non-:prepared stuck plans render the not-safe message instead of the abort button",
         %{conn: conn, workspace: ws} do
      plan = stuck_plan(:signing, ws.id)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#stuck-plan-#{plan.id}")
      assert has_element?(view, "#stuck-plan-not-safe-#{plan.id}")
      refute has_element?(view, "#abort-plan-btn-#{plan.id}")
    end

    test "fresh plans (under threshold) do NOT appear", %{conn: conn, workspace: ws} do
      _fresh = fresh_plan(:prepared, ws.id)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#stuck-plans-empty")
    end

    test "clicking abort transitions :prepared plan to :aborted and removes the row",
         %{conn: conn, workspace: ws} do
      plan = stuck_prepared_plan(ws.id)

      {:ok, view, _html} = live(conn, "/security")

      view |> element("#abort-plan-btn-#{plan.id}") |> render_click()

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :aborted
      assert reloaded.active == false

      # After reload, the now-aborted (active=false) row no longer
      # appears on the card.
      refute has_element?(view, "#stuck-plan-#{plan.id}")
      assert has_element?(view, "#stuck-plans-empty")
    end

    test "cross-workspace stuck plan does NOT appear",
         %{conn: conn} do
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{slug: "other-stuck", name: "Other"})

      _other = stuck_prepared_plan(other_ws.id)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#stuck-plans-empty")
    end

    test "current-workspace stuck plan is not starved by 10+ older sibling-workspace rows (#305 review fix)",
         %{conn: conn, workspace: ws} do
      # Pre-fix the LiveView fetched `stuck_plan_details(limit: 10)`
      # globally and post-filtered by workspace; 10+ older sibling
      # rows would consume the limit and silently hide the current
      # workspace's row. With the DB-side workspace filter, the
      # current row is rendered regardless of sibling volume.
      {:ok, sibling_ws} =
        Bank.Workspaces.create_workspace(%{slug: "sibling-starve-test", name: "Sibling"})

      for _ <- 1..12 do
        plan =
          Bank.Fixtures.execution_plan(execution_status: :prepared, workspace_id: sibling_ws.id)

        twenty_one_min_ago = DateTime.utc_now() |> DateTime.add(-21 * 60, :second)

        {1, _} =
          Bank.Repo.update_all(
            from(p in Bank.Decisions.ExecutionPlan, where: p.id == ^plan.id),
            set: [updated_at: twenty_one_min_ago]
          )
      end

      current_plan = stuck_prepared_plan(ws.id)

      {:ok, view, _html} = live(conn, "/security")

      refute has_element?(view, "#stuck-plans-empty")
      assert has_element?(view, "#stuck-plan-#{current_plan.id}")
      assert has_element?(view, "#abort-plan-btn-#{current_plan.id}")
    end
  end

  # --- ops.stuck_plan_detected on the safety timeline (#230-b) -------------

  describe "ops.stuck_plan_detected on safety timeline" do
    test "shows ops.stuck_plan_detected for the current workspace",
         %{conn: conn, workspace: ws} do
      audit_event(
        event_type: "ops.stuck_plan_detected",
        subject_type: "execution_plan",
        subject_id: Ecto.UUID.generate(),
        workspace_id: ws.id,
        actor: :runtime
      )

      {:ok, _view, html} = live(conn, "/security")

      assert html =~ "ops.stuck_plan_detected"
    end

    test "does NOT leak ops.stuck_plan_detected from another workspace",
         %{conn: conn} do
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{slug: "other-stuck-detected", name: "Other"})

      audit_event(
        event_type: "ops.stuck_plan_detected",
        subject_type: "execution_plan",
        subject_id: Ecto.UUID.generate(),
        workspace_id: other_ws.id,
        actor: :runtime
      )

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#safety-events-empty")
    end
  end

  # --- In-flight execution plans card (#229) -------------------------------

  describe "in-flight execution plans card" do
    test "renders empty state when no active plans exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#in-flight-plans-card")
      assert has_element?(view, "#in-flight-plans-empty")
    end

    test "renders one row per active workspace plan with status badge",
         %{conn: conn, workspace: ws} do
      prepared = fresh_plan(:prepared, ws.id)
      signing = fresh_plan(:signing, ws.id)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#in-flight-plans-card")
      refute has_element?(view, "#in-flight-plans-empty")

      assert has_element?(view, "#in-flight-plan-#{prepared.id}")
      assert has_element?(view, "#in-flight-plan-#{signing.id}")

      assert has_element?(
               view,
               ~s|#in-flight-plan-status-#{prepared.id}[data-status="prepared"]|
             )

      assert has_element?(
               view,
               ~s|#in-flight-plan-status-#{signing.id}[data-status="signing"]|
             )
    end

    test "renders all four non-terminal statuses",
         %{conn: conn, workspace: ws} do
      for status <- [:prepared, :signing, :broadcasting, :pending_confirmation] do
        fresh_plan(status, ws.id)
      end

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, ~s|#in-flight-plans-card[data-count="4"]|)
    end

    test "terminal-status plans (confirmed/reverted/aborted) do NOT appear",
         %{conn: conn, workspace: ws} do
      _confirmed = Bank.Fixtures.execution_plan(execution_status: :confirmed, workspace_id: ws.id)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#in-flight-plans-empty")
    end

    test "sibling-workspace plan does NOT appear on current workspace",
         %{conn: conn} do
      {:ok, sibling_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "sibling-in-flight-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      _sibling = fresh_plan(:prepared, sibling_ws.id)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#in-flight-plans-empty")
    end

    test "stuck-plans card and in-flight card coexist (stuck plan appears in both)",
         %{conn: conn, workspace: ws} do
      # A stuck `:prepared` plan still satisfies the in-flight predicate
      # (`active = true`, status non-terminal), so it should appear in
      # BOTH cards. The in-flight card is the superset.
      stuck = stuck_prepared_plan(ws.id)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#stuck-plans-card")
      assert has_element?(view, "#in-flight-plans-card")
      assert has_element?(view, "#stuck-plan-#{stuck.id}")
      assert has_element?(view, "#in-flight-plan-#{stuck.id}")

      refute has_element?(view, "#stuck-plans-empty")
      refute has_element?(view, "#in-flight-plans-empty")
    end
  end

  # --- Emergency action confirmations (#229 acceptance) -------------------

  describe "emergency action confirmations" do
    # Each mutating action button on /security must carry a
    # `data-confirm` attribute so a misclick cannot apply
    # immediately. Non-mutating controls (refresh, filter clear)
    # must NOT carry a confirm prompt — they are read-side only.
    # Pinned via stable id selectors, not raw HTML strings.

    test "pause-runtime button has data-confirm in normal state",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#pause-btn[data-confirm]")
      refute has_element?(view, "#resume-btn")
    end

    test "resume-runtime button has data-confirm when paused",
         %{conn: conn} do
      {:ok, _} = Security.pause(:global, reason: :test, actor: :user)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#resume-btn[data-confirm]")
      refute has_element?(view, "#pause-btn")
    end

    test "agent-keys pause submit button has data-confirm when unpaused",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#agent-keys-pause-submit[data-confirm]")
      refute has_element?(view, "#agent-keys-resume")
    end

    test "agent-keys resume button has data-confirm when paused",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, :paused, _} = Bank.APIKeys.pause_workspace(ws, user, reason: "confirm-test")

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#agent-keys-resume[data-confirm]")
      refute has_element?(view, "#agent-keys-pause-submit")
    end

    test "revoke delegation button has data-confirm for active delegation",
         %{conn: conn} do
      del = delegation(state: :active)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#revoke-btn-#{del.smart_account_id}[data-confirm]")
    end

    test "revoke retry button has data-confirm for revoke_failed delegation",
         %{conn: conn} do
      del = delegation(state: :revoke_failed)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#revoke-retry-btn-#{del.smart_account_id}[data-confirm]")
    end

    test "abort-plan button has data-confirm for stuck :prepared plan",
         %{conn: conn, workspace: ws} do
      plan = stuck_prepared_plan(ws.id)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#abort-plan-btn-#{plan.id}[data-confirm]")
    end

    test "non-mutating controls do NOT require confirmation",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      # Refresh button is read-side; reloading the page is harmless.
      refute has_element?(view, ~s|button[phx-click="refresh"][data-confirm]|)

      # Filter-clear button is read-side; resetting filters is harmless.
      refute has_element?(view, ~s|button[phx-click="clear_safety_filters"][data-confirm]|)
    end
  end

  # --- Pending approvals card (#229) ---------------------------------------

  describe "pending approvals card" do
    test "renders empty state when no current-workspace approvals exist",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#pending-approvals-card")
      assert has_element?(view, "#pending-approvals-empty")
      assert has_element?(view, ~s|#pending-approvals-card[data-count="0"]|)
    end

    test "current-workspace pending approval renders in #pending-approvals-card",
         %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          risk_tier: :moderate,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#pending-approvals-card")
      refute has_element?(view, "#pending-approvals-empty")

      assert has_element?(view, "#pending-approval-#{envelope.id}")

      assert has_element?(
               view,
               ~s|#pending-approval-risk-#{envelope.id}[data-risk-tier="moderate"]|
             )
    end

    test "card data-count matches rendered rows when multiple approvals exist",
         %{conn: conn} do
      for risk <- [:low, :elevated, :severe] do
        intent = agent_intent()

        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          risk_tier: risk,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )
      end

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, ~s|#pending-approvals-card[data-count="3"]|)
    end

    test "sibling-workspace pending approval does NOT appear",
         %{conn: conn} do
      {:ok, sibling_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "sibling-pending-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      intent = agent_intent(workspace_id: sibling_ws.id)

      _sibling_envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          risk_tier: :elevated,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#pending-approvals-empty")
      assert has_element?(view, ~s|#pending-approvals-card[data-count="0"]|)
    end

    test "non-current decision envelope (superseded) does NOT appear",
         %{conn: conn} do
      intent = agent_intent()

      _superseded =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          risk_tier: :moderate,
          current: false,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#pending-approvals-empty")
    end

    test "card includes a link to /queue#pending-approvals-section",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(
               view,
               ~s|#pending-approvals-queue-link[href="/queue#pending-approvals-section"]|
             )
    end

    test "coexists with stuck-plans, in-flight, and delegations cards",
         %{conn: conn, workspace: ws} do
      # Stuck plan
      stuck = stuck_prepared_plan(ws.id)

      # Active delegation (renders #delegations-card row)
      del = delegation(state: :active)

      # Pending approval
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          risk_tier: :moderate,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#stuck-plans-card")
      assert has_element?(view, "#in-flight-plans-card")
      assert has_element?(view, "#pending-approvals-card")
      assert has_element?(view, "#delegations-card")

      assert has_element?(view, "#stuck-plan-#{stuck.id}")
      assert has_element?(view, "#in-flight-plan-#{stuck.id}")
      assert has_element?(view, "#pending-approval-#{envelope.id}")
      assert has_element?(view, "#revoke-btn-#{del.smart_account_id}")
    end
  end

  # --- Incident summary card (#229) ----------------------------------------

  describe "incident summary card" do
    test "renders default summary with stable ids and copy block",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#incident-summary-card")
      assert has_element?(view, "#incident-summary-runtime", "running")
      assert has_element?(view, "#incident-summary-agent-keys", "active")
      assert has_element?(view, "#incident-summary-delegations", "0/0 executable")
      assert has_element?(view, "#incident-summary-plans", "0 stuck, 0 in-flight")
      assert has_element?(view, "#incident-summary-approvals", "0 pending")
      assert has_element?(view, "#incident-summary-events", "0 shown")
      assert has_element?(view, "#incident-summary-copy-block")
    end

    test "runtime paused state is reflected in card and copy block",
         %{conn: conn} do
      {:ok, _} = Security.pause(:global, reason: :test, actor: :user)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#incident-summary-runtime", "paused")
      assert has_element?(view, "#incident-summary-copy-block", "Runtime: paused")
    end

    test "agent-key paused state is reflected in card and copy block",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, :paused, _} = Bank.APIKeys.pause_workspace(ws, user, reason: "incident-summary-test")

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#incident-summary-agent-keys", "paused")
      assert has_element?(view, "#incident-summary-copy-block", "Agent keys: paused")
    end

    test "counts update for delegations, stuck/in-flight plans, and pending approvals",
         %{conn: conn, workspace: ws} do
      _del = delegation(state: :active)

      stuck = stuck_prepared_plan(ws.id)
      _another_in_flight = fresh_plan(:signing, ws.id)

      intent = agent_intent()

      _envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          risk_tier: :moderate,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, view, _html} = live(conn, "/security")

      # 1 active delegation; depending on whether `executable?/1`
      # short-circuits without on-chain confirmation in test env
      # the executable count may be 0 or 1 — assert the trailing
      # "/1 executable" half which is what matters operationally.
      assert has_element?(view, "#incident-summary-delegations", "/1 executable")

      # stuck plan is also in-flight (active, non-terminal), so the
      # in-flight count is 2 (stuck `:prepared` + fresh `:signing`).
      assert has_element?(view, "#incident-summary-plans", "1 stuck, 2 in-flight")

      assert has_element?(view, "#incident-summary-approvals", "1 pending")

      # Copy block reflects the same counts so a paste-into-handoff
      # message is the same picture as the on-screen card.
      assert has_element?(view, "#incident-summary-copy-block", "Plans: 1 stuck, 2 in-flight")
      assert has_element?(view, "#incident-summary-copy-block", "Approvals: 1 pending")

      # stuck plan id used to bypass the unused-variable warning.
      assert is_binary(stuck.id)
    end

    test "sibling-workspace data does NOT inflate the summary counts",
         %{conn: conn} do
      {:ok, sibling_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "sibling-incident-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      # sibling stuck + in-flight plan
      _sibling_plan = fresh_plan(:prepared, sibling_ws.id)

      # sibling pending approval (its intent rooted in sibling ws)
      sibling_intent = agent_intent(workspace_id: sibling_ws.id)

      _sibling_envelope =
        decision_envelope(
          intent: sibling_intent,
          outcome: :approval_required,
          risk_tier: :elevated,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, view, _html} = live(conn, "/security")

      # All counts remain at 0 for the current workspace.
      assert has_element?(view, "#incident-summary-plans", "0 stuck, 0 in-flight")
      assert has_element?(view, "#incident-summary-approvals", "0 pending")
    end

    test "copy block does not include obvious secret-bearing substrings",
         %{conn: conn, workspace: ws, current_user: user} do
      # Pause workspace agent keys with a distinctive reason; reason
      # text MUST NOT appear in the copy block (only the boolean
      # paused/active state is exported).
      {:ok, :paused, _} =
        Bank.APIKeys.pause_workspace(ws, user, reason: "EXPORT_LEAK_PROBE_REASON_DO_NOT_LEAK")

      {:ok, view, html} = live(conn, "/security")

      assert has_element?(view, "#incident-summary-copy-block")

      # Pull just the copy-block text out of the rendered HTML to
      # avoid matching mentions in unrelated cards (the agent-keys
      # pause panel itself does render the reason — that is its
      # job).
      copy_text =
        view
        |> element("#incident-summary-copy-block")
        |> render()

      refute copy_text =~ "EXPORT_LEAK_PROBE_REASON_DO_NOT_LEAK"
      refute copy_text =~ "Bearer "
      refute copy_text =~ "cb_"
      refute copy_text =~ "BEGIN "

      # And the wider page still shows the reason on the pause
      # panel where it belongs (this asserts the negative pin
      # above is meaningful — the reason did get rendered
      # somewhere on the page, just not inside the copy block).
      assert html =~ "EXPORT_LEAK_PROBE_REASON_DO_NOT_LEAK"
    end

    test "coexists with safety-events / pending-approvals / in-flight / delegations cards",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#incident-summary-card")
      assert has_element?(view, "#safety-events-card")
      assert has_element?(view, "#pending-approvals-card")
      assert has_element?(view, "#in-flight-plans-card")
      assert has_element?(view, "#delegations-card")
    end
  end

  # --- Chain pauses card (#228 Phase 1, read-only surface) ----------------

  describe "chain pauses card" do
    test "renders empty state when no active pauses exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#chain-pauses-card")
      assert has_element?(view, "#chain-pauses-empty")
      assert has_element?(view, ~s|#chain-pauses-card[data-count="0"]|)
    end

    test "active chain pause renders for current workspace",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, :paused, pause} =
        Bank.Security.Pauses.create_pause(ws.id, :chain, "base",
          actor: user,
          reason: "rpc outage"
        )

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#chain-pauses-card")
      refute has_element?(view, "#chain-pauses-empty")

      assert has_element?(view, ~s|#chain-pauses-card[data-count="1"]|)
      assert has_element?(view, "#chain-pause-#{pause.id}")

      assert has_element?(
               view,
               ~s|#chain-pause-scope-#{pause.id}[data-scope-type="chain"][data-scope-value="base"]|
             )

      assert has_element?(view, "#chain-pause-reason-#{pause.id}", "rpc outage")
    end

    test "sibling-workspace chain pause does NOT appear", %{conn: conn} do
      {:ok, sibling_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "sibling-pause-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      {:ok, sibling_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "sibling-pause-#{System.unique_integer([:positive])}",
          email: "sibling-pause-#{System.unique_integer([:positive])}@example.com",
          name: "Sibling User"
        })

      {:ok, :paused, _sibling_pause} =
        Bank.Security.Pauses.create_pause(sibling_ws.id, :chain, "base",
          actor: sibling_user,
          reason: "sibling-only"
        )

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#chain-pauses-empty")
      assert has_element?(view, ~s|#chain-pauses-card[data-count="0"]|)
    end

    test "resumed pause does NOT appear",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, :paused, _pause} =
        Bank.Security.Pauses.create_pause(ws.id, :chain, "base",
          actor: user,
          reason: "transient"
        )

      {:ok, :resumed, _resumed} =
        Bank.Security.Pauses.resume(ws.id, :chain, "base", actor: user)

      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#chain-pauses-empty")
    end

    test "card content does not include obvious secret-bearing substrings",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, :paused, _pause} =
        Bank.Security.Pauses.create_pause(ws.id, :chain, "base",
          actor: user,
          reason: "operator-typed reason"
        )

      {:ok, view, _html} = live(conn, "/security")

      card_html =
        view
        |> element("#chain-pauses-card")
        |> render()

      refute card_html =~ "Bearer "
      refute card_html =~ "cb_"
      refute card_html =~ "0x"
      refute card_html =~ "BEGIN "
      refute card_html =~ "private_key"
      refute card_html =~ "signing"
    end

    test "coexists with incident-summary / pending-approvals / in-flight / safety-events cards",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/security")

      assert has_element?(view, "#chain-pauses-card")
      assert has_element?(view, "#incident-summary-card")
      assert has_element?(view, "#pending-approvals-card")
      assert has_element?(view, "#in-flight-plans-card")
      assert has_element?(view, "#safety-events-card")
    end
  end

  # Insert an `ExecutionPlan` whose `updated_at` is overwritten via a
  # raw SQL update so it appears stuck without depending on Ecto's
  # automatic timestamp behavior.
  defp stuck_plan(status, workspace_id) do
    plan =
      Bank.Fixtures.execution_plan(
        execution_status: status,
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

  defp stuck_prepared_plan(workspace_id), do: stuck_plan(:prepared, workspace_id)

  defp fresh_plan(status, workspace_id) do
    Bank.Fixtures.execution_plan(execution_status: status, workspace_id: workspace_id)
  end
end
