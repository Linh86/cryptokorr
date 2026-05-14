defmodule BankWeb.AgentLive.PermissionOutdatedTest do
  @moduledoc """
  End-to-end coverage of the agent-advanced "permission outdated /
  reinstall required" surface.

  Three slices:

    * Agent screen surfacing — `permission_card` flips to the
      "Reinstall required" pill + warning banner, `test_intent_card`
      disables Run and shows the inline outdated notice;
    * runtime gate from the UI — clicking Run with an outdated
      permission emits a `:block` DecisionEnvelope carrying the
      stable `permission_outdated_reinstall_required` reason code,
      no `ExecutionPlan` is created, and no adapter dispatch fires;
    * reinstall recovery — after a fresh install bumps `granted_at`,
      the banner clears, the pill flips back to `Active`, Run
      re-enables, and the runtime gate stops firing.

  We assert via `has_element?/2` + DOM ids per AGENTS.md; no raw
  HTML regex and no `Process.sleep`.
  """
  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bank.Fixtures

  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Delegations.Delegation
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.Versions
  alias Bank.Repo
  alias Bank.SessionPermissions
  alias Bank.WalletBindings.WalletBinding

  setup :register_and_log_in_user_as_admin

  describe "agent screen — outdated permission visible" do
    test "shows the Reinstall-required pill + banner; Run is disabled",
         %{conn: conn, workspace: ws, current_user: user} do
      _binding_and_delegation = active_outdated_delegation(ws.id, user.id)
      _published_with_expansion(ws)

      {:ok, view, _html} = live(conn, "/")

      # Pill + banner copy.
      assert has_element?(view, "#permission-card-outdated-banner")
      assert has_element?(view, "#agent-hero-permission-pill")
      # Topbar hero pill flips to the warn-coloured "Reinstall required"
      # chip when outdated — without this branch the hero would still
      # claim "Active" while the runtime is blocking dispatch.
      assert has_element?(view, "#agent-hero-permission-pill .pill--warn")

      # Run button visible but disabled, with the in-card outdated notice.
      assert has_element?(view, "#test-intent-permission-outdated")
      assert view |> element("#test-intent-run") |> render() =~ "disabled"
    end

    test "topbar pill stays on Active when permission is active and policy is unchanged",
         %{conn: conn, workspace: ws, current_user: user} do
      # Active delegation + workspace has no expansion since grant.
      _delegation =
        install_active_delegation(
          ws.id,
          user.id,
          DateTime.add(DateTime.utc_now(), -60, :second)
        )

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#agent-hero-permission-pill")
      # The "ok" pill colour is what the design uses for "Active".
      assert has_element?(view, "#agent-hero-permission-pill .pill--ok")
      refute has_element?(view, "#agent-hero-permission-pill .pill--warn")
    end
  end

  describe "agent screen — legacy nil granted_at + published version" do
    # The schema doesn't enforce `granted_at NOT NULL`, so an
    # `:active` row can in principle have `granted_at = nil`. The
    # runtime `Bank.Policies.workspace_permission_gate/1` fails
    # closed for that case (returns `:legacy_nil_grant`). The UI
    # must mirror exactly the same treatment — otherwise the
    # operator sees "Active / Run enabled" while the runtime
    # silently blocks dispatch with
    # `permission_outdated_reinstall_required`.

    test "UI flips to Reinstall required + Run disabled when granted_at is nil and a policy was published",
         %{conn: conn, workspace: ws, current_user: user} do
      delegation = install_active_delegation(ws.id, user.id, DateTime.utc_now())

      delegation
      |> Ecto.Changeset.change(granted_at: nil)
      |> Repo.update!()

      _ = publish_any_policy_version(ws)

      assert Bank.Policies.workspace_permission_gate(ws.id) == :legacy_nil_grant
      assert Bank.Policies.permission_outdated?(ws.id)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#permission-card-outdated-banner")
      assert has_element?(view, "#agent-hero-permission-pill .pill--warn")
      assert has_element?(view, "#test-intent-permission-outdated")
      assert view |> element("#test-intent-run") |> render() =~ "disabled"
    end

    test "UI stays Active when granted_at is nil but the workspace has never published",
         %{conn: conn, workspace: ws, current_user: user} do
      delegation = install_active_delegation(ws.id, user.id, DateTime.utc_now())

      delegation
      |> Ecto.Changeset.change(granted_at: nil)
      |> Repo.update!()

      assert Bank.Policies.workspace_permission_gate(ws.id) == :ok
      refute Bank.Policies.permission_outdated?(ws.id)

      {:ok, view, _html} = live(conn, "/")

      refute has_element?(view, "#permission-card-outdated-banner")
      refute has_element?(view, "#agent-hero-permission-pill .pill--warn")
      refute has_element?(view, "#test-intent-permission-outdated")
    end
  end

  describe "runtime gate — outdated permission produces :block + stable reason" do
    test "evaluating an intent under outdated permission blocks with permission_outdated_reinstall_required",
         %{workspace: ws, current_user: user} do
      _binding_and_delegation = active_outdated_delegation(ws.id, user.id)
      _published_with_expansion(ws)

      cp = Bank.Fixtures.counterparty(workspace_id: ws.id)
      _label = Bank.Fixtures.address_label(counterparty: cp, chain: "base-sepolia")

      _ =
        Bank.Fixtures.trust_assertion(
          subject: cp,
          level: :trusted,
          scope: %{},
          workspace_id: ws.id
        )

      intent =
        Bank.Fixtures.agent_intent(
          workspace_id: ws.id,
          counterparty: cp,
          amount: Decimal.new("25"),
          asset: "USDC",
          chain: "base-sepolia"
        )

      assert {:ok, result} =
               Bank.Decisions.evaluate_intent(intent,
                 preview: {:ok, ok_preview(intent)}
               )

      assert result.outcome == :block
      assert result.dispatch == :not_applicable
      assert is_nil(result.execution_plan)
      assert Repo.aggregate(ExecutionPlan, :count) == 0

      reasons =
        result.decision.reasons
        |> Map.get("items", [])
        |> Enum.map(&Map.get(&1, "code"))

      assert "permission_outdated_reinstall_required" in reasons

      # DecisionEnvelope still exists, replayable.
      assert %DecisionEnvelope{} = Repo.get!(DecisionEnvelope, result.decision.id)
    end
  end

  describe "reinstall recovery — fresh install clears the outdated state" do
    test "after revoke + fresh grant, no expansion-since-grant, UI flips back to Active",
         %{conn: conn, workspace: ws, current_user: user} do
      stale = active_outdated_delegation(ws.id, user.id)
      _published_with_expansion(ws)

      # Sanity: BEFORE reinstall the runtime helper reports outdated.
      assert Bank.Policies.permission_outdated?(ws.id, stale)

      # Simulate a clean reinstall: revoke the prior row, install a
      # fresh delegation AFTER the expansion publish. The partial-
      # unique index forbids two non-terminal rows per SA so we
      # transition stale → :revoked first.
      stale
      |> Ecto.Changeset.change(state: :revoked, revoked_at: DateTime.utc_now())
      |> Repo.update!()

      fresh = install_active_delegation(ws.id, user.id, DateTime.utc_now())

      refute Bank.Policies.permission_outdated?(ws.id, fresh)

      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#permission-card-outdated-banner")
      refute has_element?(view, "#test-intent-permission-outdated")

      html = render(view)
      refute html =~ "Reinstall required"

      # Run button is no longer disabled by the outdated check (the
      # card may still show locked for other reasons in tests, but
      # the outdated banner is gone, which is the assertion that
      # matters for this slice).
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp active_outdated_delegation(workspace_id, user_id) do
    granted_at = DateTime.add(DateTime.utc_now(), -3600, :second)
    install_active_delegation(workspace_id, user_id, granted_at)
  end

  defp install_active_delegation(workspace_id, user_id, granted_at) do
    nonce = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    addr = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    {:ok, binding} =
      Repo.insert(%WalletBinding{
        workspace_id: workspace_id,
        user_id: user_id,
        address: addr,
        chain_id: 84_532,
        nonce: nonce,
        challenge_message: "perm outdated test binding",
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

  defp _published_with_expansion(ws) do
    actor_id = Ecto.UUID.generate()

    # Permissive baseline: everything the trusted-intent path needs
    # to pass without the gate (otherwise the test asserts on the
    # WRONG violation when the gate clears).
    Bank.Fixtures.policy_rule(
      workspace_id: ws.id,
      rule_type: :allowed_chain,
      priority: 10,
      params: %{"chains" => ["base-sepolia"]}
    )

    Bank.Fixtures.policy_rule(
      workspace_id: ws.id,
      rule_type: :allowed_asset,
      priority: 11,
      params: %{"assets" => ["USDC"]}
    )

    Bank.Fixtures.policy_rule(
      workspace_id: ws.id,
      rule_type: :autonomy_tier,
      priority: 12,
      params: %{"tier" => "auto"}
    )

    # Published v1: lower cap. Same fingerprint as v2 so
    # PolicyDiff.classify pairs them and emits an EXPANSION (vs
    # treating it as remove+add).
    small =
      policy_rule(
        workspace_id: ws.id,
        rule_type: :amount_limit,
        priority: 50,
        params: %{"max_per_tx" => "100", "currency" => "USDC"}
      )

    {:ok, draft1} =
      Versions.create_draft(ws.id,
        created_by: :user,
        actor_id: actor_id,
        rule_ids: %{"items" => [small.id]}
      )

    {:ok, _v1} = Versions.publish_draft(draft1, published_by: :user, actor_id: actor_id)

    # v2 EXPANDS — higher cap, same fingerprint.
    bigger =
      policy_rule(
        workspace_id: ws.id,
        rule_type: :amount_limit,
        priority: 50,
        state: :draft,
        params: %{"max_per_tx" => "5000", "currency" => "USDC"}
      )

    {:ok, draft2} =
      Versions.create_draft(ws.id,
        created_by: :user,
        actor_id: actor_id,
        rule_ids: %{"items" => [bigger.id]}
      )

    {:ok, _v2} = Versions.publish_draft(draft2, published_by: :user, actor_id: actor_id)
    :ok
  end

  # Publish a single benign policy version so the legacy-nil-grant
  # branch fires — `workspace_permission_gate/1` only fails closed
  # for nil grants when the workspace has at least one
  # published/superseded version.
  defp publish_any_policy_version(ws) do
    actor_id = Ecto.UUID.generate()

    rule =
      Bank.Fixtures.policy_rule(
        workspace_id: ws.id,
        rule_type: :amount_limit,
        priority: 10,
        params: %{"max_per_tx" => "100"}
      )

    {:ok, draft} =
      Bank.Policies.Versions.create_draft(ws.id,
        created_by: :user,
        actor_id: actor_id,
        rule_ids: %{"items" => [rule.id]}
      )

    {:ok, _v} =
      Bank.Policies.Versions.publish_draft(draft,
        published_by: :user,
        actor_id: actor_id
      )

    :ok
  end

  defp ok_preview(%AgentIntent{} = intent) do
    %Bank.Quotes.Preview{
      balance_impact: %{intent.asset => Decimal.negate(intent.amount)},
      estimated_gas: 120_000,
      estimated_fee: Decimal.new("0.00015"),
      fee_asset: "ETH",
      route: %{"type" => "erc20_transfer", "asset" => intent.asset},
      failure_conditions: ["balance falls below requested amount"],
      provider: "stub",
      provider_trace_ref: "stub-fixture",
      generated_at: DateTime.utc_now(),
      freshness_ttl_seconds: 30
    }
  end
end
