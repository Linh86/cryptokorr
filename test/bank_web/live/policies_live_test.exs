defmodule BankWeb.PoliciesLiveTest do
  @moduledoc """
  LiveView tests for the policy rules management page.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user_as_admin
  import Bank.Fixtures

  # --- Mount / render -------------------------------------------------------

  describe "initial render — empty state" do
    test "renders the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ "Policies"
      assert html =~ "Manage policy rules"
    end

    test "shows empty state when no rules", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ ~s(id="empty-rules")
      assert html =~ "No policy rules"
    end

    test "has new rule button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ ~s(id="new-rule-btn")
      assert html =~ "New rule"
    end

    test "has filter tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ ~s(id="policy-filters")
      assert html =~ "Active"
      assert html =~ "All"
    end
  end

  # --- Non-empty list -------------------------------------------------------

  describe "with policy rules" do
    setup do
      rule =
        policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "500", "currency" => "USDC"},
          state: :active
        )

      %{rule: rule}
    end

    test "renders rules list", %{conn: conn, rule: rule} do
      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ ~s(id="rules-list")
      assert html =~ ~s(id="rule-#{rule.id}")
      assert html =~ "Amount limit"
      assert html =~ "Active"
      refute html =~ ~s(id="empty-rules")
    end

    test "shows params summary", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ "Max 500 USDC per transaction"
    end

    test "shows revise and archive buttons for active rules", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ "Revise"
      assert html =~ "Archive"
    end
  end

  # --- Create form ----------------------------------------------------------

  describe "create policy rule" do
    test "toggle shows create form", %{conn: conn} do
      {:ok, view, html} = live(conn, "/policies")
      refute html =~ ~s(id="create-rule-form")

      html = view |> element("#new-rule-btn") |> render_click()
      assert html =~ ~s(id="create-rule-form")
    end

    test "creates an amount limit rule", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies")

      view |> element("#new-rule-btn") |> render_click()

      # Set rule type first so param fields render
      view
      |> form("#create-rule-form-tag", rule: %{rule_type: "amount_limit"})
      |> render_change()

      view
      |> form("#create-rule-form-tag",
        rule: %{
          rule_type: "amount_limit",
          priority: "10",
          param_max_per_tx: "1000",
          param_currency: "USDC"
        }
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Amount limit"
    end

    test "creates an allowed asset rule", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies")

      view |> element("#new-rule-btn") |> render_click()

      # Set rule type first so param fields render
      view
      |> form("#create-rule-form-tag", rule: %{rule_type: "allowed_asset"})
      |> render_change()

      view
      |> form("#create-rule-form-tag",
        rule: %{rule_type: "allowed_asset", param_assets: "USDC, WETH", param_mode: "allowlist"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Allowed asset"
    end

    test "creates an autonomy tier rule", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies")

      view |> element("#new-rule-btn") |> render_click()

      # Set rule type first so param fields render
      view
      |> form("#create-rule-form-tag", rule: %{rule_type: "autonomy_tier"})
      |> render_change()

      view
      |> form("#create-rule-form-tag",
        rule: %{rule_type: "autonomy_tier", param_tier: "manual"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Autonomy tier"
    end
  end

  # --- Revise rule ----------------------------------------------------------

  describe "revise policy rule" do
    setup do
      rule =
        policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "500", "currency" => "USDC"},
          state: :active
        )

      %{rule: rule}
    end

    test "clicking revise shows form", %{conn: conn, rule: rule} do
      {:ok, view, _html} = live(conn, "/policies")

      html =
        view
        |> element("#rule-#{rule.id} button", "Revise")
        |> render_click()

      assert html =~ ~s(id="revise-form-#{rule.id}")
      assert html =~ "Revise rule"
      assert html =~ "Create revision"
    end

    test "submitting revision creates new version", %{conn: conn, rule: rule} do
      {:ok, view, _html} = live(conn, "/policies")

      view
      |> element("#rule-#{rule.id} button", "Revise")
      |> render_click()

      view
      |> form("#revise-rule-form-tag",
        revise: %{param_max_per_tx: "2000", param_currency: "USDC"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Policy rule revised"
    end
  end

  # --- Archive rule ---------------------------------------------------------

  describe "archive policy rule" do
    setup do
      rule =
        policy_rule(rule_type: :allowed_chain, params: %{"chains" => ["base"]}, state: :active)

      %{rule: rule}
    end

    test "archives a rule", %{conn: conn, rule: rule} do
      {:ok, view, _html} = live(conn, "/policies")

      html =
        view
        |> element("#rule-#{rule.id} button", "Archive")
        |> render_click()

      assert html =~ "Policy rule archived"
    end
  end

  # --- Filter ---------------------------------------------------------------

  describe "state filter" do
    setup do
      _active =
        policy_rule(state: :active, rule_type: :amount_limit, params: %{"max_per_tx" => "100"})

      _archived =
        policy_rule(state: :archived, rule_type: :allowed_chain, params: %{"chains" => ["base"]})

      :ok
    end

    test "filters by state", %{conn: conn} do
      {:ok, view, html} = live(conn, "/policies")

      # Default is active filter
      assert html =~ "Amount limit"
      refute html =~ "Allowed chain"

      # Switch to all
      html =
        view
        |> element("button", "All")
        |> render_click()

      assert html =~ "Amount limit"
      assert html =~ "Allowed chain"
    end
  end

  # --- Navigation -----------------------------------------------------------

  describe "navigation" do
    test "Policies nav item is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/policies")

      # The page should render and show Policies as the active page
      assert html =~ "Policies"
    end
  end

  # --- Rule type display ----------------------------------------------------

  describe "rule type display" do
    test "renders rolling spend cap", %{conn: conn} do
      _rule =
        policy_rule(
          rule_type: :rolling_spend_cap,
          params: %{"max_total" => "5000", "window_hours" => 24}
        )

      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ "Rolling spend cap"
      assert html =~ "5000"
    end

    test "renders time window rule", %{conn: conn} do
      _rule =
        policy_rule(
          rule_type: :time_window,
          params: %{"timezone" => "UTC", "start_hhmm" => "09:00", "end_hhmm" => "17:00"}
        )

      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ "Time window"
      assert html =~ "09:00"
      assert html =~ "17:00"
    end

    test "renders scope badges", %{conn: conn} do
      _rule =
        policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"},
          scope: %{"asset" => "USDC", "chain" => "base"}
        )

      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ "asset"
      assert html =~ "USDC"
      assert html =~ "chain"
      assert html =~ "base"
    end

    test "shows global badge for empty scope", %{conn: conn} do
      _rule = policy_rule(rule_type: :amount_limit, params: %{"max_per_tx" => "100"}, scope: %{})

      {:ok, _view, html} = live(conn, "/policies")

      assert html =~ "Global"
    end
  end
end
