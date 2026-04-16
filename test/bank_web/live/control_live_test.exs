defmodule BankWeb.ControlLiveTest do
  @moduledoc """
  LiveView tests for the control tower connection page.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bank.Delegations
  alias Bank.Security
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  # --- Mount / render -------------------------------------------------------

  describe "initial render — no delegation" do
    test "renders the page with disconnected state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Connection"
      assert html =~ "No delegation connected"
      assert html =~ "Refresh status"
      assert html =~ "Execution blocked"
    end

    test "contains expected DOM IDs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~s(id="page-title")
      assert html =~ ~s(id="delegation-card")
      assert html =~ ~s(id="system-status-bar")
      assert html =~ ~s(id="next-steps-card")
      assert html =~ ~s(id="runtime-card")
      assert html =~ ~s(id="architecture-info")
    end

    test "shows next step guidance for establishing delegation", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Establish a delegation through the adapter callback flow"
      assert html =~ ~s(id="wallet-connect-btn")
      assert html =~ "Connect wallet"
    end

    test "shows navigation sidebar with Connection active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Bank v0.1"
      assert html =~ "Control Tower"
      assert html =~ "Connection"
      assert html =~ "Intents"
      assert html =~ "Policies"
    end

    test "shows architecture info panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Non-custodial architecture"
      assert html =~ "Control plane"
      assert html =~ "Chain adapter"
      assert html =~ "On-chain guardrails"
    end
  end

  # --- Active delegation ---------------------------------------------------

  describe "with active delegation" do
    setup do
      {:ok, del} =
        Delegations.grant("sa_main", "del_main", %{
          scope: %{"asset" => "USDC"},
          expires_at: ~U[2030-01-01 00:00:00Z]
        })

      %{delegation: del}
    end

    test "renders the delegation card with details", %{conn: conn, delegation: del} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Smart Account Delegation"
      assert html =~ "sa_main"
      assert html =~ "Active"
      assert html =~ "Base"
      assert html =~ "USDC"
      assert html =~ String.slice(del.delegation_id, 0, 8)
    end

    test "shows execution-ready indicator", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Execution ready"
      assert html =~ ~s(id="execution-ready-indicator")
    end

    test "shows revoke button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~s(id="revoke-btn")
      assert html =~ "Revoke delegation"
    end

    test "shows next step: delegation active and execution ready", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Delegation active and execution ready"
    end
  end

  # --- Pending delegation ---------------------------------------------------

  describe "with pending delegation" do
    setup do
      # Insert a pending delegation directly via the schema
      {:ok, del} =
        %Delegations.Delegation{}
        |> Delegations.Delegation.changeset(%{
          smart_account_id: "sa_pending",
          delegation_id: "del_pending",
          state: :pending,
          chain: "base"
        })
        |> Bank.Repo.insert()

      %{delegation: del}
    end

    test "renders pending state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Pending"
      assert html =~ "Delegation is pending"
    end

    test "shows execution blocked", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Execution blocked"
    end
  end

  # --- Revoking delegation --------------------------------------------------

  describe "with revoking delegation" do
    setup do
      {:ok, _del} = Delegations.grant("sa_revoking", "del_revoking")
      {:ok, _del} = Delegations.record_revoke_requested("sa_revoking")
      :ok
    end

    test "renders revoking state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Revoking"
      assert html =~ "Revocation in flight"
    end

    test "does not show revoke button in revoking state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ ~s(id="revoke-btn")
    end
  end

  # --- Paused runtime -------------------------------------------------------

  describe "paused runtime" do
    test "shows pause indicator and resume button", %{conn: conn} do
      {:ok, :paused} = Security.pause(:global)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Runtime paused"
      assert html =~ ~s(id="pause-indicator")
      assert html =~ ~s(id="resume-btn")
      refute html =~ ~s(id="pause-btn")
    end

    test "pause with active delegation shows action guidance", %{conn: conn} do
      {:ok, _del} = Delegations.grant("sa_paused", "del_paused")
      {:ok, :paused} = Security.pause(:global)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Resume the runtime to enable execution"
    end
  end

  # --- Events ---------------------------------------------------------------

  describe "refresh event" do
    test "reloads state and shows flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = view |> element("button", "Refresh status") |> render_click()

      assert html =~ "No delegation connected"
    end
  end

  describe "revoke_delegation event" do
    setup do
      {:ok, _del} = Delegations.grant("sa_revoke", "del_revoke")
      :ok
    end

    test "submits revocation and reloads state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Click the revoke button (it has phx-value-smart-account-id)
      html =
        view
        |> element("#revoke-btn")
        |> render_click()

      # The delegation should now be revoking
      assert html =~ "Revoking"
    end
  end

  describe "pause/resume events" do
    test "pause_runtime pauses and shows indicator", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = view |> element("#pause-btn") |> render_click()

      assert html =~ "Runtime paused"
      assert html =~ ~s(id="resume-btn")
    end

    test "resume_runtime resumes and shows running", %{conn: conn} do
      {:ok, :paused} = Security.pause(:global)

      {:ok, view, _html} = live(conn, "/")

      html = view |> element("#resume-btn") |> render_click()

      assert html =~ "Running"
      refute html =~ "Runtime paused"
    end
  end

  # --- PubSub real-time updates --------------------------------------------

  describe "PubSub security events" do
    test "security event triggers re-render", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")
      refute html =~ "Runtime paused"

      # Pause externally (e.g. from API)
      {:ok, :paused} = Security.pause(:global)

      # The broadcast on security:events should trigger handle_info
      # which calls load_state
      html = render(view)
      assert html =~ "Runtime paused"
    end
  end

  # --- Chain/asset display --------------------------------------------------

  describe "chain and asset badges" do
    test "shows Base and USDC badges in top bar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Base"
      assert html =~ "USDC"
    end
  end
end
