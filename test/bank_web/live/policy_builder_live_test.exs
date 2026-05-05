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

  # --- #224 P2-1: draft edits do not mutate the published policy --------

  describe "draft isolation — editing a draft never disturbs published policy (#224 P2-1)" do
    setup [:register_and_log_in_user, :upgrade_to_admin_role]

    test "editing a draft rule cloned from the current published version does not supersede the published rule before publish",
         %{conn: conn, workspace: ws, current_user: user} do
      # Seed v1 published with one amount_limit rule.
      v1_rule =
        Bank.Fixtures.policy_rule(
          rule_type: :amount_limit,
          state: :active,
          params: %{"max_per_tx" => "100"},
          workspace_id: ws.id
        )

      {:ok, draft_v1} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: user.id,
          rule_ids: %{"items" => [v1_rule.id]}
        )

      {:ok, _v1} =
        Versions.publish_draft(draft_v1, published_by: :user, actor_id: user.id)

      # Sanity: the published snapshot resolves the v1 rule.
      assert %{rules: [%{id: published_rule_id}]} =
               Versions.snapshot_for_workspace(ws.id)

      assert published_rule_id == v1_rule.id

      # Mount the builder, open a new draft (clones from v1), edit
      # the cloned rule via the form.
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      view |> element("#policy-builder-edit-#{v1_rule.id}") |> render_click()

      view
      |> form("#policy-builder-rule-form", %{
        "rule" => %{
          "rule_type" => "amount_limit",
          "priority" => "0",
          "max_per_tx" => "999"
        }
      })
      |> render_submit()

      # P2-1 assertion: the v1 published snapshot is UNCHANGED
      # before the admin clicks Publish. The snapshot must still
      # resolve the original v1 rule (the prior row stays
      # `:active` and stays in the published version's rule_ids).
      snapshot = Versions.snapshot_for_workspace(ws.id)
      assert [%{id: still_resolves}] = snapshot.rules
      assert still_resolves == v1_rule.id

      reloaded_v1_rule = Bank.Repo.get!(Bank.Policies.PolicyRule, v1_rule.id)
      assert reloaded_v1_rule.state == :active

      # Publish the draft and confirm the published snapshot now
      # picks up the edited successor rule.
      view |> element("#policy-builder-publish-btn") |> render_click()

      published_snapshot = Versions.snapshot_for_workspace(ws.id)
      published_ids = Enum.map(published_snapshot.rules, & &1.id)

      refute v1_rule.id in published_ids
      assert length(published_snapshot.rules) >= 1
    end
  end

  # --- #224 P2-2: draft-only rules are not live before publish ----------

  describe "draft isolation — new draft rules do not affect runtime decisions (#224 P2-2)" do
    setup [:register_and_log_in_user, :upgrade_to_admin_role]

    test "in a greenfield workspace, a draft-only rule is not loaded by Policies.load_active_ruleset/1 until publish",
         %{conn: conn, workspace: ws} do
      # Greenfield: no published version. The legacy
      # `Policies.load_active_ruleset/1` (which the runtime falls
      # back to when no published version exists) sees no rules
      # from this workspace yet.
      assert is_nil(Versions.current_published(ws.id))

      ruleset_before =
        Bank.Policies.load_active_ruleset(workspace_id: ws.id)

      assert ruleset_before == []

      # Operator adds a rule via the builder (without publishing).
      {:ok, view, _html} = live(conn, "/policies/builder")
      view |> element("#policy-builder-open-draft-btn") |> render_click()

      view
      |> form("#policy-builder-rule-form", %{
        "rule" => %{
          "rule_type" => "amount_limit",
          "priority" => "0",
          "max_per_tx" => "10"
        }
      })
      |> render_submit()

      # P2-2 assertion: the draft-added rule is NOT in the active
      # workspace ruleset. It sits at `state: :draft` until publish.
      ruleset_during_draft =
        Bank.Policies.load_active_ruleset(workspace_id: ws.id)

      assert ruleset_during_draft == []

      # The draft holds exactly one rule and that rule is in
      # `:draft` state.
      [rule_id] =
        ws.id
        |> Versions.list_versions(status: :draft, limit: 1)
        |> List.first()
        |> Bank.Policies.PolicyVersion.rule_ids_list()

      draft_rule = Bank.Repo.get!(Bank.Policies.PolicyRule, rule_id)
      assert draft_rule.state == :draft

      # Publish — the rule must be activated atomically by
      # `Versions.publish_draft/2`.
      view |> element("#policy-builder-publish-btn") |> render_click()

      reloaded = Bank.Repo.get!(Bank.Policies.PolicyRule, rule_id)
      assert reloaded.state == :active

      # And the published snapshot now resolves the rule for
      # runtime decisions.
      snapshot = Versions.snapshot_for_workspace(ws.id)
      assert Enum.map(snapshot.rules, & &1.id) == [rule_id]
    end
  end

  # --- helpers ---------------------------------------------------------

  defp current_draft(ws_id) do
    ws_id
    |> Versions.list_versions(status: :draft, limit: 1)
    |> List.first()
    |> Repo.reload()
  end

  # --- #225 simulator UI ----------------------------------------------

  describe "policy simulator panel (#225)" do
    setup [:register_and_log_in_user, :upgrade_to_admin_role]

    test "renders the simulator panel and form for admins", %{conn: conn} do
      {:ok, view, html} = live(conn, "/policies/builder")

      assert html =~ ~s(id="policy-builder-simulator")
      assert html =~ "Simulator"
      assert has_element?(view, "#policy-builder-simulator-form")
      assert has_element?(view, "#policy-builder-simulator-run-btn")
    end

    test "running a simulation against a published amount limit shows :block outcome",
         %{conn: conn, workspace: ws, current_user: user} do
      rule =
        Bank.Fixtures.policy_rule(
          rule_type: :amount_limit,
          state: :active,
          workspace_id: ws.id,
          params: %{"max_per_tx" => "100"}
        )

      {:ok, draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: user.id,
          rule_ids: %{"items" => [rule.id]}
        )

      {:ok, _} = Versions.publish_draft(draft, published_by: :user, actor_id: user.id)

      {:ok, view, _html} = live(conn, "/policies/builder")

      html =
        view
        |> form("#policy-builder-simulator-form", %{
          "simulation" => %{
            "kind" => "transfer",
            "asset" => "USDC",
            "chain" => "base",
            "amount" => "150"
          }
        })
        |> render_submit()

      assert html =~ ~s(id="policy-builder-simulator-result")
      assert has_element?(view, "#policy-builder-simulator-published-outcome")
      assert html =~ "block"
      # Matched-rule link points at the published rule's stable id.
      assert has_element?(view, "#policy-builder-simulator-published-matched-#{rule.id}")
    end

    test "draft tightens the limit; the changed banner appears",
         %{conn: conn, workspace: ws, current_user: user} do
      published_rule =
        Bank.Fixtures.policy_rule(
          rule_type: :amount_limit,
          state: :active,
          workspace_id: ws.id,
          params: %{"max_per_tx" => "100"}
        )

      {:ok, pub_draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: user.id,
          rule_ids: %{"items" => [published_rule.id]}
        )

      {:ok, _} = Versions.publish_draft(pub_draft, published_by: :user, actor_id: user.id)

      tighter =
        Bank.Fixtures.policy_rule(
          rule_type: :amount_limit,
          state: :draft,
          workspace_id: ws.id,
          params: %{"max_per_tx" => "50"}
        )

      {:ok, _new_draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: user.id,
          rule_ids: %{"items" => [tighter.id]}
        )

      {:ok, view, _html} = live(conn, "/policies/builder")

      html =
        view
        |> form("#policy-builder-simulator-form", %{
          "simulation" => %{
            "kind" => "transfer",
            "asset" => "USDC",
            "chain" => "base",
            "amount" => "75"
          }
        })
        |> render_submit()

      assert html =~ ~s(id="policy-builder-simulator-changed-banner")
      assert has_element?(view, "#policy-builder-simulator-published-outcome")
      assert has_element?(view, "#policy-builder-simulator-draft-outcome")
    end

    test "missing required fields surface in the errors panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")

      html =
        view
        |> form("#policy-builder-simulator-form", %{
          "simulation" => %{
            "kind" => "transfer",
            "asset" => "",
            "chain" => "",
            "amount" => ""
          }
        })
        |> render_submit()

      assert html =~ ~s(id="policy-builder-simulator-errors")
      assert html =~ "is required"
    end

    test "running a simulation does not insert any AgentIntent / ExecutionPlan / DecisionEnvelope / audit row",
         %{conn: conn, workspace: ws, current_user: user} do
      _rule =
        Bank.Fixtures.policy_rule(
          rule_type: :amount_limit,
          state: :active,
          workspace_id: ws.id,
          params: %{"max_per_tx" => "100"}
        )

      {:ok, _view, _} = live(conn, "/policies/builder")
      view = elem(live(conn, "/policies/builder"), 1)

      intents_before = Bank.Repo.aggregate(Bank.Intents.AgentIntent, :count)
      plans_before = Bank.Repo.aggregate(Bank.Decisions.ExecutionPlan, :count)
      decisions_before = Bank.Repo.aggregate(Bank.Decisions.DecisionEnvelope, :count)
      audit_before = Bank.Repo.aggregate(Bank.Audit.AuditEvent, :count)
      _ = user

      view
      |> form("#policy-builder-simulator-form", %{
        "simulation" => %{
          "kind" => "transfer",
          "asset" => "USDC",
          "chain" => "base",
          "amount" => "10"
        }
      })
      |> render_submit()

      assert Bank.Repo.aggregate(Bank.Intents.AgentIntent, :count) == intents_before
      assert Bank.Repo.aggregate(Bank.Decisions.ExecutionPlan, :count) == plans_before
      assert Bank.Repo.aggregate(Bank.Decisions.DecisionEnvelope, :count) == decisions_before
      assert Bank.Repo.aggregate(Bank.Audit.AuditEvent, :count) == audit_before
    end
  end

  describe "policy simulator panel — non-admin (#225)" do
    setup :register_and_log_in_user

    test "operator sees a read-only placeholder (no form, no run button)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")

      refute has_element?(view, "#policy-builder-simulator-form")
      refute has_element?(view, "#policy-builder-simulator-run-btn")
      assert has_element?(view, "#policy-builder-simulator-readonly")
    end

    test "operator-attempted run_simulation shows admin-required flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/policies/builder")

      html =
        render_hook(view, "run_simulation", %{
          "simulation" => %{
            "kind" => "transfer",
            "asset" => "USDC",
            "chain" => "base",
            "amount" => "10"
          }
        })

      assert html =~ "Admin role required"
    end
  end

  # Avoid unused-alias warnings if `Policies` becomes unused after a
  # refactor to a context-only API.
  _ = {Policies}
end
