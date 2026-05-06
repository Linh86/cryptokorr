defmodule Bank.Decisions.MorphoDepositArtifactsTest do
  @moduledoc """
  Coverage for `Bank.Decisions.MorphoDepositArtifacts` (#206) — the
  pure transformer that builds the persisted/audited artifacts for
  an approved Morpho ERC-4626 deposit plan from the intent +
  decision envelope + current snapshot.

  No DB; no I/O; no validation. The transformer trusts that the
  plan-creator has already verified intent kind / chain / asset
  and that the snapshot is the current one.
  """

  use ExUnit.Case, async: true

  alias Bank.Decisions.{DecisionEnvelope, MorphoDepositArtifacts}
  alias Bank.DefiVenues.Morpho.PersistedVaultSnapshot
  alias Bank.Intents.AgentIntent

  defp build_intent do
    %AgentIntent{
      id: "11111111-1111-4111-8111-111111111111",
      kind: :defi_yield_deposit,
      chain: "base-sepolia",
      asset: "USDC",
      amount: Decimal.new("1000"),
      target_raw_address: "0xbeef000000000000000000000000000000000099",
      workspace_id: "22222222-2222-4222-8222-222222222222"
    }
  end

  defp build_envelope(intent_id) do
    %DecisionEnvelope{
      id: "33333333-3333-4333-8333-333333333333",
      intent_id: intent_id,
      outcome: :auto_exec,
      current: true,
      policy_snapshot_ref: %{
        "rule_ids" => ["44444444-4444-4444-8444-444444444444"]
      }
    }
  end

  defp build_snapshot do
    %PersistedVaultSnapshot{
      id: "55555555-5555-4555-8555-555555555555",
      chain_id: 84_532,
      vault_address: "0xbeef000000000000000000000000000000000099",
      payload_hash: "demo-hash",
      fetched_at: ~U[2026-05-06 06:00:00.000000Z]
    }
  end

  describe "from_intent/6" do
    test "packages chain/asset and persisted morpho_deposit steps from the intent + snapshot" do
      intent = build_intent()
      envelope = build_envelope(intent.id)
      snapshot = build_snapshot()
      sa = "sa_demo"
      rule_ids = ["44444444-4444-4444-8444-444444444444"]

      artifacts =
        MorphoDepositArtifacts.from_intent(intent, envelope, snapshot, sa, rule_ids, :user)

      assert artifacts.chain == "base-sepolia"
      assert artifacts.asset == "USDC"

      steps = artifacts.steps
      assert steps["kind"] == "morpho_deposit"
      assert steps["vault_address"] == "0xbeef000000000000000000000000000000000099"
      assert steps["chain_id"] == 84_532
      assert steps["asset"] == "USDC"
      assert steps["receiver"] == "sa_demo"
      assert steps["snapshot_id"] == snapshot.id
      assert steps["snapshot_payload_hash"] == "demo-hash"
      assert steps["snapshot_fetched_at"] == "2026-05-06T06:00:00.000000Z"
      assert steps["policy_rule_ids"] == rule_ids
      assert steps["decision_id"] == envelope.id
      assert steps["approval_actor"] == "user"
    end

    test "audit metadata carries vault address + snapshot identity" do
      intent = build_intent()
      envelope = build_envelope(intent.id)
      snapshot = build_snapshot()

      artifacts =
        MorphoDepositArtifacts.from_intent(intent, envelope, snapshot, "sa_a", [], :runtime)

      assert artifacts.audit_metadata == %{
               morpho_vault_address: "0xbeef000000000000000000000000000000000099",
               morpho_snapshot_id: snapshot.id,
               morpho_snapshot_payload_hash: "demo-hash"
             }
    end

    test "tolerates a nil snapshot (snapshot_id/hash are nil; the dispatch gate will fail closed)" do
      intent = build_intent()
      envelope = build_envelope(intent.id)

      artifacts =
        MorphoDepositArtifacts.from_intent(intent, envelope, nil, "sa_a", [], :runtime)

      assert artifacts.steps["snapshot_id"] == nil
      assert artifacts.steps["snapshot_payload_hash"] == nil
      assert artifacts.steps["snapshot_fetched_at"] == nil
      assert artifacts.audit_metadata.morpho_snapshot_id == nil
      assert artifacts.audit_metadata.morpho_snapshot_payload_hash == nil
    end

    test "approval_actor :runtime renders as the string 'runtime'" do
      intent = build_intent()
      envelope = build_envelope(intent.id)
      snapshot = build_snapshot()

      artifacts =
        MorphoDepositArtifacts.from_intent(intent, envelope, snapshot, "sa_a", [], :runtime)

      assert artifacts.steps["approval_actor"] == "runtime"
    end
  end
end
