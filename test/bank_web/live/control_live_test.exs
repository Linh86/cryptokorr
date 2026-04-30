defmodule BankWeb.ControlLiveTest do
  @moduledoc """
  LiveView tests for the control tower connection page.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user_as_admin

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

      # API Keys link is admin-only (BANK_ADMIN_EMAILS); a workspace-admin
      # who is NOT in the bootstrap allowlist must not see it.
      refute html =~ ~s(href="/admin/api_keys")
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
        grant_delegation("sa_main", "del_main", %{
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
          chain: "base",
          workspace_id: Process.get(:bank_test_workspace_id)
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
      {:ok, _del} = grant_delegation("sa_revoking", "del_revoking")
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
      {:ok, _del} = grant_delegation("sa_paused", "del_paused")
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
      {:ok, _del} = grant_delegation("sa_revoke", "del_revoke")
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

  # --- Multi-account support -----------------------------------------------

  describe "multiple delegations" do
    setup do
      {:ok, d1} = grant_delegation("sa_primary", "del_primary")
      {:ok, d2} = grant_delegation("sa_secondary", "del_secondary")
      %{primary: d1, secondary: d2}
    end

    test "renders account selector when more than one delegation exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~s(id="account-selector")
      assert html =~ ~s(id="account-tab-sa_primary")
      assert html =~ ~s(id="account-tab-sa_secondary")
    end

    test "defaults to the first delegation from list_active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # list_active orders by desc inserted_at, so sa_secondary is first.
      assert html =~ "sa_secondary"
    end

    test "select_account switches the rendered delegation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> element("#account-tab-sa_primary")
        |> render_click()

      assert html =~ ~s(id="delegation-card")
      assert html =~ "sa_primary"
    end

    test "revoke uses the selected account id", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      _ = view |> element("#account-tab-sa_primary") |> render_click()
      html = view |> element("#revoke-btn") |> render_click()

      assert html =~ "Revoking"
      assert Delegations.get("sa_primary").state == :revoking
      assert Delegations.get("sa_secondary").state == :active
    end

    test "selecting an unknown account id is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "select_account", %{"smart-account-id" => "sa_not_real"})

      html = render(view)
      assert html =~ ~s(id="delegation-card")
    end
  end

  describe "account selector absent for single delegation" do
    setup do
      {:ok, _del} = grant_delegation("sa_solo", "del_solo")
      :ok
    end

    test "no selector when there is only one delegation", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ ~s(id="account-selector")
      assert html =~ "sa_solo"
    end
  end
end
