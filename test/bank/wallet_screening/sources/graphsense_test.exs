defmodule Bank.WalletScreening.Sources.GraphSenseTest do
  use ExUnit.Case, async: true

  alias Bank.WalletScreening.Sources.GraphSense

  @eth_tag %{
    "address" => "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
    "currency" => "ETH",
    "label" => "Uniswap V2: Router",
    "source" => "https://etherscan.io/address/0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
    "category" => "defi",
    "lastmod" => "2025-06-01",
    "confidence" => "verified"
  }

  @btc_tag %{
    "address" => "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
    "currency" => "BTC",
    "label" => "Satoshi Nakamoto Genesis",
    "source" => "https://blockchair.com/bitcoin/address/1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
    "category" => "mining"
  }

  @exchange_tag %{
    "address" => "0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8",
    "currency" => "ETH",
    "label" => "Binance Hot Wallet",
    "category" => "exchange",
    "lastmod" => "2025-03-15"
  }

  @no_address_tag %{
    "currency" => "ETH",
    "label" => "Missing address tag"
  }

  @no_currency_tag %{
    "address" => "0xSomeAddr",
    "label" => "Missing currency"
  }

  @unsupported_currency_tag %{
    "address" => "DogeSomeAddr",
    "currency" => "DOGE",
    "label" => "Dogecoin Exchange"
  }

  @tagpack_envelope %{
    "title" => "DeFi Protocol Tags",
    "creator" => "graphsense",
    "tags" => [@eth_tag, @btc_tag]
  }

  @address_only_tagpack %{
    "title" => "GraphSense Binance",
    "creator" => "GraphSense Core Team",
    "confidence" => "service_data",
    "category" => "exchange",
    "currency" => "BTC",
    "label" => "binance.com",
    "lastmod" => "2019-07-03",
    "source" => "https://www.coindesk.com/binance-hack",
    "tags" => [
      %{"address" => "1NDyJtNTjmwk5xPNhjgAMu4HDHigtobu1s"},
      %{"address" => "3CTPRyUbCKkByGmAVvDV6ReZXT1WfV3UPd"}
    ]
  }

  @tagpack_yaml """
  title: GraphSense Binance
  creator: GraphSense Core Team
  is_cluster_definer: true
  confidence: service_data
  description: Addresses related to Binance
  category: exchange
  currency: BTC
  label: binance.com
  lastmod: 2019-07-03
  source: https://www.coindesk.com/hackers-steal-40-7-million-in-bitcoin-from-crypto-exchange-binance
  actor: binance
  tags:
  - address: 1NDyJtNTjmwk5xPNhjgAMu4HDHigtobu1s
  - address: 3CTPRyUbCKkByGmAVvDV6ReZXT1WfV3UPd
  """

  describe "extract_tags/1" do
    test "extracts tags from tagpack envelope" do
      tags = GraphSense.extract_tags(@tagpack_envelope)
      assert length(tags) == 2
    end

    test "applies root tagpack metadata to address-only tags" do
      [first, second] = GraphSense.extract_tags(@address_only_tagpack)

      assert first["address"] == "1NDyJtNTjmwk5xPNhjgAMu4HDHigtobu1s"
      assert first["currency"] == "BTC"
      assert first["label"] == "binance.com"
      assert first["category"] == "exchange"
      assert first["source"] == "https://www.coindesk.com/binance-hack"

      assert second["currency"] == "BTC"
      assert second["creator"] == "GraphSense Core Team"
    end

    test "passes through bare array" do
      tags = GraphSense.extract_tags([@eth_tag, @btc_tag])
      assert length(tags) == 2
    end

    test "returns empty for unexpected input" do
      assert GraphSense.extract_tags("not json") == []
      assert GraphSense.extract_tags(%{}) == []
    end
  end

  describe "decode_yaml/1" do
    test "decodes canonical public GraphSense tagpack YAML" do
      tagpack = GraphSense.decode_yaml(@tagpack_yaml)
      tags = GraphSense.extract_tags(tagpack)

      assert tagpack["title"] == "GraphSense Binance"
      assert tagpack["currency"] == "BTC"
      assert length(tags) == 2
      assert Enum.all?(tags, &(&1["currency"] == "BTC"))
      assert Enum.all?(tags, &(&1["label"] == "binance.com"))
    end

    test "decoded YAML feeds into the normal parser" do
      %{records: records, skipped: []} =
        @tagpack_yaml
        |> GraphSense.decode_yaml()
        |> GraphSense.extract_tags()
        |> GraphSense.parse()

      assert length(records) == 2
      assert Enum.all?(records, &(&1.chain == "bitcoin"))
      assert Enum.all?(records, &(&1.control_tier == :context))
    end
  end

  describe "parse/1" do
    test "parses ETH tag with correct chain and control_tier" do
      %{records: [record], skipped: []} = GraphSense.parse([@eth_tag])

      assert record.chain == "ethereum"
      assert record.address == "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"
      assert record.control_tier == :context
      assert record.source == "graphsense"
      assert record.category == "defi"
    end

    test "parses BTC tag with bitcoin chain" do
      %{records: [record], skipped: []} = GraphSense.parse([@btc_tag])

      assert record.chain == "bitcoin"
      assert record.address == "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
      assert record.control_tier == :context
    end

    test "preserves provenance in reason" do
      %{records: [record], skipped: []} = GraphSense.parse([@eth_tag])

      assert record.reason =~ "GraphSense"
      assert record.reason =~ "Uniswap V2: Router"
      assert record.reason =~ "defi"
    end

    test "uses source URI as evidence_uri when available" do
      %{records: [record], skipped: []} = GraphSense.parse([@eth_tag])

      assert record.evidence_uri ==
               "https://etherscan.io/address/0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"
    end

    test "falls back to graphsense URL when source is missing" do
      %{records: [record], skipped: []} = GraphSense.parse([@exchange_tag])

      assert record.evidence_uri =~ "graphsense.info/address/"
    end

    test "preserves metadata with label, currency, category, lastmod" do
      %{records: [record], skipped: []} = GraphSense.parse([@eth_tag])

      assert record.metadata["label"] == "Uniswap V2: Router"
      assert record.metadata["currency"] == "ETH"
      assert record.metadata["category"] == "defi"
      assert record.metadata["lastmod"] == "2025-06-01"
      assert record.metadata["confidence"] == "verified"
    end

    test "parses lastmod date into first_seen_at" do
      %{records: [record], skipped: []} = GraphSense.parse([@eth_tag])

      assert record.first_seen_at != nil
    end

    test "skips tags with missing address" do
      %{records: [], skipped: [skipped]} = GraphSense.parse([@no_address_tag])

      assert skipped.reason =~ "missing or empty address"
    end

    test "skips tags with missing currency" do
      %{records: [], skipped: [skipped]} = GraphSense.parse([@no_currency_tag])

      assert skipped.reason =~ "missing currency"
    end

    test "skips tags with unsupported currency" do
      %{records: [], skipped: [skipped]} = GraphSense.parse([@unsupported_currency_tag])

      assert skipped.reason =~ "unsupported currency"
    end

    test "all records have context tier" do
      tags = [@eth_tag, @btc_tag, @exchange_tag]
      %{records: records, skipped: []} = GraphSense.parse(tags)

      assert length(records) == 3
      assert Enum.all?(records, &(&1.control_tier == :context))
    end

    test "all records have graphsense source" do
      %{records: records, skipped: []} = GraphSense.parse([@eth_tag, @btc_tag])

      assert Enum.all?(records, &(&1.source == "graphsense"))
    end

    test "handles mixed valid and invalid tags" do
      tags = [@eth_tag, @no_address_tag, @btc_tag, @unsupported_currency_tag]
      %{records: records, skipped: skipped} = GraphSense.parse(tags)

      assert length(records) == 2
      assert length(skipped) == 2
    end

    test "handles empty list" do
      assert %{records: [], skipped: []} = GraphSense.parse([])
    end
  end
end
