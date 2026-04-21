defmodule Bank.WalletScreening.EvidenceTest do
  use Bank.DataCase, async: true

  alias Bank.Fixtures
  alias Bank.WalletScreening
  alias Bank.WalletScreening.Evidence

  defp insert_record!(attrs) do
    {:ok, record} = WalletScreening.upsert_record(attrs)
    record
  end

  @sanctions_addr "0xSanctionsEvidence001"
  @scam_addr "0xScamEvidence002"
  @context_addr "0xContextEvidence003"
  @clean_addr "0xCleanEvidence004"

  describe "for_address/3 — outcome semantics" do
    test "hard_block produces block outcome with provenance" do
      insert_record!(%{
        chain: "ethereum",
        address: @sanctions_addr,
        control_tier: :hard_block,
        source: "ofac",
        source_record_id: "sdn-ev-001",
        category: "sanctions",
        reason: "OFAC SDN: TEST ENTITY",
        evidence_uri: "https://ofac.test/001"
      })

      evidence = Evidence.for_address("ethereum", @sanctions_addr)

      assert evidence.outcome == "block"
      assert evidence.winning_tier == "hard_block"
      assert evidence.winning_source == "ofac"
      assert evidence.winning_reason =~ "OFAC"
      assert evidence.winning_evidence_uri =~ "ofac.test"
      assert evidence.total_records == 1
      assert length(evidence.records) == 1
    end

    test "challenge produces challenge outcome" do
      insert_record!(%{
        chain: "ethereum",
        address: @scam_addr,
        control_tier: :challenge,
        source: "scamsniffer",
        source_record_id: "ss-ev-001",
        category: "phishing",
        reason: "ScamSniffer: phishing"
      })

      evidence = Evidence.for_address("ethereum", @scam_addr)

      assert evidence.outcome == "challenge"
      assert evidence.winning_tier == "challenge"
      assert evidence.winning_source == "scamsniffer"
    end

    test "context-only produces clean outcome with context records" do
      insert_record!(%{
        chain: "ethereum",
        address: @context_addr,
        control_tier: :context,
        source: "graphsense",
        source_record_id: "gs-ev-001",
        category: "exchange",
        reason: "GraphSense: Binance"
      })

      evidence = Evidence.for_address("ethereum", @context_addr)

      assert evidence.outcome == "clean"
      assert evidence.winning_tier == "context"
      assert evidence.total_records == 1
      assert hd(evidence.records)["control_tier"] == "context"
    end

    test "score-only produces clean outcome with score data" do
      insert_record!(%{
        chain: "ethereum",
        address: "0xScoreEvidence005",
        control_tier: :score_only,
        source: "internal_scoring",
        source_record_id: "score-ev-001",
        category: "suspicious",
        reason: "Internal scoring: suspicious",
        score: Decimal.new("0.85"),
        score_version: "v2.1"
      })

      evidence = Evidence.for_address("ethereum", "0xScoreEvidence005")

      assert evidence.outcome == "clean"
      assert evidence.winning_tier == "score_only"
      assert hd(evidence.records)["score"] != nil
      assert hd(evidence.records)["score_version"] == "v2.1"
    end

    test "no records produces clean outcome" do
      evidence = Evidence.for_address("ethereum", @clean_addr)

      assert evidence.outcome == "clean"
      assert evidence.winning_tier == nil
      assert evidence.total_records == 0
      assert evidence.records == []
    end

    test "multiple tiers show all records with correct winning tier" do
      insert_record!(%{
        chain: "ethereum",
        address: @sanctions_addr,
        control_tier: :hard_block,
        source: "ofac",
        source_record_id: "sdn-ev-001",
        category: "sanctions",
        reason: "OFAC"
      })

      insert_record!(%{
        chain: "ethereum",
        address: @sanctions_addr,
        control_tier: :challenge,
        source: "scamsniffer",
        source_record_id: "ss-ev-002",
        category: "phishing",
        reason: "ScamSniffer"
      })

      evidence = Evidence.for_address("ethereum", @sanctions_addr)

      assert evidence.outcome == "block"
      assert evidence.winning_tier == "hard_block"
      assert evidence.total_records == 2
    end
  end

  describe "for_intent/2" do
    test "screens intent target raw address" do
      insert_record!(%{
        chain: "base",
        address: "0xIntentTarget001",
        control_tier: :challenge,
        source: "scamsniffer",
        source_record_id: "ss-intent-001",
        category: "phishing",
        reason: "ScamSniffer phishing"
      })

      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0xIntentTarget001",
          chain: "base"
        )

      evidence = Evidence.for_intent(intent)

      assert evidence.outcome == "challenge"
      assert evidence.screened_address == "0xIntentTarget001"
      assert evidence.screened_chain == "base"
    end

    test "screens intent target address label" do
      cp = Fixtures.counterparty()

      label =
        Fixtures.address_label(counterparty: cp, chain: "ethereum", address: "0xLabelAddr001")

      insert_record!(%{
        chain: "ethereum",
        address: "0xLabelAddr001",
        control_tier: :context,
        source: "graphsense",
        source_record_id: "gs-label-001",
        category: "exchange",
        reason: "GraphSense exchange"
      })

      intent =
        Fixtures.agent_intent(
          counterparty: cp,
          target_address_label_id: label.id,
          chain: "ethereum"
        )

      evidence = Evidence.for_intent(intent)

      assert evidence.outcome == "clean"
      assert evidence.total_records == 1
    end

    test "returns empty evidence when no target address resolvable" do
      intent = Fixtures.agent_intent()

      evidence = Evidence.for_intent(intent)

      assert evidence.outcome == "clean"
      assert evidence.screened_address == nil
    end
  end

  describe "feed_health inclusion" do
    test "evidence includes feed health for matched sources" do
      insert_record!(%{
        chain: "ethereum",
        address: @sanctions_addr,
        control_tier: :hard_block,
        source: "ofac",
        source_record_id: "sdn-health-001",
        category: "sanctions",
        reason: "OFAC"
      })

      evidence = Evidence.for_address("ethereum", @sanctions_addr)

      assert is_list(evidence.feed_health)
      assert Enum.any?(evidence.feed_health, &(&1["source"] == "ofac"))
    end
  end
end
