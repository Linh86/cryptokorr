defmodule BankWeb.CounterpartyDetailLiveTest do
  @moduledoc """
  LiveView tests for the counterparty detail page.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bank.Fixtures

  setup do
    cp = counterparty(name: "Detail Corp", current_trust_level: :unknown)
    %{counterparty: cp}
  end

  # --- Mount / render -------------------------------------------------------

  describe "initial render" do
    test "renders counterparty details", %{conn: conn, counterparty: cp} do
      {:ok, _view, html} = live(conn, "/counterparties/#{cp.id}")

      assert html =~ "Detail Corp"
      assert html =~ "Unknown"
      assert html =~ ~s(id="page-title")
    end

    test "shows addresses section", %{conn: conn, counterparty: cp} do
      {:ok, _view, html} = live(conn, "/counterparties/#{cp.id}")

      assert html =~ ~s(id="addresses-section")
      assert html =~ "No addresses yet"
    end

    test "shows evidence section", %{conn: conn, counterparty: cp} do
      {:ok, _view, html} = live(conn, "/counterparties/#{cp.id}")

      assert html =~ ~s(id="evidence-section")
      assert html =~ "No evidence yet"
    end

    test "shows trust section", %{conn: conn, counterparty: cp} do
      {:ok, _view, html} = live(conn, "/counterparties/#{cp.id}")

      assert html =~ ~s(id="trust-section")
    end

    test "shows details card", %{conn: conn, counterparty: cp} do
      {:ok, _view, html} = live(conn, "/counterparties/#{cp.id}")

      assert html =~ ~s(id="details-card")
      assert html =~ "Active"
      assert html =~ cp.id
    end

    test "redirects on not found", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/counterparties"}}} =
               live(conn, "/counterparties/#{Ecto.UUID.generate()}")
    end
  end

  # --- Edit counterparty ----------------------------------------------------

  describe "edit counterparty" do
    test "toggle shows edit form", %{conn: conn, counterparty: cp} do
      {:ok, view, html} = live(conn, "/counterparties/#{cp.id}")
      refute html =~ ~s(id="edit-form")

      html = view |> element("button", "Edit") |> render_click()
      assert html =~ ~s(id="edit-form")
    end

    test "saves edited name", %{conn: conn, counterparty: cp} do
      {:ok, view, _html} = live(conn, "/counterparties/#{cp.id}")

      view |> element("button", "Edit") |> render_click()

      view
      |> form("#edit-form form", counterparty: %{name: "Renamed Corp"})
      |> render_submit()

      html = render(view)
      assert html =~ "Renamed Corp"
    end
  end

  # --- Archive --------------------------------------------------------------

  describe "archive counterparty" do
    test "archives the counterparty", %{conn: conn, counterparty: cp} do
      {:ok, view, html} = live(conn, "/counterparties/#{cp.id}")
      assert html =~ ~s(id="archive-btn")

      view |> element("#archive-btn") |> render_click()

      html = render(view)
      assert html =~ "Archived"
    end
  end

  # --- Address labels -------------------------------------------------------

  describe "address labels" do
    test "toggle shows add address form", %{conn: conn, counterparty: cp} do
      {:ok, view, html} = live(conn, "/counterparties/#{cp.id}")
      refute html =~ ~s(id="add-address-form")

      html = view |> element("#add-address-btn") |> render_click()
      assert html =~ ~s(id="add-address-form")
    end

    test "adds an address label", %{conn: conn, counterparty: cp} do
      {:ok, view, _html} = live(conn, "/counterparties/#{cp.id}")

      view |> element("#add-address-btn") |> render_click()

      view
      |> form("#add-address-form form",
        address_label: %{chain: "base", address: "0xabc123", role: "payout"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "0xabc123"
      assert html =~ "base"
    end

    test "retires an address label", %{conn: conn, counterparty: cp} do
      label = address_label(counterparty: cp, chain: "base", address: "0xretire")

      {:ok, view, html} = live(conn, "/counterparties/#{cp.id}")
      assert html =~ "0xretire"

      view
      |> element("#addr-#{label.id} button", "Retire")
      |> render_click()

      html = render(view)
      # The retired address should disappear from the active list
      refute html =~ "0xretire"
    end
  end

  # --- Evidence -------------------------------------------------------------

  describe "evidence" do
    test "toggle shows add evidence form", %{conn: conn, counterparty: cp} do
      {:ok, view, html} = live(conn, "/counterparties/#{cp.id}")
      refute html =~ ~s(id="add-evidence-form")

      html = view |> element("#add-evidence-btn") |> render_click()
      assert html =~ ~s(id="add-evidence-form")
    end

    test "adds evidence artifact", %{conn: conn, counterparty: cp} do
      {:ok, view, _html} = live(conn, "/counterparties/#{cp.id}")

      view |> element("#add-evidence-btn") |> render_click()

      view
      |> form("#add-evidence-form form",
        evidence: %{kind: "user_note", content_uri: "https://example.com/doc"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "https://example.com/doc"
      assert html =~ "User note"
    end

    test "shows existing evidence", %{conn: conn, counterparty: cp} do
      _ev =
        evidence_artifact(
          subject: cp,
          kind: :external_lookup,
          content_uri: "https://check.example.com"
        )

      {:ok, _view, html} = live(conn, "/counterparties/#{cp.id}")

      assert html =~ "External lookup"
      assert html =~ "https://check.example.com"
    end
  end

  # --- Trust assertions -----------------------------------------------------

  describe "trust assertions" do
    test "toggle shows trust assertion form", %{conn: conn, counterparty: cp} do
      {:ok, view, html} = live(conn, "/counterparties/#{cp.id}")
      refute html =~ ~s(id="assert-trust-form")

      html = view |> element("#assert-trust-btn") |> render_click()
      assert html =~ ~s(id="assert-trust-form")
    end

    test "issues a trust assertion", %{conn: conn, counterparty: cp} do
      {:ok, view, _html} = live(conn, "/counterparties/#{cp.id}")

      view |> element("#assert-trust-btn") |> render_click()

      view
      |> form("#assert-trust-form form",
        trust: %{level: "trusted", rationale: "Verified partner"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Trusted"
    end

    test "shows existing trust assertions", %{conn: conn, counterparty: cp} do
      _assertion =
        trust_assertion(
          subject: cp,
          level: :sensitive,
          rationale: "Needs review"
        )

      {:ok, _view, html} = live(conn, "/counterparties/#{cp.id}")

      assert html =~ "Sensitive"
      assert html =~ "Needs review"
    end
  end

  # --- Back navigation ------------------------------------------------------

  describe "navigation" do
    test "back link points to counterparties list", %{conn: conn, counterparty: cp} do
      {:ok, _view, html} = live(conn, "/counterparties/#{cp.id}")

      assert html =~ "Back to counterparties"
      assert html =~ ~s(href="/counterparties")
    end
  end
end
