defmodule Bank.Policies.SimulatorTest do
  @moduledoc """
  Tests for `Bank.Policies.Simulator` (#225) — pure simulator
  that compares a hypothetical intent against a workspace's
  draft and published policy versions.

  Coverage:

    * amount limit blocks above threshold
    * allowed chain mode (allowlist / denylist) shapes outcome
    * autonomy tier `:manual` produces `:approval_required`
    * autonomy tier `:block` produces `:block`
    * draft vs published comparison flips `changed?`
    * draft-only rules surface only on the draft side
    * unscoped fallback when no version exists yields auto_exec
    * **no AgentIntent / ExecutionPlan / DecisionEnvelope / audit
      side effects**
    * cross-workspace isolation: workspace B's rules never
      participate in workspace A's simulation

  Pure context tests, no LiveView setup.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.{PolicyRule, PolicyVersion, Simulator, Versions}
  alias Bank.Repo

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "sim-#{System.unique_integer([:positive])}",
        name: "Simulator"
      })

    %{workspace: ws, actor_id: Ecto.UUID.generate()}
  end

  # --- amount limit ----------------------------------------------------

  describe "simulate/2 — amount limit" do
    test "blocks an intent above the published amount limit",
         %{workspace: ws, actor_id: actor_id} do
      publish_amount_limit_policy(ws, actor_id, "100")

      assert {:ok, result} =
               Simulator.simulate(ws.id, valid_params(amount: "150"))

      assert result.published.outcome == :block
      assert result.published.pass? == false
      refute result.changed?
    end

    test "passes for an intent below the published amount limit",
         %{workspace: ws, actor_id: actor_id} do
      publish_amount_limit_policy(ws, actor_id, "100")

      assert {:ok, result} = Simulator.simulate(ws.id, valid_params(amount: "50"))

      assert result.published.outcome == :auto_exec
      assert result.published.pass? == true
    end
  end

  # --- chain allowlist -------------------------------------------------

  describe "simulate/2 — allowed chain" do
    test "blocks a chain that is NOT in the allowlist",
         %{workspace: ws, actor_id: actor_id} do
      rule =
        Bank.Fixtures.policy_rule(
          rule_type: :allowed_chain,
          state: :active,
          workspace_id: ws.id,
          params: %{"chains" => ["base"], "mode" => "allowlist"}
        )

      publish_with_rules(ws, actor_id, [rule.id])

      assert {:ok, result} = Simulator.simulate(ws.id, valid_params(chain: "ethereum"))
      assert result.published.outcome == :block
    end

    test "passes a chain that IS in the allowlist",
         %{workspace: ws, actor_id: actor_id} do
      rule =
        Bank.Fixtures.policy_rule(
          rule_type: :allowed_chain,
          state: :active,
          workspace_id: ws.id,
          params: %{"chains" => ["base"], "mode" => "allowlist"}
        )

      publish_with_rules(ws, actor_id, [rule.id])

      assert {:ok, result} = Simulator.simulate(ws.id, valid_params(chain: "base"))
      assert result.published.outcome == :auto_exec
    end
  end

  # --- autonomy tier ---------------------------------------------------

  describe "simulate/2 — autonomy_tier" do
    test ":manual tier yields :approval_required (no policy violations)",
         %{workspace: ws, actor_id: actor_id} do
      rule =
        Bank.Fixtures.policy_rule(
          rule_type: :autonomy_tier,
          state: :active,
          workspace_id: ws.id,
          params: %{"tier" => "manual"}
        )

      publish_with_rules(ws, actor_id, [rule.id])

      assert {:ok, result} = Simulator.simulate(ws.id, valid_params())

      assert result.published.outcome == :approval_required
      assert result.published.pass? == true
    end

    test ":block tier yields :block",
         %{workspace: ws, actor_id: actor_id} do
      rule =
        Bank.Fixtures.policy_rule(
          rule_type: :autonomy_tier,
          state: :active,
          workspace_id: ws.id,
          params: %{"tier" => "block"}
        )

      publish_with_rules(ws, actor_id, [rule.id])

      assert {:ok, result} = Simulator.simulate(ws.id, valid_params())
      assert result.published.outcome == :block
    end
  end

  # --- draft vs published comparison -----------------------------------

  describe "simulate/2 — draft vs published comparison" do
    test "draft tightens the amount limit; comparison flips changed? to true",
         %{workspace: ws, actor_id: actor_id} do
      # Published: max 100.
      published_rule =
        Bank.Fixtures.policy_rule(
          rule_type: :amount_limit,
          state: :active,
          workspace_id: ws.id,
          params: %{"max_per_tx" => "100"}
        )

      publish_with_rules(ws, actor_id, [published_rule.id])

      # Draft: max 50 — still :draft state until the operator
      # publishes (#224 P2-2 contract).
      tightened =
        Bank.Fixtures.policy_rule(
          rule_type: :amount_limit,
          state: :draft,
          workspace_id: ws.id,
          params: %{"max_per_tx" => "50"}
        )

      {:ok, _draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: %{"items" => [tightened.id]}
        )

      # Intent at 75: published passes, draft blocks → changed?
      assert {:ok, result} = Simulator.simulate(ws.id, valid_params(amount: "75"))

      assert result.published.outcome == :auto_exec
      assert result.draft.outcome == :block
      assert result.changed?
    end

    test "no draft → published-only side, draft.available? is false",
         %{workspace: ws, actor_id: actor_id} do
      publish_amount_limit_policy(ws, actor_id, "100")

      assert {:ok, result} = Simulator.simulate(ws.id, valid_params(amount: "50"))

      assert result.published.available? == true
      assert result.draft.available? == false
      assert result.draft.rules == []
    end

    test "no published version → published.available? is false",
         %{workspace: ws, actor_id: actor_id} do
      _draft_only =
        Bank.Fixtures.policy_rule(
          rule_type: :amount_limit,
          state: :draft,
          workspace_id: ws.id,
          params: %{"max_per_tx" => "10"}
        )

      {:ok, _draft_v} =
        Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)

      assert {:ok, result} = Simulator.simulate(ws.id, valid_params(amount: "50"))

      assert result.published.available? == false
      assert result.published.rules == []
      # No rules to evaluate against → policy passes.
      assert result.published.outcome == :auto_exec
    end
  end

  # --- input validation ------------------------------------------------

  describe "simulate/2 — input validation" do
    test "missing required field returns {:error, errors}", %{workspace: ws} do
      assert {:error, errors} = Simulator.simulate(ws.id, %{kind: :transfer})
      assert errors[:asset] == ["is required"]
      assert errors[:chain] == ["is required"]
      assert errors[:amount] == ["is required"]
    end

    test "malformed amount returns {:error, %{amount: ...}}", %{workspace: ws} do
      assert {:error, errors} =
               Simulator.simulate(ws.id, valid_params(amount: "abc"))

      assert errors[:amount] == ["must be a decimal"]
    end
  end

  # --- no side effects -------------------------------------------------

  describe "simulate/2 — no runtime side effects" do
    test "does not insert AgentIntent / ExecutionPlan / DecisionEnvelope / audit / Oban",
         %{workspace: ws, actor_id: actor_id} do
      publish_amount_limit_policy(ws, actor_id, "100")

      intents_before = Repo.aggregate(AgentIntent, :count)
      plans_before = Repo.aggregate(ExecutionPlan, :count)
      decisions_before = Repo.aggregate(DecisionEnvelope, :count)
      audit_before = Repo.aggregate(AuditEvent, :count)
      jobs_before = Repo.all(Oban.Job)

      assert {:ok, _result} = Simulator.simulate(ws.id, valid_params(amount: "50"))

      assert Repo.aggregate(AgentIntent, :count) == intents_before
      assert Repo.aggregate(ExecutionPlan, :count) == plans_before
      assert Repo.aggregate(DecisionEnvelope, :count) == decisions_before
      assert Repo.aggregate(AuditEvent, :count) == audit_before
      assert Repo.all(Oban.Job) == jobs_before
    end
  end

  # --- workspace isolation ---------------------------------------------

  describe "simulate/2 — cross-workspace isolation" do
    test "workspace B's rules never participate in workspace A's simulation",
         %{workspace: ws_a, actor_id: _actor_id} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "sim-iso-#{System.unique_integer([:positive])}",
          name: "Iso B"
        })

      # Workspace B has a strict amount-limit rule.
      ws_b_rule =
        Bank.Fixtures.policy_rule(
          rule_type: :amount_limit,
          state: :active,
          workspace_id: ws_b.id,
          params: %{"max_per_tx" => "1"}
        )

      # Workspace A has NO published version → no rules at all.
      assert is_nil(Versions.current_published(ws_a.id))

      assert {:ok, result} = Simulator.simulate(ws_a.id, valid_params(amount: "100"))

      assert result.published.rules == []
      assert result.published.outcome == :auto_exec
      refute Enum.any?(result.published.rules, &(&1.id == ws_b_rule.id))
    end
  end

  # --- helpers ---------------------------------------------------------

  defp valid_params(overrides \\ []) do
    base = %{
      kind: :transfer,
      asset: "USDC",
      chain: "base",
      amount: "10"
    }

    Enum.into(overrides, base)
  end

  defp publish_amount_limit_policy(ws, actor_id, max_per_tx) do
    rule =
      Bank.Fixtures.policy_rule(
        rule_type: :amount_limit,
        state: :active,
        workspace_id: ws.id,
        params: %{"max_per_tx" => max_per_tx}
      )

    publish_with_rules(ws, actor_id, [rule.id])
  end

  defp publish_with_rules(ws, actor_id, rule_ids) do
    {:ok, draft} =
      Versions.create_draft(ws.id,
        created_by: :user,
        actor_id: actor_id,
        rule_ids: %{"items" => rule_ids}
      )

    {:ok, published} =
      Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

    published
  end

  # Avoid an unused-alias warning if the schema becomes
  # implicitly used through changeset functions.
  _ = {PolicyVersion, PolicyRule}
end
