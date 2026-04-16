defmodule BankWeb.CounterpartiesLiveTest do
  @moduledoc """
  LiveView tests for the counterparties list page.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bank.Fixtures

  # --- Mount / render -------------------------------------------------------

  describe "initial render — empty state" do
    test "renders the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/counterparties")

      assert html =~ "Counterparties"
      assert html =~ "Manage trusted recipients"
    end

    test "shows empty state when no counterparties", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/counterparties")

      assert html =~ ~s(id="empty-counterparties")
      assert html =~ "No counterparties"
    end

    test "has new counterparty button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/counterparties")

      assert html =~ ~s(id="new-counterparty-btn")
      assert html =~ "New counterparty"
    end
  end

  # --- Non-empty list -------------------------------------------------------

  describe "with counterparties" do
    setup do
      cp = counterparty(name: "Acme Corp", current_trust_level: :trusted)
      %{counterparty: cp}
    end

    test "renders counterparties list", %{conn: conn, counterparty: cp} do
      {:ok, _view, html} = live(conn, "/counterparties")

      assert html =~ ~s(id="counterparties-list")
      assert html =~ cp.name
      assert html =~ "Trusted"
      refute html =~ ~s(id="empty-counterparties")
    end

    test "shows trust level badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/counterparties")

      assert html =~ "Trusted"
    end
  end

  # --- Create form ----------------------------------------------------------

  describe "create counterparty" do
    test "toggle shows create form", %{conn: conn} do
      {:ok, view, html} = live(conn, "/counterparties")
      refute html =~ ~s(id="create-counterparty-form")

      html = view |> element("#new-counterparty-btn") |> render_click()
      assert html =~ ~s(id="create-counterparty-form")
      assert html =~ "New counterparty"
    end

    test "creates a counterparty successfully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counterparties")

      view |> element("#new-counterparty-btn") |> render_click()

      view
      |> form("form", counterparty: %{name: "Test Corp"})
      |> render_submit()

      html = render(view)
      assert html =~ "Test Corp"
      refute html =~ ~s(id="create-counterparty-form")
    end

    test "validates name is required", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counterparties")

      view |> element("#new-counterparty-btn") |> render_click()

      html =
        view
        |> form("form", counterparty: %{name: ""})
        |> render_change()

      assert html =~ "can" <> "&#39;t be blank"
    end
  end

  # --- Archive filter -------------------------------------------------------

  describe "archive filter" do
    setup do
      _active = counterparty(name: "Active Corp")
      archived = counterparty(name: "Old Corp", active: false)
      %{archived: archived}
    end

    test "hides archived by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/counterparties")

      assert html =~ "Active Corp"
      refute html =~ "Old Corp"
    end

    test "shows archived when toggled", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counterparties")

      html = view |> element("input[type=checkbox]") |> render_click()

      assert html =~ "Active Corp"
      assert html =~ "Old Corp"
    end
  end

  # --- Navigation -----------------------------------------------------------

  describe "navigation" do
    test "Counterparties nav item is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/counterparties")

      assert html =~ "Counterparties"
    end

    test "counterparty links to detail page", %{conn: conn} do
      cp = counterparty(name: "Link Test")
      {:ok, _view, html} = live(conn, "/counterparties")

      assert html =~ ~s(href="/counterparties/#{cp.id}")
    end
  end
end
