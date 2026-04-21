defmodule Bank.WalletScreening.Sources.InternalScoringTest do
  use ExUnit.Case, async: true

  alias Bank.WalletScreening.Sources.InternalScoring

  @high_score_entry %{
    "address" => "0xSuspiciousAddr001",
    "chain" => "ethereum",
    "score" => 0.92,
    "model_version" => "elliptic-v2.1",
    "features" => ["high_fan_in", "mixer_exposure", "rapid_consolidation"],
    "category" => "suspicious",
    "scored_at" => "2025-06-01T12:00:00Z"
  }

  @low_score_entry %{
    "address" => "0xLowRiskAddr002",
    "chain" => "ethereum",
    "score" => 0.15,
    "model_version" => "elliptic-v2.1",
    "category" => "low_risk"
  }

  @btc_score_entry %{
    "address" => "1BTCScoredAddr003",
    "chain" => "bitcoin",
    "score" => 0.78,
    "model_version" => "btc-cluster-v1.0",
    "features" => ["darknet_proximity"],
    "category" => "suspicious"
  }

  @missing_address %{
    "chain" => "ethereum",
    "score" => 0.5,
    "model_version" => "v1"
  }

  @missing_chain %{
    "address" => "0xAddr",
    "score" => 0.5,
    "model_version" => "v1"
  }

  @missing_score %{
    "address" => "0xAddr",
    "chain" => "ethereum",
    "model_version" => "v1"
  }

  @missing_model_version %{
    "address" => "0xAddr",
    "chain" => "ethereum",
    "score" => 0.5
  }

  @out_of_range_score %{
    "address" => "0xAddr",
    "chain" => "ethereum",
    "score" => 1.5,
    "model_version" => "v1"
  }

  describe "parse/1" do
    test "parses high-score entry with correct control_tier and provenance" do
      %{records: [record], skipped: []} = InternalScoring.parse([@high_score_entry])

      assert record.chain == "ethereum"
      assert record.address == "0xSuspiciousAddr001"
      assert record.control_tier == :score_only
      assert record.source == "internal_scoring"
      assert record.category == "suspicious"
      assert record.score != nil
      assert record.score_version == "elliptic-v2.1"
    end

    test "preserves score as Decimal" do
      %{records: [record], skipped: []} = InternalScoring.parse([@high_score_entry])

      assert %Decimal{} = record.score
      assert Decimal.compare(record.score, Decimal.from_float(0.9)) == :gt
    end

    test "preserves model version in score_version" do
      %{records: [record], skipped: []} = InternalScoring.parse([@high_score_entry])

      assert record.score_version == "elliptic-v2.1"
    end

    test "preserves features in metadata" do
      %{records: [record], skipped: []} = InternalScoring.parse([@high_score_entry])

      assert record.metadata["features"] == ["high_fan_in", "mixer_exposure", "rapid_consolidation"]
      assert record.metadata["model_version"] == "elliptic-v2.1"
      assert record.metadata["scored_at"] == "2025-06-01T12:00:00Z"
      assert record.metadata["raw_score"] == 0.92
    end

    test "preserves provenance in reason" do
      %{records: [record], skipped: []} = InternalScoring.parse([@high_score_entry])

      assert record.reason =~ "Internal scoring"
      assert record.reason =~ "suspicious"
      assert record.reason =~ "0.92"
      assert record.reason =~ "elliptic-v2.1"
    end

    test "handles BTC chain entries" do
      %{records: [record], skipped: []} = InternalScoring.parse([@btc_score_entry])

      assert record.chain == "bitcoin"
      assert record.control_tier == :score_only
      assert record.score_version == "btc-cluster-v1.0"
    end

    test "accepts low scores" do
      %{records: [record], skipped: []} = InternalScoring.parse([@low_score_entry])

      assert Decimal.compare(record.score, Decimal.from_float(0.2)) == :lt
      assert record.category == "low_risk"
    end

    test "skips entries with missing address" do
      %{records: [], skipped: [skipped]} = InternalScoring.parse([@missing_address])
      assert skipped.reason =~ "missing or empty address"
    end

    test "skips entries with missing chain" do
      %{records: [], skipped: [skipped]} = InternalScoring.parse([@missing_chain])
      assert skipped.reason =~ "missing chain"
    end

    test "skips entries with missing score" do
      %{records: [], skipped: [skipped]} = InternalScoring.parse([@missing_score])
      assert skipped.reason =~ "missing or invalid score"
    end

    test "skips entries with missing model_version" do
      %{records: [], skipped: [skipped]} = InternalScoring.parse([@missing_model_version])
      assert skipped.reason =~ "missing model_version"
    end

    test "skips entries with out-of-range score" do
      %{records: [], skipped: [skipped]} = InternalScoring.parse([@out_of_range_score])
      assert skipped.reason =~ "missing or invalid score"
    end

    test "all records have score_only tier" do
      entries = [@high_score_entry, @low_score_entry, @btc_score_entry]
      %{records: records, skipped: []} = InternalScoring.parse(entries)

      assert length(records) == 3
      assert Enum.all?(records, &(&1.control_tier == :score_only))
    end

    test "all records have internal_scoring source" do
      %{records: records, skipped: []} = InternalScoring.parse([@high_score_entry, @btc_score_entry])
      assert Enum.all?(records, &(&1.source == "internal_scoring"))
    end

    test "handles mixed valid and invalid entries" do
      entries = [@high_score_entry, @missing_address, @btc_score_entry, @out_of_range_score]
      %{records: records, skipped: skipped} = InternalScoring.parse(entries)

      assert length(records) == 2
      assert length(skipped) == 2
    end

    test "handles empty list" do
      assert %{records: [], skipped: []} = InternalScoring.parse([])
    end

    test "accepts string score" do
      entry = Map.put(@high_score_entry, "score", "0.75")
      %{records: [record], skipped: []} = InternalScoring.parse([entry])
      assert Decimal.compare(record.score, Decimal.from_float(0.7)) == :gt
    end
  end
end
