defmodule BankWeb.PolicyBuilderLiveTest do
  @moduledoc """
  LiveView tests for the admin policy-builder UI (#224).

  Coverage matches the issue body's `## Tests` block:

    * LiveView form tests for each MVP rule family
    * non-admin blocked from edits
    * invalid params show errors
    * draft / publish state displayed
    * cross-workspace isolation

  Setup is `async: false` so the role-upgrade pattern from
  `Bank.ConnCase.upgrade_to_admin_role/1` (which mutates the
  caller's membership row) doesn't bleed across parallel tests.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bank.Policies
  alias Bank.Policies.{PolicyVersion, Versions}
  alias Bank.Repo

  # --- mount / render --------------------------------------------------

  describe "mount + render" do
    setup :register_and_log_in_user

    test "renders the policy builder page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/policies/builder")

      assert html =~ "Policy builder"
      assert html =~ ~s(id="policy-builder")
      assert html =~ ~s(id="policy-builder-published")
      assert html =~ ~s(id="policy-builder-draft")
    end

    test "shows empty published banner when no version has been published",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/policies/builder")

      assert html =~ ~s(id="policy-builder-published-empty")
      assert html =~ "No policy version has been published"
    end

    test "shows 'No draft open' state when no draft exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/policies/builder")

      assert html =~ ~s(id="policy-builder-draft-state")
      assert html =~ "No draft open"
    end
  end

  # --- non-admin gating ------------------------------------------------

  describe "non-admin (operator) — read-only UI + flash on edit" do
    setup :register_and_log_in_user

    test "operator does NOT see the open-draft button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")

      refute has_element?(view, "#policy-builder-open-draft-btn")
    end

    test "operator-attempted open_draft shows admin-required flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")

      # Defence in depth: even though the button is hidden for
      # operators, the handle_event must reject if invoked
      # programmatically.
      html = render_hook(view, "open_draft", %{})

      assert html =~ "Admin role required"
    end

    test "operator-attempted save_rule shows admin-required flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")

      html =
        render_hook(view, "save_rule", %{
          "rule" => %{"rule_type" => "amount_limit", "max_per_tx" => "10"}
        })

      assert html =~ "Admin role required"
    end
  end

  # --- admin draft + add/edit/delete -----------------------------------

  describe "admin — open draft, add / edit / delete rules" do
    setup [:register_and_log_in_user, :upgrade_to_admin_role]

    test "admin can open a new draft", %{conn: conn} do
      {:ok, view, html} = live(conn, "/policies/builder")
      assert html =~ "No draft open"

      html = view |> element("#policy-builder-open-draft-btn") |> render_click()

      assert html =~ ~s(id="policy-builder-draft-state")
      assert html =~ "Draft v1"
      assert html =~ "Draft opened."
    end

    test "admin can add an amount_limit rule to the draft", %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      html =
        view
        |> form("#policy-builder-rule-form", %{
          "rule" => %{
            "rule_type" => "amount_limit",
            "priority" => "10",
            "max_per_tx" => "150"
          }
        })
        |> render_submit()

      assert html =~ "Rule added to draft."
      assert html =~ "Max amount per intent: 150"

      # Side-effect: the draft now lists the new rule's id.
      draft = current_draft(ws.id)
      assert length(PolicyVersion.rule_ids_list(draft)) == 1
    end

    test "admin can add a rolling_spend_cap rule to the draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      html =
        view
        |> form("#policy-builder-rule-form", %{
          "rule" => %{
            "rule_type" => "rolling_spend_cap",
            "priority" => "5",
            "max_total" => "1000",
            "window_hours" => "24"
          }
        })
        |> render_submit()

      assert html =~ "Rule added to draft."
      assert html =~ "Rolling spend cap: 1000 per 24h"
    end

    test "admin can add an allowed_asset rule to the draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      html =
        view
        |> form("#policy-builder-rule-form", %{
          "rule" => %{
            "rule_type" => "allowed_asset",
            "priority" => "0",
            "assets_csv" => "USDC, USDT",
            "mode" => "allowlist"
          }
        })
        |> render_submit()

      assert html =~ "Rule added to draft."
      assert html =~ "Allowed assets (allowlist): USDC, USDT"
    end

    test "admin can add an allowed_chain rule to the draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      html =
        view
        |> form("#policy-builder-rule-form", %{
          "rule" => %{
            "rule_type" => "allowed_chain",
            "priority" => "0",
            "chains_csv" => "base, base-sepolia",
            "mode" => "allowlist"
          }
        })
        |> render_submit()

      assert html =~ "Rule added to draft."
      assert html =~ "Allowed chains (allowlist): base, base-sepolia"
    end

    test "admin can add an autonomy_tier rule to the draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      html =
        view
        |> form("#policy-builder-rule-form", %{
          "rule" => %{
            "rule_type" => "autonomy_tier",
            "priority" => "0",
            "tier" => "manual"
          }
        })
        |> render_submit()

      assert html =~ "Rule added to draft."
      assert html =~ "Autonomy tier: manual"
    end

    test "admin can edit (revise) an existing rule in the draft", %{conn: conn, workspace: ws} do
      # Seed a draft with one amount_limit rule.
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      view
      |> form("#policy-builder-rule-form", %{
        "rule" => %{"rule_type" => "amount_limit", "priority" => "0", "max_per_tx" => "100"}
      })
      |> render_submit()

      [original_id] = current_draft(ws.id) |> PolicyVersion.rule_ids_list()

      # Click "Edit" — form opens in edit mode.
      html = view |> element("#policy-builder-edit-#{original_id}") |> render_click()
      assert html =~ "Save changes"

      # Submit revised value.
      html =
        view
        |> form("#policy-builder-rule-form", %{
          "rule" => %{"rule_type" => "amount_limit", "priority" => "0", "max_per_tx" => "250"}
        })
        |> render_submit()

      assert html =~ "Rule updated in draft."
      assert html =~ "Max amount per intent: 250"

      # The draft's rule_ids list now contains a NEW (successor)
      # id; the original is dropped.
      [new_id] = current_draft(ws.id) |> PolicyVersion.rule_ids_list()
      refute new_id == original_id
    end

    test "admin can remove a rule from the draft", %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      view
      |> form("#policy-builder-rule-form", %{
        "rule" => %{"rule_type" => "amount_limit", "priority" => "0", "max_per_tx" => "100"}
      })
      |> render_submit()

      [rule_id] = current_draft(ws.id) |> PolicyVersion.rule_ids_list()

      html = view |> element("#policy-builder-remove-#{rule_id}") |> render_click()
      assert html =~ "Rule removed from draft."

      assert PolicyVersion.rule_ids_list(current_draft(ws.id)) == []
    end
  end

  # --- validation errors ----------------------------------------------

  describe "admin — invalid params show errors" do
    setup [:register_and_log_in_user, :upgrade_to_admin_role]

    test "amount_limit without max_per_tx fails the form changeset",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      html =
        view
        |> form("#policy-builder-rule-form", %{
          "rule" => %{"rule_type" => "amount_limit", "priority" => "0", "max_per_tx" => ""}
        })
        |> render_submit()

      # Form re-renders with the error and no rule was added.
      refute html =~ "Rule added to draft."
      assert html =~ "is required"
    end

    test "rolling_spend_cap with non-positive window_hours fails",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      html =
        view
        |> form("#policy-builder-rule-form", %{
          "rule" => %{
            "rule_type" => "rolling_spend_cap",
            "priority" => "0",
            "max_total" => "1000",
            "window_hours" => "0"
          }
        })
        |> render_submit()

      refute html =~ "Rule added to draft."
      assert html =~ "must be greater than 0"
    end

    test "allowed_asset with empty assets_csv fails", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      html =
        view
        |> form("#policy-builder-rule-form", %{
          "rule" => %{
            "rule_type" => "allowed_asset",
            "priority" => "0",
            "assets_csv" => "",
            "mode" => "allowlist"
          }
        })
        |> render_submit()

      refute html =~ "Rule added to draft."
      assert html =~ "list at least one asset"
    end
  end

  # --- published policy is read-only -----------------------------------

  describe "published policy is read-only in UI" do
    setup [:register_and_log_in_user, :upgrade_to_admin_role]

    test "published version banner renders without edit affordances",
         %{conn: conn, workspace: ws, current_user: user} do
      # Seed a published version with one rule outside the LiveView.
      rule =
        Bank.Fixtures.policy_rule(
          rule_type: :amount_limit,
          state: :active,
          params: %{"max_per_tx" => "100"},
          workspace_id: ws.id
        )

      {:ok, draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: user.id,
          rule_ids: %{"items" => [rule.id]}
        )

      {:ok, _published} =
        Versions.publish_draft(draft, published_by: :user, actor_id: user.id)

      {:ok, view, html} = live(conn, "/policies/builder")

      assert html =~ ~s(id="policy-builder-published-meta")
      assert html =~ "Version"
      # Published rule appears in the published list with a stable id.
      assert has_element?(view, "#policy-builder-published-rule-#{rule.id}")

      # NO edit / remove affordances on the published rule.
      refute has_element?(view, "#policy-builder-edit-#{rule.id}")
      refute has_element?(view, "#policy-builder-remove-#{rule.id}")
    end
  end

  # --- draft / publish state displayed --------------------------------

  describe "draft / publish state shown via stable badges" do
    setup [:register_and_log_in_user, :upgrade_to_admin_role]

    test "draft badge transitions through open → publish",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/policies/builder")
      assert html =~ "No draft open"

      view |> element("#policy-builder-open-draft-btn") |> render_click()

      view
      |> form("#policy-builder-rule-form", %{
        "rule" => %{"rule_type" => "amount_limit", "priority" => "0", "max_per_tx" => "100"}
      })
      |> render_submit()

      assert has_element?(view, "#policy-builder-publish-btn")

      html = view |> element("#policy-builder-publish-btn") |> render_click()
      assert html =~ "Draft published."
      # After publish, the draft section returns to "No draft open"
      # (no draft remains; the published banner now carries the
      # state).
      assert html =~ "No draft open"
    end
  end

  # --- cross-workspace isolation ---------------------------------------

  describe "cross-workspace isolation" do
    setup [:register_and_log_in_user, :upgrade_to_admin_role]

    test "another workspace's draft is not visible in this workspace's builder",
         %{conn: conn} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "policy-builder-other-#{System.unique_integer([:positive])}",
          name: "Other"
        })

      {:ok, _draft_b} =
        Versions.create_draft(ws_b.id, created_by: :user, actor_id: Ecto.UUID.generate())

      {:ok, _view, html} = live(conn, "/policies/builder")

      # The current workspace has no draft — the badge says so.
      assert html =~ "No draft open"
      refute html =~ "Draft v1"
    end
  end

  # --- helpers ---------------------------------------------------------

  defp current_draft(ws_id) do
    ws_id
    |> Versions.list_versions(status: :draft, limit: 1)
    |> List.first()
    |> Repo.reload()
  end

  # Avoid unused-alias warnings if `Policies` becomes unused after a
  # refactor to a context-only API.
  _ = {Policies}
end
