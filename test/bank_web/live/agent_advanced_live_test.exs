defmodule BankWeb.AgentAdvancedLiveTest do
  @moduledoc """
  Tests for the Advanced screen's policy section (#agent-advanced):

    * the `policies` accordion renders REAL workspace rules
      (published version when one exists, active ruleset
      otherwise), not the legacy static stub;
    * a non-admin sees the data + a read-only message — no
      mutation buttons;
    * an admin can open a draft via `policy:open_draft`,
      discard it via `policy:discard_draft`, and publish it via
      `policy:publish_draft`, all gated behind the admin role;
    * draft edits never mutate the published policy (runtime
      stays on the prior published version until publish);
    * the diff classifier surfaces tightening vs expansion in
      the UI, and the `requires fresh permission install` banner
      shows up exactly when a draft is an expansion;
    * the permission-outdated banner fires when an expansion
      publish has landed since the active delegation's
      `granted_at`.

  We assert via `has_element?/2` + DOM ids so the test stays
  resilient to copy / layout changes — per AGENTS.md.
  """
  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bank.Delegations.Delegation
  alias Bank.Fixtures
  alias Bank.Policies.{PolicyRule, Versions}
  alias Bank.Repo
  alias Bank.SessionPermissions
  alias Bank.WalletBindings.WalletBinding

  # ── Section 1: anyone (operator-tier or higher) sees real rules ──

  describe "policies section — read-only render" do
    setup :register_and_log_in_user

    test "renders active ruleset when no PolicyVersion is published",
         %{conn: conn, workspace: ws} do
      _r1 =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100", "currency" => "USDC"},
          workspace_id: ws.id
        )

      _r2 =
        Fixtures.policy_rule(
          rule_type: :autonomy_tier,
          params: %{"tier" => "manual"},
          workspace_id: ws.id
        )

      {:ok, view, _html} = live(conn, "/advanced")

      assert has_element?(view, "#adv-policy")
      assert has_element?(view, "#adv-policy-source-active")
      assert has_element?(view, "#adv-policy-published-table")
      # Each active rule rendered with a stable id.
      assert has_element?(view, "#adv-policy-published-rule-#{_r1.id}")
      assert has_element?(view, "#adv-policy-published-rule-#{_r2.id}")

      # No draft yet → empty state.
      assert has_element?(view, "#adv-policy-draft-empty")
    end

    test "renders published version metadata when one exists",
         %{conn: conn, workspace: ws} do
      rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"},
          workspace_id: ws.id
        )

      {:ok, draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: Ecto.UUID.generate(),
          rule_ids: %{"items" => [rule.id]}
        )

      {:ok, _pub} =
        Versions.publish_draft(draft, published_by: :user, actor_id: Ecto.UUID.generate())

      {:ok, view, _html} = live(conn, "/advanced")

      assert has_element?(view, "#adv-policy-source-published")
      assert has_element?(view, "#adv-policy-published-rule-#{rule.id}")
      assert has_element?(view, "#adv-policy-draft-empty")
    end

    test "operator role does NOT see open/publish/discard buttons",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/advanced")

      assert has_element?(view, "#adv-policy-readonly")
      refute has_element?(view, "#adv-policy-open-draft-btn")
      refute has_element?(view, "#adv-policy-publish-btn")
      refute has_element?(view, "#adv-policy-discard-btn")
    end
  end

  # ── Section 2: admin can manage drafts ──

  describe "policies section — admin draft lifecycle" do
    setup :register_and_log_in_user_as_admin

    test "open_draft creates a draft + render flips to in-flight draft",
         %{conn: conn, workspace: ws} do
      _rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"},
          workspace_id: ws.id
        )

      {:ok, view, _html} = live(conn, "/advanced")

      assert has_element?(view, "#adv-policy-open-draft-btn")

      view |> element("#adv-policy-open-draft-btn") |> render_click()

      # New draft visible — no Process.sleep needed; the click is
      # synchronous and the rerender is immediate.
      assert has_element?(view, "#adv-policy-draft-state", "Draft v")
      assert has_element?(view, "#adv-policy-publish-btn")
      assert has_element?(view, "#adv-policy-discard-btn")
    end

    test "draft edit does NOT change the published rule set",
         %{conn: conn, workspace: ws} do
      published_rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"},
          workspace_id: ws.id
        )

      {:ok, draft0} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: Ecto.UUID.generate(),
          rule_ids: %{"items" => [published_rule.id]}
        )

      {:ok, _pub} =
        Versions.publish_draft(draft0, published_by: :user, actor_id: Ecto.UUID.generate())

      published_version_before = Versions.current_published(ws.id)

      {:ok, view, _html} = live(conn, "/advanced")

      view |> element("#adv-policy-open-draft-btn") |> render_click()

      # Open draft = clones the published rule_ids list, so the new
      # draft has the same rule id. Now tweak the draft list
      # directly through the Versions API (the LiveView delegates
      # full per-rule editing to the policy builder) and verify
      # the published version is still intact.
      [draft] = Versions.list_versions(ws.id, status: :draft, limit: 1)

      {:ok, _updated_draft} =
        Versions.update_draft_rule_ids(draft, %{"items" => []})

      published_version_after = Versions.current_published(ws.id)

      assert published_version_before.id == published_version_after.id

      # Runtime snapshot still resolves to the original rule.
      %{rules: live_rules} = Versions.snapshot_for_workspace(ws.id)
      assert Enum.map(live_rules, & &1.id) == [published_rule.id]
    end

    test "discard_draft removes the draft + flips render back to empty",
         %{conn: conn, workspace: ws} do
      _ =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"},
          workspace_id: ws.id
        )

      {:ok, view, _html} = live(conn, "/advanced")

      view |> element("#adv-policy-open-draft-btn") |> render_click()
      assert has_element?(view, "#adv-policy-discard-btn")

      view |> element("#adv-policy-discard-btn") |> render_click()

      assert has_element?(view, "#adv-policy-draft-empty")
      assert has_element?(view, "#adv-policy-open-draft-btn")
      # The draft row was deleted, not soft-archived.
      assert Versions.list_versions(ws.id, status: :draft) == []
    end

    test "tightening draft shows the no-reinstall info banner, NOT the expansion warn banner",
         %{conn: conn, workspace: ws} do
      big_rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "1000"},
          workspace_id: ws.id
        )

      # Publish a baseline with the loose rule.
      {:ok, draft0} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: Ecto.UUID.generate(),
          rule_ids: %{"items" => [big_rule.id]}
        )

      {:ok, _pub} =
        Versions.publish_draft(draft0, published_by: :user, actor_id: Ecto.UUID.generate())

      # Build a tighter draft.
      tight_rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"},
          state: :draft,
          workspace_id: ws.id
        )

      {:ok, _draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: Ecto.UUID.generate(),
          rule_ids: %{"items" => [tight_rule.id]}
        )

      {:ok, view, _html} = live(conn, "/advanced")

      assert has_element?(view, "#adv-policy-draft-tightening-info")
      refute has_element?(view, "#adv-policy-draft-expansion-warn")
    end

    test "expansion draft shows the expansion-warn banner + reinstall-required publish confirm",
         %{conn: conn, workspace: ws} do
      tight_rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"},
          workspace_id: ws.id
        )

      {:ok, draft0} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: Ecto.UUID.generate(),
          rule_ids: %{"items" => [tight_rule.id]}
        )

      {:ok, _pub} =
        Versions.publish_draft(draft0, published_by: :user, actor_id: Ecto.UUID.generate())

      # Build a draft that expands the cap.
      bigger_rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "10000"},
          state: :draft,
          workspace_id: ws.id
        )

      {:ok, _draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: Ecto.UUID.generate(),
          rule_ids: %{"items" => [bigger_rule.id]}
        )

      {:ok, view, _html} = live(conn, "/advanced")

      assert has_element?(view, "#adv-policy-draft-expansion-warn")
      refute has_element?(view, "#adv-policy-draft-tightening-info")

      # Publish button carries the reinstall-required confirm copy.
      html = render(view)
      assert html =~ ~r/Publishing will require a fresh permission install/
    end

    test "publish_draft promotes the draft + draft empty state returns",
         %{conn: conn, workspace: ws} do
      tight_rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "50"},
          state: :draft,
          workspace_id: ws.id
        )

      {:ok, _draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: Ecto.UUID.generate(),
          rule_ids: %{"items" => [tight_rule.id]}
        )

      {:ok, view, _html} = live(conn, "/advanced")

      view |> element("#adv-policy-publish-btn") |> render_click()

      # After publish: draft empty, new version visible.
      assert has_element?(view, "#adv-policy-draft-empty")
      assert has_element?(view, "#adv-policy-source-published")
      assert Versions.list_versions(ws.id, status: :draft) == []

      published = Versions.current_published(ws.id)
      assert published.version_number == 1
      assert Bank.Policies.PolicyVersion.rule_ids_list(published) == [tight_rule.id]

      # The promoted rule is now :active.
      assert Repo.get(PolicyRule, tight_rule.id).state == :active
    end
  end

  # ── Section 3: permission-outdated banner ──

  describe "permission outdated banner" do
    setup %{conn: _conn} = context do
      {:ok, ctx} = register_and_log_in_user_as_admin(context)
      Map.merge(context, Map.new(ctx))
    end

    test "no banner when no expansion publish landed since granted_at",
         %{conn: conn, workspace: ws, current_user: user} do
      _b = active_delegation_with_granted_at(ws.id, user.id, DateTime.utc_now())

      _r =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"},
          workspace_id: ws.id
        )

      {:ok, view, _html} = live(conn, "/advanced")

      refute has_element?(view, "#adv-policy-permission-outdated")
      refute has_element?(view, "#adv-top-permission-outdated")
    end

    test "banner appears after an expansion publish lands since granted_at",
         %{conn: conn, workspace: ws, current_user: user} do
      # Permission was installed 1 hour ago.
      granted_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      _b = active_delegation_with_granted_at(ws.id, user.id, granted_at)

      tight_rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"},
          workspace_id: ws.id
        )

      {:ok, d1} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: Ecto.UUID.generate(),
          rule_ids: %{"items" => [tight_rule.id]}
        )

      {:ok, _} = Versions.publish_draft(d1, published_by: :user, actor_id: Ecto.UUID.generate())

      # Expansion publish lands AFTER the permission's grant.
      bigger_rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "5000"},
          state: :draft,
          workspace_id: ws.id
        )

      {:ok, d2} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: Ecto.UUID.generate(),
          rule_ids: %{"items" => [bigger_rule.id]}
        )

      {:ok, _} = Versions.publish_draft(d2, published_by: :user, actor_id: Ecto.UUID.generate())

      {:ok, view, _html} = live(conn, "/advanced")

      assert has_element?(view, "#adv-policy-permission-outdated")
      assert has_element?(view, "#adv-top-permission-outdated")
    end

    # Legacy nil grant: an `:active` delegation with no install
    # timestamp + a published policy version. The runtime gate
    # (`Bank.Policies.workspace_permission_gate/1`) returns
    # `:legacy_nil_grant`, so the Advanced banner MUST mirror —
    # before this fix, the banner stayed silent while the runtime
    # blocked dispatch, leaving the operator with no UI signal.
    test "legacy nil granted_at + published version surfaces the outdated banner",
         %{conn: conn, workspace: ws, current_user: user} do
      delegation =
        active_delegation_with_granted_at(ws.id, user.id, DateTime.utc_now())

      delegation
      |> Ecto.Changeset.change(granted_at: nil)
      |> Bank.Repo.update!()

      # Publish any version so the legacy-nil-grant branch fires.
      actor_id = Ecto.UUID.generate()

      rule =
        Bank.Fixtures.policy_rule(
          workspace_id: ws.id,
          rule_type: :amount_limit,
          priority: 10,
          params: %{"max_per_tx" => "100"}
        )

      {:ok, draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: %{"items" => [rule.id]}
        )

      {:ok, _} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      assert Bank.Policies.workspace_permission_gate(ws.id) == :legacy_nil_grant

      {:ok, view, _html} = live(conn, "/advanced")

      assert has_element?(view, "#adv-policy-permission-outdated")
      assert has_element?(view, "#adv-top-permission-outdated")
    end

    test "legacy nil granted_at WITHOUT any published version stays silent",
         %{conn: conn, workspace: ws, current_user: user} do
      delegation =
        active_delegation_with_granted_at(ws.id, user.id, DateTime.utc_now())

      delegation
      |> Ecto.Changeset.change(granted_at: nil)
      |> Bank.Repo.update!()

      # Greenfield workspace: no policy version → :ok → banner silent.
      assert Bank.Policies.workspace_permission_gate(ws.id) == :ok

      {:ok, view, _html} = live(conn, "/advanced")

      refute has_element?(view, "#adv-policy-permission-outdated")
      refute has_element?(view, "#adv-top-permission-outdated")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp active_delegation_with_granted_at(workspace_id, user_id, granted_at) do
    nonce = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    addr = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    {:ok, binding} =
      Repo.insert(%WalletBinding{
        workspace_id: workspace_id,
        user_id: user_id,
        address: addr,
        chain_id: 84_532,
        nonce: nonce,
        challenge_message: "advanced test binding",
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
        verified_at: DateTime.utc_now()
      })

    sa_id = SessionPermissions.compute_smart_account_id(binding)

    attrs = %{
      smart_account_id: sa_id,
      delegation_id: "del-#{System.unique_integer([:positive])}",
      state: :active,
      chain: "base-sepolia",
      scope: SessionPermissions.Scope.default(),
      workspace_id: workspace_id,
      binding_id: binding.id,
      root_validator_owner: "user",
      install_userop_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      granted_at: granted_at
    }

    {:ok, delegation} =
      %Delegation{}
      |> Delegation.changeset(attrs)
      |> Repo.insert()

    delegation
  end
end
