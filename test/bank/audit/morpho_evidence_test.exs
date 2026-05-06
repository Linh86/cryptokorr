defmodule Bank.Audit.MorphoEvidenceTest do
  @moduledoc """
  Audit / replay coverage for the Morpho deposit decision pipeline
  (#208).

  Pinned acceptance:

    * `morpho.risk_explained` lands on every Morpho decision (any
      outcome) and carries the structured explanation, snapshot
      reference, matched policy rule ids, and proposed amount.
    * `morpho.policy_blocked` lands when the evaluator routes to
      `:block` and carries the block-severity reason codes.
    * `morpho.snapshot_stale` lands when the snapshot has any
      `:stale` or `:expired` field; absent for fresh snapshots and
      for the missing-snapshot path.
    * Replay bundle's `morpho_evidence` slice surfaces the Morpho
      audit rows in `(ts, id)` order with `event_type`, subject,
      and `after_ref` fields.
    * Audit rows are workspace-scoped via passthrough
      `workspace_id` on every event.
    * Secret hygiene: explanation/evidence carries no provider
      Authorization headers, RPC URLs, raw GraphQL bodies, or
      private-key markers.
    * Event ordering inside one Morpho decision is deterministic:
      `morpho.risk_explained` → (optional) `morpho.snapshot_stale`
      → (optional) `morpho.policy_blocked` → `decision.decided` →
      (optional) `intent.state_changed`.
  """

  use Bank.DataCase, async: true

  alias Bank.Audit
  alias Bank.Audit.AuditEvent
  alias Bank.Decisions
  alias Bank.Fixtures
  import Ecto.Query

  @vault_address Fixtures.default_morpho_vault_address()
  @other_vault "0xdead000000000000000000000000000000000002"

  defp morpho_policy_rules(workspace_id, opts \\ []) do
    vault_addresses = Keyword.get(opts, :vault_addresses, [@vault_address])

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

  defp audit_events_for(intent_id) do
    Bank.Repo.all(
      from e in AuditEvent,
        where: e.correlation_id == ^intent_id,
        order_by: [asc: e.ts, asc: e.id]
    )
  end

  defp event_types_for(intent_id) do
    intent_id |> audit_events_for() |> Enum.map(& &1.event_type)
  end

  defp event_after_refs_by_type(intent_id) do
    intent_id
    |> audit_events_for()
    |> Map.new(fn e -> {e.event_type, e.after_ref} end)
  end

  describe "morpho.risk_explained" do
    test "fires on the happy approval path with snapshot + rule ids + amount" do
      intent = Fixtures.morpho_deposit_intent()
      snapshot = Fixtures.morpho_vault_snapshot()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, _} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      types = event_types_for(intent.id)
      assert "morpho.risk_explained" in types

      after_refs = event_after_refs_by_type(intent.id)
      ref = after_refs["morpho.risk_explained"]

      explanation = ref["morpho_risk_explanation"]
      assert explanation["kind"] == "morpho_vault_risk"
      assert explanation["vault_address"] == @vault_address
      assert explanation["decision"] == "approval_required"

      snap_ref = ref["snapshot"]
      assert snap_ref["id"] == snapshot.id
      assert snap_ref["chain_id"] == 84_532
      assert snap_ref["vault_address"] == @vault_address
      assert snap_ref["payload_hash"] == snapshot.payload_hash
      assert snap_ref["fetched_at"]
      assert snap_ref["source_name"] == "morpho_blue_graphql"
      assert snap_ref["source_schema_version"] == "1"

      assert Enum.sort(ref["policy_rule_ids"]) == Enum.sort(Enum.map(rules, & &1.id))
      assert ref["proposed_amount"] == "1000"
    end

    test "fires on missing-snapshot :hold path with snapshot=nil in after_ref" do
      intent = Fixtures.morpho_deposit_intent()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent, morpho_snapshot: nil, rules: rules)

      assert result.outcome == :hold

      after_refs = event_after_refs_by_type(intent.id)
      assert ref = after_refs["morpho.risk_explained"]
      assert ref["snapshot"] == nil
      assert ref["morpho_risk_explanation"]["decision"] == "hold"
    end

    test "stamps intent.workspace_id on the audit row" do
      intent = Fixtures.morpho_deposit_intent()
      snapshot = Fixtures.morpho_vault_snapshot()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, _} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      [event] =
        intent.id
        |> audit_events_for()
        |> Enum.filter(&(&1.event_type == "morpho.risk_explained"))

      assert event.workspace_id == intent.workspace_id
    end
  end

  describe "morpho.policy_blocked" do
    test "fires for an unknown vault → :block decision with block reason codes" do
      intent = Fixtures.morpho_deposit_intent(target_raw_address: @other_vault)
      snapshot = Fixtures.morpho_vault_snapshot(vault_address: @other_vault)
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      assert result.outcome == :block

      after_refs = event_after_refs_by_type(intent.id)
      assert ref = after_refs["morpho.policy_blocked"]

      assert ref["vault_address"] == @other_vault
      assert ref["chain_id"] == 84_532
      assert "vault_not_allowlisted" in ref["block_reason_codes"]
      assert is_binary(ref["summary"])
      assert is_list(ref["policy_rule_ids"])
    end

    test "does NOT fire on the happy approval path" do
      intent = Fixtures.morpho_deposit_intent()
      snapshot = Fixtures.morpho_vault_snapshot()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, _} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      refute "morpho.policy_blocked" in event_types_for(intent.id)
    end

    test "does NOT fire on a :hold (missing snapshot) decision" do
      intent = Fixtures.morpho_deposit_intent()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, result} =
               Decisions.evaluate_intent(intent, morpho_snapshot: nil, rules: rules)

      assert result.outcome == :hold
      refute "morpho.policy_blocked" in event_types_for(intent.id)
    end
  end

  describe "morpho.snapshot_stale" do
    test "fires when allocation TTL has expired (critical-data hold)" do
      intent = Fixtures.morpho_deposit_intent()
      now = DateTime.utc_now()
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

      after_refs = event_after_refs_by_type(intent.id)
      assert ref = after_refs["morpho.snapshot_stale"]

      assert ref["vault_address"] == snapshot.vault_address
      assert ref["chain_id"] == 84_532
      assert ref["fetched_at"]

      stale_fields = ref["stale_fields"]
      assert is_list(stale_fields)
      assert Enum.any?(stale_fields, &(&1["state"] in ["stale", "expired"]))
      # And subject_type points at the snapshot row, not the intent.
      [event] =
        intent.id
        |> audit_events_for()
        |> Enum.filter(&(&1.event_type == "morpho.snapshot_stale"))

      assert event.subject_type == "morpho_vault_snapshot"
      assert event.subject_id == snapshot.id
    end

    test "does NOT fire on a fresh snapshot" do
      intent = Fixtures.morpho_deposit_intent()
      snapshot = Fixtures.morpho_vault_snapshot()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, _} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      refute "morpho.snapshot_stale" in event_types_for(intent.id)
    end

    test "does NOT fire when there is no snapshot at all" do
      intent = Fixtures.morpho_deposit_intent()
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, _} =
               Decisions.evaluate_intent(intent, morpho_snapshot: nil, rules: rules)

      refute "morpho.snapshot_stale" in event_types_for(intent.id)
    end
  end

  describe "replay bundle morpho_evidence slice" do
    test "carries Morpho events in (ts, id) order with after_ref" do
      intent = Fixtures.morpho_deposit_intent(target_raw_address: @other_vault)
      snapshot = Fixtures.morpho_vault_snapshot(vault_address: @other_vault)
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, _} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      assert {:ok, bundle} = Audit.replay(intent.id)

      assert is_list(bundle.morpho_evidence)
      types = Enum.map(bundle.morpho_evidence, & &1.event_type)

      # An unknown-vault block emits both risk_explained and
      # policy_blocked, in that order (risk_explained always
      # first, policy_blocked appended on the block branch).
      assert types == ["morpho.risk_explained", "morpho.policy_blocked"]

      [risk, blocked] = bundle.morpho_evidence
      assert risk.subject_type == "agent_intent"
      assert risk.subject_id == intent.id
      assert risk.after_ref["morpho_risk_explanation"]["decision"] == "block"

      assert blocked.subject_type == "agent_intent"
      assert "vault_not_allowlisted" in blocked.after_ref["block_reason_codes"]
    end

    test "is empty for a transfer-path intent (no Morpho events expected)" do
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

      assert {:ok, _} =
               Decisions.evaluate_intent(intent, preview: {:ok, preview})

      assert {:ok, bundle} = Audit.replay(intent.id)
      assert bundle.morpho_evidence == []
    end
  end

  describe "event ordering" do
    test "morpho events precede decision.decided and intent.state_changed" do
      # Stale snapshot + unknown vault → emits risk_explained,
      # snapshot_stale, policy_blocked. Use fixed times so the
      # order is deterministic across runs.
      intent = Fixtures.morpho_deposit_intent(target_raw_address: @other_vault)
      now = DateTime.utc_now()
      stale_at = DateTime.add(now, -3600, :second)
      snapshot = Fixtures.morpho_vault_snapshot(vault_address: @other_vault, fetched_at: stale_at)
      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, _} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules,
                 now: now
               )

      types = event_types_for(intent.id)

      morpho_idx = Enum.find_index(types, &(&1 == "morpho.risk_explained"))
      stale_idx = Enum.find_index(types, &(&1 == "morpho.snapshot_stale"))
      block_idx = Enum.find_index(types, &(&1 == "morpho.policy_blocked"))
      decided_idx = Enum.find_index(types, &(&1 == "decision.decided"))
      state_idx = Enum.find_index(types, &(&1 == "intent.state_changed"))

      assert morpho_idx < stale_idx
      assert stale_idx < block_idx
      assert block_idx < decided_idx
      assert decided_idx < state_idx
    end
  end

  describe "secret hygiene" do
    test "no Authorization headers, RPC URLs, or private-key markers in any Morpho audit row" do
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

      assert {:ok, _} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      morpho_events =
        intent.id
        |> audit_events_for()
        |> Enum.filter(&morpho_event?/1)

      assert morpho_events != []

      blob = inspect(morpho_events)

      refute blob =~ "Authorization"
      refute blob =~ "Bearer "
      refute blob =~ "BEGIN PRIVATE KEY"
      refute blob =~ "rpc.example"
      refute blob =~ "private_key"
      # The redacted source map's known-public fields are fine; the
      # raw GraphQL body and tokenized URL must NOT leak in.
      refute blob =~ "blue-api.morpho.org/graphql?token="
    end

    test "snapshot reference does not embed source_warnings or any other source-map field beyond name + schema version" do
      intent = Fixtures.morpho_deposit_intent()

      snapshot =
        Fixtures.morpho_vault_snapshot(
          source: %{
            "fetched_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "source_name" => "morpho_blue_graphql",
            "source_schema_version" => "1",
            # If we ever leak source_warnings into the snapshot ref,
            # this canary string makes the regression obvious.
            "source_warnings" => [%{"raw_type" => "MUST_NOT_LEAK_INTO_AUDIT"}],
            "payload_hash" => "demo-hash"
          }
        )

      rules = morpho_policy_rules(intent.workspace_id)

      assert {:ok, _} =
               Decisions.evaluate_intent(intent,
                 morpho_snapshot: snapshot,
                 rules: rules
               )

      after_refs = event_after_refs_by_type(intent.id)
      snap_ref = after_refs["morpho.risk_explained"]["snapshot"]

      assert Map.keys(snap_ref) |> Enum.sort() ==
               ~w(chain_id fetched_at id payload_hash source_name source_schema_version vault_address)

      refute inspect(snap_ref) =~ "MUST_NOT_LEAK_INTO_AUDIT"
    end
  end

  defp morpho_event?(%{event_type: "morpho." <> _}), do: true
  defp morpho_event?(_), do: false
end
