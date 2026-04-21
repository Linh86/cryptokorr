defmodule Bank.WalletScreening.ScoringIngestionTest do
  use Bank.DataCase, async: true

  alias Bank.WalletScreening
  alias Bank.WalletScreening.Ingestion

  @scoring_entries [
    %{
      "address" => "0xSuspiciousAddr001",
      "chain" => "ethereum",
      "score" => 0.92,
      "model_version" => "elliptic-v2.1",
      "features" => ["high_fan_in", "mixer_exposure"],
      "category" => "suspicious",
      "scored_at" => "2025-06-01T12:00:00Z"
    },
    %{
      "address" => "1BTCScoredAddr002",
      "chain" => "bitcoin",
      "score" => 0.65,
      "model_version" => "btc-cluster-v1.0",
      "features" => ["darknet_proximity"],
      "category" => "suspicious"
    }
  ]

  @invalid_entry %{
    "address" => "0xBadScore",
    "chain" => "ethereum",
    "score" => 2.0,
    "model_version" => "v1"
  }

  describe "ingest_scoring/1" do
    test "ingests scoring results as score_only records" do
      assert {:ok, result} = Ingestion.ingest_scoring(@scoring_entries)

      assert result.source == "internal_scoring"
      assert result.ingested == 2
      assert result.skipped == 0

      records = WalletScreening.list_records(%{source: "internal_scoring"})
      assert length(records) == 2
      assert Enum.all?(records, &(&1.control_tier == :score_only))
    end

    test "score_only records carry score and score_version" do
      {:ok, _} = Ingestion.ingest_scoring(@scoring_entries)

      records = WalletScreening.list_records(%{source: "internal_scoring"})

      assert Enum.all?(records, fn r ->
               r.score != nil and r.score_version != nil
             end)
    end

    test "score_only records produce :clean screening outcome (never block/challenge alone)" do
      {:ok, _} = Ingestion.ingest_scoring(@scoring_entries)

      result = WalletScreening.screen("ethereum", "0xSuspiciousAddr001")
      assert result.outcome == :clean
      assert length(result.score_records) == 1
      assert result.winning_record.control_tier == :score_only
    end

    test "upsert is idempotent" do
      {:ok, _} = Ingestion.ingest_scoring(@scoring_entries)
      {:ok, _} = Ingestion.ingest_scoring(@scoring_entries)

      records = WalletScreening.list_records(%{source: "internal_scoring"})
      assert length(records) == 2
    end

    test "upsert is idempotent across EVM checksum-case variants" do
      upper = %{
        "address" => "0xABCDEF0000000000000000000000000000000001",
        "chain" => "ethereum",
        "score" => 0.91,
        "model_version" => "elliptic-v2.1",
        "category" => "suspicious"
      }

      lower = Map.put(upper, "address", "0xabcdef0000000000000000000000000000000001")

      {:ok, _} = Ingestion.ingest_scoring([upper])
      {:ok, _} = Ingestion.ingest_scoring([lower])

      records =
        WalletScreening.list_records(%{
          source: "internal_scoring",
          chain: "ethereum",
          address: "0xabcdef0000000000000000000000000000000001"
        })

      assert length(records) == 1
      assert hd(records).address == "0xabcdef0000000000000000000000000000000001"
    end

    test "reports invalid entries in skipped" do
      entries = @scoring_entries ++ [@invalid_entry]
      {:ok, result} = Ingestion.ingest_scoring(entries)

      assert result.ingested == 2
      assert result.skipped == 1
    end

    test "preserves provenance for operator explanation" do
      {:ok, _} = Ingestion.ingest_scoring(@scoring_entries)

      result = WalletScreening.screen("ethereum", "0xSuspiciousAddr001")
      winning = result.winning_record

      assert winning.source == "internal_scoring"
      assert winning.score_version == "elliptic-v2.1"
      assert winning.reason =~ "Internal scoring"
      assert winning.reason =~ "0.92"
      assert winning.metadata["model_version"] == "elliptic-v2.1"
      assert winning.metadata["features"] == ["high_fan_in", "mixer_exposure"]
    end
  end

  describe "score_only precedence — never overrides higher tiers" do
    test "hard_block wins over score_only" do
      ofac_attrs = %{
        chain: "ethereum",
        address: "0xSuspiciousAddr001",
        control_tier: :hard_block,
        source: "ofac",
        source_record_id: "sdn-prec-001",
        category: "sanctions",
        reason: "OFAC sanctioned"
      }

      {:ok, _} = WalletScreening.upsert_record(ofac_attrs)
      {:ok, _} = Ingestion.ingest_scoring(@scoring_entries)

      result = WalletScreening.screen("ethereum", "0xSuspiciousAddr001")
      assert result.outcome == :block
      assert result.winning_record.control_tier == :hard_block
      assert length(result.all_records) == 2
      assert length(result.score_records) == 1
    end

    test "challenge wins over score_only" do
      scam_attrs = %{
        chain: "ethereum",
        address: "0xSuspiciousAddr001",
        control_tier: :challenge,
        source: "scamsniffer",
        source_record_id: "ss-prec-001",
        category: "phishing",
        reason: "known phishing"
      }

      {:ok, _} = WalletScreening.upsert_record(scam_attrs)
      {:ok, _} = Ingestion.ingest_scoring(@scoring_entries)

      result = WalletScreening.screen("ethereum", "0xSuspiciousAddr001")
      assert result.outcome == :challenge
      assert result.winning_record.control_tier == :challenge
      assert length(result.score_records) == 1
    end

    test "context wins over score_only in precedence order (both produce :clean)" do
      context_attrs = %{
        chain: "ethereum",
        address: "0xSuspiciousAddr001",
        control_tier: :context,
        source: "graphsense",
        source_record_id: "gs-prec-001",
        category: "exchange",
        reason: "Known exchange"
      }

      {:ok, _} = WalletScreening.upsert_record(context_attrs)
      {:ok, _} = Ingestion.ingest_scoring(@scoring_entries)

      result = WalletScreening.screen("ethereum", "0xSuspiciousAddr001")
      assert result.outcome == :clean
      assert result.winning_record.control_tier == :context
      assert length(result.context_records) == 1
      assert length(result.score_records) == 1
    end

    test "score_only alone never produces :block" do
      {:ok, _} = Ingestion.ingest_scoring(@scoring_entries)

      result = WalletScreening.screen("ethereum", "0xSuspiciousAddr001")
      refute result.outcome == :block
      refute result.outcome == :challenge
      assert result.outcome == :clean
    end

    test "multiple score_only records still produce :clean" do
      extra_score = %{
        "address" => "0xSuspiciousAddr001",
        "chain" => "ethereum",
        "score" => 0.99,
        "model_version" => "another-model-v3",
        "category" => "very_suspicious"
      }

      {:ok, _} = Ingestion.ingest_scoring(@scoring_entries ++ [extra_score])

      result = WalletScreening.screen("ethereum", "0xSuspiciousAddr001")
      assert result.outcome == :clean
      assert length(result.score_records) == 2
    end
  end
end
