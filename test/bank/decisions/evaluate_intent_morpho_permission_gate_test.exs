defmodule Bank.Decisions.EvaluateIntentMorphoPermissionGateTest do
  @moduledoc """
  Verifies the agent-advanced permission-outdated gate fires on
  the Morpho/Earn pipeline (`Bank.Decisions.MorphoEvaluator`), not
  just the transfer pipeline.

  The Morpho path never auto-execs on its own; the worst-case
  user dispatch is `evaluate -> :approval_required ->
  Bank.Decisions.approve/2 -> create_execution_plan`. Without the
  gate the operator could silently expand the agent's on-chain
  authority by approving a stale-permission Morpho deposit. With
  the gate, the FIRST evaluation collapses the outcome to `:block`
  with the stable `permission_outdated_reinstall_required`
  reason, so approve never sees an `:approval_required` envelope
  to operate on.
  """
  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Decisions
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Fixtures
  alias Bank.Policies.Versions
  alias Bank.Repo

  @vault_address Fixtures.default_morpho_vault_address()

  defp fresh_workspace do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "morpho-gate-#{suffix}",
        name: "Morpho gate workspace #{suffix}",
        mainnet_enabled: true
      })

    ws
  end

  defp morpho_policy_rules(workspace_id) do
    [
      Fixtures.policy_rule(
        rule_type: :allowed_vault,
        params: %{
          "vaults" => [%{"chain_id" => 84_532, "address" => @vault_address}]
        },
        scope: %{"venue" => "morpho"},
        workspace_id: workspace_id
      ),
      Fixtures.policy_rule(
        rule_type: :allowed_oracle,
        params: %{"oracles" => ["0xchainlinkoracle"]},
        scope: %{"venue" => "morpho"},
        workspace_id: workspace_id
      ),
      Fixtures.policy_rule(
        rule_type: :allowed_collateral_asset,
        params: %{"assets" => ["0xwsteth"]},
        scope: %{"venue" => "morpho"},
        workspace_id: workspace_id
      ),
      Fixtures.policy_rule(
        rule_type: :allowed_curator,
        params: %{"curators" => ["0xallocator1"]},
        scope: %{"venue" => "morpho"},
        workspace_id: workspace_id
      ),
      Fixtures.policy_rule(
        rule_type: :max_vault_exposure,
        params: %{"max_amount" => "1000000"},
        scope: %{"venue" => "morpho"},
        workspace_id: workspace_id
      )
    ]
  end

  defp publish_then_expand(ws) do
    actor_id = Ecto.UUID.generate()

    small =
      Fixtures.policy_rule(
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

    bigger =
      Fixtures.policy_rule(
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

  defp install_delegation(ws, granted_at) do
    sa = "sa-morpho-perm-#{System.unique_integer([:positive])}"
    {:ok, del} = Bank.Delegations.grant(sa, "del-#{sa}", %{workspace_id: ws.id})

    del
    |> Ecto.Changeset.change(granted_at: granted_at)
    |> Repo.update!()
  end

  describe "Morpho evaluator — permission outdated" do
    test "expansion publish after grant collapses Morpho :approval_required to :block" do
      ws = fresh_workspace()
      intent = Fixtures.morpho_deposit_intent(workspace_id: ws.id)
      snapshot = Fixtures.morpho_vault_snapshot()

      _delegation =
        install_delegation(ws, DateTime.add(DateTime.utc_now(), -3600, :second))

      publish_then_expand(ws)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: morpho_policy_rules(intent.workspace_id)
               )

      # Without the gate this would be `:approval_required` (the
      # Morpho engine's MVP fallback). With the gate, the outcome
      # collapses to `:block` and the stable reason is at the
      # head of `reasons.items` so consumers reading `items[0].code`
      # see it.
      assert result.outcome == :block
      assert result.decision.outcome == :block
      assert is_nil(result.execution_plan)

      [first | _] = result.decision.reasons["items"]
      assert first["code"] == "permission_outdated_reinstall_required"

      # The Morpho explanation is preserved as the SECOND item so
      # replay still surfaces the underlying risk story.
      [_first, morpho | _] = result.decision.reasons["items"]
      assert morpho["code"] == "morpho_risk_explanation"

      # DecisionEnvelope persists. ExecutionPlan does not.
      assert %DecisionEnvelope{outcome: :block} =
               Repo.get!(DecisionEnvelope, result.decision.id)

      assert Repo.aggregate(ExecutionPlan, :count) == 0

      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
    end

    test "fresh install after expansion clears the Morpho gate" do
      ws = fresh_workspace()
      intent = Fixtures.morpho_deposit_intent(workspace_id: ws.id)
      snapshot = Fixtures.morpho_vault_snapshot()

      publish_then_expand(ws)

      _fresh =
        install_delegation(ws, DateTime.add(DateTime.utc_now(), 60, :second))

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: morpho_policy_rules(intent.workspace_id)
               )

      # Gate cleared: outcome reverts to the engine's natural
      # `:approval_required` (Morpho MVP never auto-execs).
      assert result.outcome == :approval_required

      reasons = Enum.map(result.decision.reasons["items"], & &1["code"])
      refute "permission_outdated_reinstall_required" in reasons
    end

    test "legacy :active delegation with nil granted_at fails closed when a published version exists" do
      ws = fresh_workspace()
      intent = Fixtures.morpho_deposit_intent(workspace_id: ws.id)
      snapshot = Fixtures.morpho_vault_snapshot()

      # Active delegation with no install timestamp — legacy
      # row predating the `granted_at` column.
      delegation = install_delegation(ws, DateTime.utc_now())

      delegation
      |> Ecto.Changeset.change(granted_at: nil)
      |> Repo.update!()

      # Workspace has a published policy version (any publish
      # tracks the gate; expansion not required for the legacy
      # branch — see `Bank.Policies.workspace_permission_gate/1`).
      actor_id = Ecto.UUID.generate()

      rule =
        Fixtures.policy_rule(
          workspace_id: ws.id,
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"}
        )

      {:ok, draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: %{"items" => [rule.id]}
        )

      {:ok, _v} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: morpho_policy_rules(intent.workspace_id)
               )

      assert result.outcome == :block

      [first | _] = result.decision.reasons["items"]
      assert first["code"] == "permission_outdated_reinstall_required"
      assert first["details"]["reason"] == "legacy_nil_grant"
    end
  end

  describe "skip_outdated_permission_gate? escape hatch" do
    test "explicit opt bypasses the Morpho gate (replay/simulator only)" do
      ws = fresh_workspace()
      intent = Fixtures.morpho_deposit_intent(workspace_id: ws.id)
      snapshot = Fixtures.morpho_vault_snapshot()

      _delegation =
        install_delegation(ws, DateTime.add(DateTime.utc_now(), -3600, :second))

      publish_then_expand(ws)

      assert {:ok, result} =
               Bank.Decisions.MorphoEvaluator.evaluate(intent,
                 morpho_snapshot: snapshot,
                 rules: morpho_policy_rules(intent.workspace_id),
                 skip_outdated_permission_gate?: true
               )

      # Skip respected — outcome is the engine's natural reply.
      assert result.outcome in [:approval_required, :block, :hold]

      reasons = Enum.map(result.decision.reasons["items"], & &1["code"])
      refute "permission_outdated_reinstall_required" in reasons
    end
  end
end
