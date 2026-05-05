defmodule Bank.Decisions.EvaluateIntentMorphoTest do
  @moduledoc """
  Decision-pipeline tests for the Morpho deposit slice (#203).

  Covers the issue's acceptance criteria:

    * valid Morpho deposit → `:approval_required` with attached
      `morpho_risk_explanation`;
    * unknown vault → `:block`;
    * stale critical snapshot → `:hold`;
    * Morpho warning maps into the explanation reasons/checks;
    * replay bundle carries the Morpho risk evidence;
    * no `ExecutionPlan` / `RunExecution` enqueued for Morpho;
    * existing transfer-path intents continue to evaluate;
    * cross-workspace policy rules cannot influence another
      workspace's Morpho decision;
    * explanation/evidence carries no raw provider secrets.

  All tests run pure-DB; the engine itself is a pure function on
  `(snapshot, policy_input, now)` and we never broadcast or hit
  the chain.
  """

  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit
  alias Bank.Decisions
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent

  @vault_address Fixtures.default_morpho_vault_address()
  @other_vault "0xdead000000000000000000000000000000000001"

  defp morpho_policy_rules(workspace_id, opts \\ []) do
    vault_addresses = Keyword.get(opts, :vault_addresses, [@vault_address])
    oracle = Keyword.get(opts, :oracle, "0xchainlinkoracle")
    collateral = Keyword.get(opts, :collateral, "0xwsteth")
    curator = Keyword.get(opts, :curator, "0xallocator1")

    [
      Fixtures.policy_rule(
        rule_type: :allowed_vault,
        params: %{
          "vaults" =>
            Enum.map(vault_addresses, fn addr ->
              %{"chain_id" => 84_532, "address" => addr}
            end)
        },
        scope: %{"venue" => "morpho"},
        workspace_id: workspace_id
      ),
      Fixtures.policy_rule(
        rule_type: :allowed_oracle,
        params: %{"oracles" => [oracle]},
        scope: %{"venue" => "morpho"},
        workspace_id: workspace_id
      ),
      Fixtures.policy_rule(
        rule_type: :allowed_collateral_asset,
        params: %{"assets" => [collateral]},
        scope: %{"venue" => "morpho"},
        workspace_id: workspace_id
      ),
      Fixtures.policy_rule(
        rule_type: :allowed_curator,
        params: %{"curators" => [curator]},
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

  defp explanation_from(%DecisionEnvelope{reasons: %{"items" => [item | _]}}) do
    get_in(item, ["details", "morpho_risk_explanation"])
  end

  describe "happy path: allowlisted vault + fresh snapshot" do
    test "returns :approval_required with morpho_risk_explanation in reasons" do
      intent = Fixtures.morpho_deposit_intent()
      snapshot = Fixtures.morpho_vault_snapshot()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      assert result.outcome == :approval_required
      assert result.decision.outcome == :approval_required
      assert result.decision.risk_tier in [:low, :moderate]
      assert result.decision.current
      assert result.decision.approval_expires_at
      # No trust/sim rows for the Morpho path.
      assert is_nil(result.trust)
      assert is_nil(result.simulation)

      explanation = explanation_from(result.decision)
      assert explanation["kind"] == "morpho_vault_risk"
      assert explanation["venue"] == "morpho"
      assert explanation["chain_id"] == 84_532
      assert explanation["vault_address"] == @vault_address
      assert explanation["decision"] == "approval_required"

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :decided
      assert reloaded.current_decision_id == result.decision.id
    end

    test "policy_snapshot_ref captures the matched Morpho rule ids" do
      intent = Fixtures.morpho_deposit_intent()
      snapshot = Fixtures.morpho_vault_snapshot()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      captured = result.decision.policy_snapshot_ref["rule_ids"]
      assert is_list(captured)
      assert Enum.sort(captured) == Enum.sort(Enum.map(rules, & &1.id))
    end
  end

  describe "unknown vault → :block" do
    test "vault address not on allowlist returns :block, no execution plan" do
      intent =
        Fixtures.morpho_deposit_intent(target_raw_address: @other_vault)

      snapshot = Fixtures.morpho_vault_snapshot(vault_address: @other_vault)
      # Allowlist names the *expected* vault, not the requested one,
      # so the engine should fail closed at :block.
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      assert result.outcome == :block
      assert result.decision.outcome == :block
      assert result.decision.risk_tier == :severe
      assert result.execution_plan == nil
      assert result.dispatch == :not_applicable

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :blocked

      assert Bank.Repo.aggregate(ExecutionPlan, :count, :id) == 0
    end
  end

  describe "stale critical snapshot → :hold" do
    test "snapshot whose allocation TTL has expired forces :hold" do
      intent = Fixtures.morpho_deposit_intent()
      now = DateTime.utc_now()
      # Allocation TTL defaults to 300s; expire it (use > 2× TTL so
      # the engine sees `:expired`, which is the critical-data
      # `:hold` branch).
      stale_at = DateTime.add(now, -3600, :second)
      snapshot = Fixtures.morpho_vault_snapshot(fetched_at: stale_at)
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules,
                 now: now
               )

      assert result.outcome == :hold
      assert result.decision.outcome == :hold

      explanation = explanation_from(result.decision)

      assert Enum.any?(explanation["primary_reasons"], fn r ->
               r["code"] in [
                 "freshness_allocation",
                 "freshness_warnings"
               ] and r["severity"] == "hold"
             end)
    end

    test "no persisted snapshot at all → :hold with snapshot_missing reason" do
      intent = Fixtures.morpho_deposit_intent()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: nil,
                 rules: rules
               )

      assert result.outcome == :hold
      explanation = explanation_from(result.decision)

      assert Enum.any?(explanation["primary_reasons"], fn r ->
               r["code"] == "snapshot_missing" and r["severity"] == "hold"
             end)
    end
  end

  describe "Morpho warning maps into reason/check" do
    test "RED-level warning produces a block-severity reason" do
      intent = Fixtures.morpho_deposit_intent()

      snapshot =
        Fixtures.morpho_vault_snapshot(
          warnings: [%{"raw_type" => "deposit_disabled", "raw_level" => "RED"}]
        )

      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      explanation = explanation_from(result.decision)

      assert Enum.any?(explanation["primary_reasons"], fn r ->
               r["code"] == "morpho_warning_deposit_disabled" and
                 r["severity"] == "block"
             end)

      # And a corresponding check entry.
      assert Enum.any?(explanation["checks"], fn c ->
               c["code"] == "morpho_warning_deposit_disabled"
             end)

      assert result.outcome == :block
    end
  end

  describe "replay surface" do
    test "replay bundle carries the Morpho risk explanation in the decision" do
      intent = Fixtures.morpho_deposit_intent()
      snapshot = Fixtures.morpho_vault_snapshot()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, _} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      assert {:ok, bundle} = Audit.replay(intent.id)

      assert [%DecisionEnvelope{} = envelope] = bundle.decisions
      explanation = explanation_from(envelope)

      assert explanation["kind"] == "morpho_vault_risk"
      assert explanation["vault_address"] == @vault_address
      assert is_list(explanation["primary_reasons"])
      assert is_list(explanation["checks"])

      # No trust/sim rows for the Morpho path; the bundle's lists
      # come back empty (replay readers handle that explicitly via
      # `Decisions.Report.from_bundle/1`).
      assert bundle.trust_assessments == []
      assert bundle.simulations == []
      assert bundle.plans == []
    end
  end

  describe "no execution dispatch" do
    test "no ExecutionPlan inserted, no RunExecution job enqueued" do
      intent = Fixtures.morpho_deposit_intent()
      snapshot = Fixtures.morpho_vault_snapshot()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      assert result.dispatch == :not_applicable
      assert result.execution_plan == nil

      assert Bank.Repo.aggregate(ExecutionPlan, :count, :id) == 0
      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
    end
  end

  describe "transfer-path regression" do
    test "kind: :transfer intents still evaluate through the transfer pipeline" do
      cp = Fixtures.counterparty()
      _label = Fixtures.address_label(counterparty: cp, chain: "base")

      _ =
        Fixtures.trust_assertion(
          subject: cp,
          level: :trusted,
          scope: %{}
        )

      intent =
        Fixtures.agent_intent(counterparty: cp, amount: Decimal.new("25"))

      preview = %Bank.Quotes.Preview{
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

      assert {:ok, result} =
               Decisions.evaluate_intent(intent, preview: {:ok, preview})

      # Transfer path produces real trust/sim rows; the morpho
      # explanation key is absent.
      assert result.trust
      assert result.simulation
      reasons = result.decision.reasons["items"] || []

      refute Enum.any?(reasons, fn item ->
               get_in(item, ["details", "morpho_risk_explanation"])
             end)
    end
  end

  describe "workspace boundary" do
    test "workspace B's allowlist cannot enable workspace A's Morpho decision" do
      # Workspace A: the intent's owning workspace. Has no Morpho
      # rules of its own.
      {:ok, workspace_a} =
        Bank.Workspaces.create_workspace(%{
          slug: "ws-a-#{System.unique_integer([:positive])}",
          name: "Workspace A"
        })

      # Workspace B: a foreign workspace whose Morpho allowlist
      # names the requested vault. If the evaluator leaked
      # cross-workspace, A's intent would see B's allowlist and
      # approve.
      {:ok, workspace_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "ws-b-#{System.unique_integer([:positive])}",
          name: "Foreign Workspace B"
        })

      _foreign_rules = morpho_policy_rules(workspace_b.id)

      intent =
        Fixtures.morpho_deposit_intent(workspace_id: workspace_a.id)

      snapshot = Fixtures.morpho_vault_snapshot()

      # No `:rules` opt — go through the real
      # `Policies.load_active_ruleset(workspace_id: A)` path.
      assert {:ok, result} =
               Decisions.evaluate_intent(intent, morpho_snapshot: snapshot)

      assert result.outcome == :block

      explanation = explanation_from(result.decision)

      assert Enum.any?(explanation["primary_reasons"], fn r ->
               r["code"] == "vault_not_allowlisted" and r["severity"] == "block"
             end)

      # And A's policy_snapshot_ref must be empty — no leak.
      assert result.decision.policy_snapshot_ref == %{"rule_ids" => []}
    end
  end

  describe "secret hygiene" do
    test "explanation does not echo Authorization headers, RPC URLs, or raw payloads" do
      intent = Fixtures.morpho_deposit_intent()

      snapshot =
        Fixtures.morpho_vault_snapshot(
          source: %{
            "fetched_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "source_name" => "morpho_blue_graphql",
            "source_schema_version" => "1",
            "source_warnings" => [],
            "payload_hash" => "demo-hash"
          }
        )

      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      blob = inspect(result.decision.reasons)

      refute blob =~ "Authorization"
      refute blob =~ "Bearer "
      refute blob =~ "BEGIN PRIVATE KEY"
      refute blob =~ "rpc.example"
      refute blob =~ "private_key"
    end
  end
end
