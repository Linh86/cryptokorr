defmodule BankWeb.SecurityLiveTest do
  @moduledoc """
  LiveView tests for the security console.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user
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
  end

  describe "navigation" do
    test "Security nav item is active on /security", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/security")

      assert html =~ ~s(href="/security")
      assert html =~ "bg-primary/10 text-primary"
    end
  end
end
