defmodule Bank.Policies.PolicyBuilderSmokeTest do
  @moduledoc """
  Narrative smoke for `docs/runbooks/policy-builder.md` (#227).

  Walks the same sequence the runbook prescribes for a fresh
  reviewer:

    1. greenfield workspace — runtime sees no rules
    2. open a draft via `Bank.Policies.Versions.create_draft/2`
    3. add `:amount_limit`, `:allowed_chain`, `:autonomy_tier`
       rules at `state: :draft`
    4. wire the draft's `rule_ids` to reference them
    5. simulate before publish — draft tightens outcomes,
       runtime is still `nil` (draft never affects runtime)
    6. publish via `Bank.Policies.Versions.publish_draft/2`
    7. submit a real intent and assert the decision envelope's
       `policy_snapshot_ref` pins `rule_ids`,
       `policy_version_id`, and `policy_version_number`
    8. reload the decision row to confirm the pin is durable

  This file exists so the runbook has automated proof that a
  fresh reviewer's path produces a deterministic, replay-able
  decision. Per-step regressions on individual layers (the
  context, the simulator, the version surface) are pinned by
  `versions_test.exs`, `simulator_test.exs`, and
  `policies_test.exs`.
  """

  use Bank.DataCase, async: false

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Intents.AgentIntent
  alias Bank.Policies
  alias Bank.Policies.{PolicyRule, PolicyVersion, Simulator, Versions}
  alias Bank.Repo

  import Ecto.Query

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "policy-builder-smoke-#{System.unique_integer([:positive])}",
        name: "Policy builder smoke"
      })

    %{workspace: ws, actor_id: Ecto.UUID.generate()}
  end

  describe "runbook narrative — greenfield → draft → simulate → publish → evaluate" do
    test "fresh reviewer can configure a safe policy and the runtime pins the published version",
         %{workspace: ws, actor_id: actor_id} do
      # ---- step 1 — greenfield workspace --------------------------------
      assert is_nil(Versions.current_published(ws.id))
      assert is_nil(Versions.snapshot_for_workspace(ws.id))

      # ---- step 2 — open a draft ----------------------------------------
      assert {:ok, %PolicyVersion{status: :draft, version_number: 1} = draft} =
               Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)

      # Opening a draft must not affect the runtime.
      assert is_nil(Versions.snapshot_for_workspace(ws.id))

      # ---- step 3 — add three rules to the draft ------------------------
      {:ok, amount_rule} =
        Policies.create_rule(
          %{
            rule_type: :amount_limit,
            params: %{"max_per_tx" => "100"},
            state: :draft,
            created_by: :user
          },
          workspace_id: ws.id,
          actor: :user,
          actor_id: actor_id
        )

      {:ok, chain_rule} =
        Policies.create_rule(
          %{
            rule_type: :allowed_chain,
            params: %{"chains" => ["base"], "mode" => "allowlist"},
            state: :draft,
            created_by: :user
          },
          workspace_id: ws.id,
          actor: :user,
          actor_id: actor_id
        )

      {:ok, autonomy_rule} =
        Policies.create_rule(
          %{
            rule_type: :autonomy_tier,
            params: %{"tier" => "manual"},
            state: :draft,
            created_by: :user
          },
          workspace_id: ws.id,
          actor: :user,
          actor_id: actor_id
        )

      # All three rules are draft-only — the catalog must not
      # surface them as :active to the runtime yet.
      for rule <- [amount_rule, chain_rule, autonomy_rule] do
        assert rule.state == :draft
        assert rule.workspace_id == ws.id
      end

      # ---- step 4 — point the draft at the new rules --------------------
      ordered_rule_ids = [amount_rule.id, chain_rule.id, autonomy_rule.id]

      {:ok, draft} =
        Versions.update_draft_rule_ids(draft, %{"items" => ordered_rule_ids})

      assert PolicyVersion.rule_ids_list(draft) == ordered_rule_ids

      # ---- step 5a — simulate a small intent before publish -------------
      {:ok, small_result} =
        Simulator.simulate(ws.id, %{
          kind: :transfer,
          asset: "USDC",
          chain: "base",
          amount: "50"
        })

      assert small_result.draft.available?
      assert small_result.draft.outcome == :approval_required
      assert small_result.draft.pass? == true
      assert autonomy_rule.id in small_result.draft.matched_rule_ids

      # No published version → simulator shows the runtime would
      # auto-exec because no rules apply.
      refute small_result.published.available?
      assert small_result.published.outcome == :auto_exec

      # `changed?` is only `true` when BOTH sides have a version.
      # The contract — confirmed in simulator_test.exs — is that
      # the absence of a published version surfaces through
      # `published.available? == false`, not the diff banner.
      refute small_result.changed?

      # ---- step 5b — simulate an above-limit, off-chain intent ----------
      {:ok, blocked_result} =
        Simulator.simulate(ws.id, %{
          kind: :transfer,
          asset: "USDC",
          chain: "ethereum",
          amount: "150"
        })

      assert blocked_result.draft.outcome == :block
      assert blocked_result.draft.pass? == false

      blocked_codes =
        blocked_result.draft.violations |> Enum.map(& &1.code) |> Enum.sort()

      assert "amount_above_limit" in blocked_codes
      assert "chain_not_allowed" in blocked_codes

      # ---- step 5c — runtime contract: draft never touches runtime ------
      # `Bank.Policies.Versions.snapshot_for_workspace/1` is the
      # exact function `Bank.Decisions.evaluate_policy/3` calls.
      # Returning `nil` here is the proof that an unpublished
      # draft is invisible to live decisions.
      assert is_nil(Versions.snapshot_for_workspace(ws.id))

      # ---- step 6 — publish the draft -----------------------------------
      audit_before = Repo.aggregate(AuditEvent, :count)

      assert {:ok, %PolicyVersion{status: :published} = published} =
               Versions.publish_draft(draft,
                 published_by: :user,
                 actor_id: actor_id
               )

      assert published.id == draft.id
      assert published.version_number == 1
      assert published.published_by == :user
      assert PolicyVersion.rule_ids_list(published) == ordered_rule_ids

      # All three draft rules are now :active.
      for id <- ordered_rule_ids do
        rule = Repo.get!(PolicyRule, id)
        assert rule.state == :active
      end

      # `policy.version.published` audit event was emitted.
      assert Repo.aggregate(AuditEvent, :count) == audit_before + 1

      assert Repo.exists?(
               from a in AuditEvent,
                 where:
                   a.event_type == ^"policy.version.published" and
                     a.workspace_id == ^ws.id
             )

      # ---- step 7a — runtime now sees the published rule list -----------
      snapshot = Versions.snapshot_for_workspace(ws.id)

      assert snapshot.version_id == published.id
      assert snapshot.version_number == published.version_number
      assert snapshot.rule_ids_in_version == ordered_rule_ids

      # The resolved active rule list matches what we published.
      resolved_ids = snapshot.rules |> Enum.map(& &1.id) |> Enum.sort()
      assert resolved_ids == Enum.sort(ordered_rule_ids)

      # ---- step 7b — submit a real intent and evaluate ------------------
      cp = Bank.Fixtures.counterparty(workspace_id: ws.id)

      _ =
        Bank.Fixtures.address_label(
          counterparty: cp,
          chain: "base"
        )

      _ =
        Bank.Fixtures.trust_assertion(
          subject: cp,
          level: :trusted,
          scope: %{}
        )

      intent =
        Bank.Fixtures.agent_intent(
          counterparty: cp,
          workspace_id: ws.id,
          asset: "USDC",
          chain: "base",
          amount: Decimal.new("50")
        )

      preview = preview_for(intent)

      # `paused?: false` keeps the assertion deterministic against
      # `Bank.Security.PauseState`'s process-global state across
      # CI runs (mirrors versions_test.exs).
      assert {:ok, result} =
               Bank.Decisions.evaluate_intent(intent,
                 preview: {:ok, preview},
                 paused?: false
               )

      # ---- step 8 — assert the snapshot ref pins the version -----------
      ref = result.decision.policy_snapshot_ref

      assert ref["policy_version_id"] == published.id
      assert ref["policy_version_number"] == published.version_number
      assert is_list(ref["rule_ids"])
      assert Enum.sort(ref["rule_ids"]) == Enum.sort(ordered_rule_ids)

      # The decision outcome reflects the published policy: a $50
      # USDC `base` transfer passes amount + chain rules but the
      # `:autonomy_tier => :manual` rule routes it to
      # `approval_required`. No `auto_exec` dispatch happens, so
      # no `ExecutionPlan` is created.
      assert result.decision.outcome == :approval_required
      assert Repo.aggregate(ExecutionPlan, :count, :id) == 0

      # ---- pin durability — reload the row from disk -------------------
      reloaded = Repo.get!(DecisionEnvelope, result.decision.id)
      assert reloaded.policy_snapshot_ref == ref

      # Sanity: the reloaded `rule_ids` resolve to live PolicyRule
      # rows in the same workspace — the catalog's append-only
      # contract gives us this for free.
      reload_ids = reloaded.policy_snapshot_ref["rule_ids"]

      live_rule_count =
        Repo.aggregate(
          from(r in PolicyRule,
            where: r.id in ^reload_ids and r.workspace_id == ^ws.id
          ),
          :count,
          :id
        )

      assert live_rule_count == length(reload_ids)
    end

    test "no draft → workspace cannot publish; runtime continues to see nothing",
         %{workspace: ws, actor_id: _actor_id} do
      # Defensive companion to the happy path: a fresh reviewer
      # without a draft cannot accidentally promote anything.
      assert Versions.list_versions(ws.id, status: :draft) == []
      assert is_nil(Versions.current_published(ws.id))
      assert is_nil(Versions.snapshot_for_workspace(ws.id))

      # Greenfield workspace's intent count is also 0 (no smoke
      # writes leak into other tables).
      assert Repo.aggregate(AgentIntent, :count, :id) == 0
    end
  end

  # --- preview helper --------------------------------------------------

  defp preview_for(intent) do
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
