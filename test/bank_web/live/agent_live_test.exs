defmodule BankWeb.AgentLiveTest do
  @moduledoc """
  Smoke render tests for the Agent Control redesign screens.

  Phase 1 verifies the AgentLive / AgentActivityLive / AgentAdvancedLive
  templates render under viewer auth without raising — the screens
  themselves run on dummy state, so we just check headings and the
  always-visible TopBar/NavRail anchors.
  """
  use BankWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  describe "Agent screen" do
    test "renders the hero, top bar and all six sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "CryptoKorr"
      assert html =~ "Base Sepolia · testnet"

      assert html =~ "Connect a wallet to begin." or html =~ "Set the agent up in two steps."

      assert html =~ "01 — Wallet"
      assert html =~ "02 — Permission"
      assert html =~ "03 — Mode"
      assert html =~ "04 — Test"
      assert html =~ "05 — Activity"
      assert html =~ "06 — Emergency stop"

      assert html =~ "Stop agent"
    end
  end

  describe "Activity screen" do
    test "renders the filterbar and timeline", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/activity")

      assert html =~ "Everything the agent has touched"
      assert html =~ "filterbar"
      assert html =~ "All"
      assert html =~ "Executed"
      assert html =~ "Blocked &amp; failed"
    end
  end

  describe "Advanced screen" do
    test "renders the accordion of stubbed sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/advanced")

      assert html =~ "For when you need the cockpit"
      assert html =~ "Policy rules"
      assert html =~ "Counterparties"
      assert html =~ "Adapter health"
      assert html =~ "Inbox"
    end
  end
end
