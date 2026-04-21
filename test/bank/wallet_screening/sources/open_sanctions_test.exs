defmodule Bank.WalletScreening.Sources.OpenSanctionsTest do
  use ExUnit.Case, async: true

  alias Bank.WalletScreening.Sources.OpenSanctions

  @btc_wallet %{
    "id" => "os-wallet-001",
    "schema" => "CryptoWallet",
    "properties" => %{
      "publicKey" => ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"],
      "currency" => ["BTC"],
      "holder" => ["os-entity-lazarus"],
      "topics" => ["sanction"],
      "sourceUrl" => ["https://opensanctions.org/entities/os-wallet-001/"]
    }
  }

  @eth_wallet %{
    "id" => "os-wallet-002",
    "schema" => "CryptoWallet",
    "properties" => %{
      "publicKey" => ["0xDeAdBeEf00000000000000000000000000000002"],
      "currency" => ["ETH"],
      "holder" => [],
      "topics" => ["sanction"],
      "sourceUrl" => ["https://ofac.treasury.gov/sdn"]
    }
  }

  @multi_address_wallet %{
    "id" => "os-wallet-003",
    "schema" => "CryptoWallet",
    "properties" => %{
      "publicKey" => ["0xAddr1", "0xAddr2"],
      "currency" => ["ETH"],
      "topics" => ["sanction"]
    }
  }

  @non_sanctioned_wallet %{
    "id" => "os-wallet-004",
    "schema" => "CryptoWallet",
    "properties" => %{
      "publicKey" => ["0xCleanWallet"],
      "currency" => ["ETH"],
      "topics" => ["poi"]
    }
  }

  @non_wallet_entity %{
    "id" => "os-person-001",
    "schema" => "Person",
    "properties" => %{
      "name" => ["Kim Jong Un"],
      "topics" => ["sanction"]
    }
  }

  @unsupported_currency_wallet %{
    "id" => "os-wallet-099",
    "schema" => "CryptoWallet",
    "properties" => %{
      "publicKey" => ["SomeDogeAddress"],
      "currency" => ["DOGE"],
      "topics" => ["sanction"]
    }
  }

  @mixed_currency_wallet %{
    "id" => "os-wallet-098",
    "schema" => "CryptoWallet",
    "properties" => %{
      "publicKey" => ["0xMixedCurrencyWallet"],
      "currency" => ["ETH", "DOGE"],
      "topics" => ["sanction"]
    }
  }

  @empty_address_wallet %{
    "id" => "os-wallet-097",
    "schema" => "CryptoWallet",
    "properties" => %{
      "publicKey" => ["", "  "],
      "currency" => ["ETH"],
      "topics" => ["sanction"]
    }
  }

  @no_address_wallet %{
    "id" => "os-wallet-100",
    "schema" => "CryptoWallet",
    "properties" => %{
      "publicKey" => [],
      "currency" => ["ETH"],
      "topics" => ["sanction"]
    }
  }

  describe "filter_sanctioned_wallets/1" do
    test "includes sanctioned CryptoWallet entities" do
      entities = [@btc_wallet, @eth_wallet, @non_wallet_entity, @non_sanctioned_wallet]

      result = OpenSanctions.filter_sanctioned_wallets(entities)

      assert length(result) == 2
      assert Enum.all?(result, &(&1["schema"] == "CryptoWallet"))
    end

    test "excludes non-wallet entities and non-sanctioned wallets" do
      result =
        OpenSanctions.filter_sanctioned_wallets([@non_wallet_entity, @non_sanctioned_wallet])

      assert result == []
    end
  end

  describe "parse/1" do
    test "parses BTC wallet with correct chain and provenance" do
      %{records: [record], skipped: []} = OpenSanctions.parse([@btc_wallet])

      assert record.chain == "bitcoin"
      assert record.address == "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
      assert record.control_tier == :hard_block
      assert record.source == "opensanctions"
      assert record.source_record_id =~ "os-wallet-001"
      assert record.category == "sanctions"
      assert record.reason =~ "OpenSanctions"
      assert record.reason =~ "BTC"
    end

    test "parses ETH wallet with source URL as evidence_uri" do
      %{records: [record], skipped: []} = OpenSanctions.parse([@eth_wallet])

      assert record.chain == "ethereum"
      assert record.evidence_uri == "https://ofac.treasury.gov/sdn"
    end

    test "produces one record per address for multi-address wallets" do
      %{records: records, skipped: []} = OpenSanctions.parse([@multi_address_wallet])

      assert length(records) == 2
      addresses = Enum.map(records, & &1.address)
      assert "0xAddr1" in addresses
      assert "0xAddr2" in addresses
    end

    test "preserves metadata with entity_id and holders" do
      %{records: [record], skipped: []} = OpenSanctions.parse([@btc_wallet])

      assert record.metadata["entity_id"] == "os-wallet-001"
      assert record.metadata["holders"] == ["os-entity-lazarus"]
      assert record.metadata["currency"] == "BTC"
    end

    test "skips wallets with unsupported currency" do
      %{records: [], skipped: [skipped]} = OpenSanctions.parse([@unsupported_currency_wallet])

      assert skipped.reason =~ "unsupported currency"
    end

    test "records supported currencies while reporting unsupported siblings" do
      %{records: [record], skipped: [skipped]} = OpenSanctions.parse([@mixed_currency_wallet])

      assert record.chain == "ethereum"
      assert record.address == "0xMixedCurrencyWallet"
      assert skipped.reason =~ "unsupported currency: DOGE"
    end

    test "skips empty publicKey values instead of producing malformed records" do
      %{records: [], skipped: skipped} = OpenSanctions.parse([@empty_address_wallet])

      assert length(skipped) == 2
      assert Enum.all?(skipped, &(&1.reason =~ "empty publicKey"))
    end

    test "skips wallets with no address" do
      %{records: [], skipped: [skipped]} = OpenSanctions.parse([@no_address_wallet])

      assert skipped.reason =~ "no publicKey"
    end

    test "filters out non-sanctioned and non-wallet entities automatically" do
      entities = [
        @btc_wallet,
        @non_wallet_entity,
        @non_sanctioned_wallet,
        @eth_wallet
      ]

      %{records: records, skipped: []} = OpenSanctions.parse(entities)

      assert length(records) == 2
      sources = Enum.map(records, & &1.source) |> Enum.uniq()
      assert sources == ["opensanctions"]
    end

    test "all records have hard_block tier" do
      %{records: records, skipped: []} = OpenSanctions.parse([@btc_wallet, @eth_wallet])

      assert Enum.all?(records, &(&1.control_tier == :hard_block))
    end

    test "handles empty list" do
      assert %{records: [], skipped: []} = OpenSanctions.parse([])
    end
  end
end
