defmodule Bank.WalletScreening.Sources.OFACTest do
  use ExUnit.Case, async: true

  alias Bank.WalletScreening.Sources.OFAC

  @eth_entry %{
    "id" => 42001,
    "id_type" => "Digital Currency Address - ETH",
    "id_number" => "0xDeAdBeEf00000000000000000000000000000001",
    "name" => "LAZARUS GROUP",
    "programs" => ["DPRK3", "CYBER2"]
  }

  @btc_entry %{
    "id" => 42002,
    "id_type" => "Digital Currency Address - XBT",
    "id_number" => "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
    "name" => "SUEX OTC",
    "programs" => ["CYBER2"]
  }

  @usdt_entry %{
    "id" => 42003,
    "id_type" => "Digital Currency Address - USDT",
    "id_number" => "0xABCDEF1234567890abcdef1234567890ABCDEF12",
    "name" => "TORNADO CASH",
    "programs" => ["SDGT"]
  }

  @non_crypto_entry %{
    "id" => 50001,
    "id_type" => "Passport",
    "id_number" => "AB1234567",
    "name" => "SOME PERSON"
  }

  @unsupported_ticker_entry %{
    "id" => 42099,
    "id_type" => "Digital Currency Address - DOGE",
    "id_number" => "DNoAddressHere",
    "name" => "UNKNOWN ENTITY"
  }

  @missing_address_entry %{
    "id" => 42100,
    "id_type" => "Digital Currency Address - ETH",
    "id_number" => nil,
    "name" => "BAD ENTRY"
  }

  describe "extract_digital_currency_entries/1" do
    test "filters to digital currency entries only" do
      entries = [@eth_entry, @non_crypto_entry, @btc_entry]

      result = OFAC.extract_digital_currency_entries(entries)

      assert length(result) == 2
      assert Enum.all?(result, &String.contains?(&1["id_type"], "Digital Currency Address"))
    end

    test "returns empty for non-crypto entries" do
      assert OFAC.extract_digital_currency_entries([@non_crypto_entry]) == []
    end
  end

  describe "parse/1" do
    test "parses ETH entry with correct chain and control_tier" do
      %{records: [record], skipped: []} = OFAC.parse([@eth_entry])

      assert record.chain == "ethereum"
      assert record.address == "0xDeAdBeEf00000000000000000000000000000001"
      assert record.control_tier == :hard_block
      assert record.source == "ofac"
      assert record.source_record_id == "sdn-42001"
      assert record.category == "sanctions"
    end

    test "parses BTC entry with bitcoin chain" do
      %{records: [record], skipped: []} = OFAC.parse([@btc_entry])

      assert record.chain == "bitcoin"
      assert record.address == "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
    end

    test "parses USDT entry with ethereum chain" do
      %{records: [record], skipped: []} = OFAC.parse([@usdt_entry])

      assert record.chain == "ethereum"
    end

    test "preserves provenance in reason and evidence_uri" do
      %{records: [record], skipped: []} = OFAC.parse([@eth_entry])

      assert record.reason =~ "LAZARUS GROUP"
      assert record.reason =~ "DPRK3"
      assert record.evidence_uri =~ "42001"
    end

    test "preserves provenance in metadata" do
      %{records: [record], skipped: []} = OFAC.parse([@eth_entry])

      assert record.metadata["sdn_id"] == 42001
      assert record.metadata["entity_name"] == "LAZARUS GROUP"
      assert record.metadata["programs"] == ["DPRK3", "CYBER2"]
      assert record.metadata["ticker"] == "ETH"
    end

    test "skips entries with unsupported ticker" do
      %{records: [], skipped: [skipped]} = OFAC.parse([@unsupported_ticker_entry])

      assert skipped.reason =~ "unsupported ticker"
    end

    test "skips entries with missing address" do
      %{records: [], skipped: [skipped]} = OFAC.parse([@missing_address_entry])

      assert skipped.reason =~ "missing id_number"
    end

    test "handles mixed valid and invalid entries" do
      entries = [@eth_entry, @unsupported_ticker_entry, @btc_entry, @missing_address_entry]

      %{records: records, skipped: skipped} = OFAC.parse(entries)

      assert length(records) == 2
      assert length(skipped) == 2
    end

    test "handles empty list" do
      assert %{records: [], skipped: []} = OFAC.parse([])
    end

    test "all records have hard_block tier" do
      entries = [@eth_entry, @btc_entry, @usdt_entry]
      %{records: records, skipped: []} = OFAC.parse(entries)

      assert Enum.all?(records, &(&1.control_tier == :hard_block))
    end

    test "all records have ofac source" do
      %{records: records, skipped: []} = OFAC.parse([@eth_entry, @btc_entry])

      assert Enum.all?(records, &(&1.source == "ofac"))
    end
  end
end
