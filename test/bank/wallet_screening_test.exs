defmodule Bank.WalletScreeningTest do
  use Bank.DataCase, async: true

  alias Bank.WalletScreening
  alias Bank.WalletScreening.{ScreeningOutcome, ScreeningRecord}

  defp insert_record!(attrs) do
    {:ok, record} = WalletScreening.upsert_record(attrs)
    record
  end

  @ofac_attrs %{
    chain: "base",
    address: "0xDeAdBeEf00000000000000000000000000000001",
    control_tier: :hard_block,
    source: "ofac",
    source_record_id: "sdn-001",
    category: "sanctions",
    reason: "OFAC SDN list entry",
    evidence_uri: "https://ofac.treasury.gov/sdn/001"
  }

  @scam_attrs %{
    chain: "base",
    address: "0xDeAdBeEf00000000000000000000000000000001",
    control_tier: :challenge,
    source: "scamsniffer",
    source_record_id: "ss-001",
    category: "phishing",
    reason: "known phishing address"
  }

  @context_attrs %{
    chain: "base",
    address: "0xDeAdBeEf00000000000000000000000000000001",
    control_tier: :context,
    source: "graphsense",
    source_record_id: "gs-tag-001",
    category: "exchange",
    reason: "Binance hot wallet"
  }

  describe "normalise_address/2" do
    test "lowercases EVM addresses" do
      assert WalletScreening.normalise_address("base", "0xAbCdEf") == "0xabcdef"
      assert WalletScreening.normalise_address("ethereum", "0xAbCdEf") == "0xabcdef"
      assert WalletScreening.normalise_address("Arbitrum", "0xAbCdEf") == "0xabcdef"
    end

    test "preserves case for non-EVM chains" do
      assert WalletScreening.normalise_address("bitcoin", "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa") ==
               "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
    end

    test "trims whitespace" do
      assert WalletScreening.normalise_address("base", "  0xAbC  ") == "0xabc"
    end
  end

  describe "upsert_record/1" do
    test "inserts a new screening record with address normalisation" do
      {:ok, record} = WalletScreening.upsert_record(@ofac_attrs)

      assert record.chain == "base"
      assert record.normalised_address == "0xdeadbeef00000000000000000000000000000001"
      assert record.control_tier == :hard_block
      assert record.source == "ofac"
    end

    test "upserts on conflict — updates existing record" do
      {:ok, first} = WalletScreening.upsert_record(@ofac_attrs)

      updated_attrs = Map.put(@ofac_attrs, :reason, "Updated SDN entry")
      {:ok, second} = WalletScreening.upsert_record(updated_attrs)

      assert second.id == first.id
      assert second.reason == "Updated SDN entry"
    end

    test "accepts string-key attributes from feed parsers" do
      string_attrs =
        @ofac_attrs
        |> Map.put(:chain, " Base ")
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      assert {:ok, record} = WalletScreening.upsert_record(string_attrs)

      assert record.chain == "base"
      assert record.normalised_address == "0xdeadbeef00000000000000000000000000000001"
      assert record.source == "ofac"
    end
  end

  describe "upsert_records/1" do
    test "batch inserts multiple records" do
      records = [
        @ofac_attrs,
        Map.merge(@ofac_attrs, %{source_record_id: "sdn-002", reason: "second entry"})
      ]

      assert {:ok, 2} = WalletScreening.upsert_records(records)
    end

    test "rolls back on invalid record" do
      records = [
        @ofac_attrs,
        %{chain: "base"}
      ]

      assert {:error, _} = WalletScreening.upsert_records(records)

      assert Repo.aggregate(ScreeningRecord, :count) == 0
    end
  end

  describe "screen/3" do
    test "returns :clean for unknown address" do
      result = WalletScreening.screen("base", "0x0000000000000000000000000000000000000000")

      assert %ScreeningOutcome{outcome: :clean} = result
      assert result.all_records == []
    end

    test "returns :block for sanctions hit" do
      insert_record!(@ofac_attrs)

      result =
        WalletScreening.screen(
          "base",
          "0xDeAdBeEf00000000000000000000000000000001"
        )

      assert result.outcome == :block
      assert result.winning_record.source == "ofac"
    end

    test "case-insensitive lookup for EVM chains" do
      insert_record!(@ofac_attrs)

      result =
        WalletScreening.screen(
          "base",
          "0xDEADBEEF00000000000000000000000000000001"
        )

      assert result.outcome == :block
    end

    test "hard_block takes precedence over challenge" do
      insert_record!(@ofac_attrs)
      insert_record!(@scam_attrs)

      result =
        WalletScreening.screen(
          "base",
          "0xDeAdBeEf00000000000000000000000000000001"
        )

      assert result.outcome == :block
      assert result.winning_record.control_tier == :hard_block
      assert length(result.all_records) == 2
    end

    test "challenge takes precedence over context" do
      insert_record!(@scam_attrs)
      insert_record!(@context_attrs)

      result =
        WalletScreening.screen(
          "base",
          "0xDeAdBeEf00000000000000000000000000000001"
        )

      assert result.outcome == :challenge
      assert length(result.context_records) == 1
    end

    test "context-only returns :clean with enrichment" do
      insert_record!(@context_attrs)

      result =
        WalletScreening.screen(
          "base",
          "0xDeAdBeEf00000000000000000000000000000001"
        )

      assert result.outcome == :clean
      assert length(result.context_records) == 1
      assert result.winning_record.control_tier == :context
    end

    test "excludes expired records by default" do
      expired_attrs =
        Map.put(@ofac_attrs, :expires_at, DateTime.add(DateTime.utc_now(), -3600, :second))

      insert_record!(expired_attrs)

      result =
        WalletScreening.screen(
          "base",
          "0xDeAdBeEf00000000000000000000000000000001"
        )

      assert result.outcome == :clean
    end

    test "uses the supplied clock for expiry filtering" do
      now = ~U[2026-04-21 12:00:00Z]
      expires_at = DateTime.add(now, 60, :second)

      insert_record!(Map.put(@ofac_attrs, :expires_at, expires_at))

      active =
        WalletScreening.screen(
          "base",
          "0xDeAdBeEf00000000000000000000000000000001",
          now: now
        )

      expired =
        WalletScreening.screen(
          "base",
          "0xDeAdBeEf00000000000000000000000000000001",
          now: DateTime.add(now, 120, :second)
        )

      assert active.outcome == :block
      assert expired.outcome == :clean
    end

    test "includes expired records when requested" do
      expired_attrs =
        Map.put(@ofac_attrs, :expires_at, DateTime.add(DateTime.utc_now(), -3600, :second))

      insert_record!(expired_attrs)

      result =
        WalletScreening.screen(
          "base",
          "0xDeAdBeEf00000000000000000000000000000001",
          include_expired: true
        )

      assert result.outcome == :block
    end

    test "does not match across chains" do
      insert_record!(@ofac_attrs)

      result =
        WalletScreening.screen(
          "ethereum",
          "0xDeAdBeEf00000000000000000000000000000001"
        )

      assert result.outcome == :clean
    end
  end

  describe "list_records/2" do
    test "lists records with filters" do
      insert_record!(@ofac_attrs)
      insert_record!(@scam_attrs)
      insert_record!(@context_attrs)

      all = WalletScreening.list_records()
      assert length(all) == 3

      sanctions_only = WalletScreening.list_records(%{control_tier: :hard_block})
      assert length(sanctions_only) == 1
      assert hd(sanctions_only).source == "ofac"

      by_source = WalletScreening.list_records(%{source: "scamsniffer"})
      assert length(by_source) == 1
    end
  end

  describe "delete_expired_records/2" do
    test "deletes records for a source older than cutoff" do
      insert_record!(@ofac_attrs)

      cutoff = DateTime.add(DateTime.utc_now(), 3600, :second)
      {count, _} = WalletScreening.delete_expired_records("ofac", cutoff)

      assert count == 1
      assert Repo.aggregate(ScreeningRecord, :count) == 0
    end

    test "does not delete records from other sources" do
      insert_record!(@ofac_attrs)
      insert_record!(@scam_attrs)

      cutoff = DateTime.add(DateTime.utc_now(), 3600, :second)
      {count, _} = WalletScreening.delete_expired_records("ofac", cutoff)

      assert count == 1
      assert Repo.aggregate(ScreeningRecord, :count) == 1
    end
  end
end
