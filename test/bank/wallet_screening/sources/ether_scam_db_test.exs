defmodule Bank.WalletScreening.Sources.EtherScamDBTest do
  use ExUnit.Case, async: true

  alias Bank.WalletScreening.Sources.EtherScamDB

  @phishing_entry %{
    "id" => 12345,
    "name" => "Fake Uniswap",
    "url" => "https://fake-uniswap.com",
    "coin" => "ETH",
    "category" => "Phishing",
    "subcategory" => "ICO Scam",
    "description" => "Fake token swap site draining wallets",
    "addresses" => ["0xScamAddr001", "0xScamAddr002"],
    "reporter" => "community",
    "status" => "Active"
  }

  @single_address_entry %{
    "id" => 12346,
    "name" => "Ponzi Token",
    "category" => "Scamming",
    "address" => "0xSingleAddr001",
    "status" => "Verified"
  }

  @no_address_entry %{
    "id" => 12347,
    "name" => "Missing Addr Scam",
    "category" => "Phishing"
  }

  @empty_addresses_entry %{
    "id" => 12348,
    "name" => "Empty List Scam",
    "category" => "Scamming",
    "addresses" => []
  }

  @blank_address_entry %{
    "id" => 12349,
    "name" => "Blank Addr",
    "category" => "Phishing",
    "addresses" => ["  ", ""]
  }

  @scams_yaml """
  -
      id: 2
      name: myelherwallel.com
      url: 'http://myelherwallel.com'
      coin: ETH
      category: Phishing
      subcategory: MyEtherWallet
      addresses:
          - '0xD0cC2B24980CBCCA47EF755Da88B220a82291407'
          - '0x4cdc1cba0aeb5539f2e0ba158281e67e0e54a9b1'
      reporter: MyCrypto
  -
      id: 7
      name: xn--mytherwallet-fvb.com
      url: 'http://xn--mytherwallet-fvb.com'
      coin: ETH
      category: Phishing
      subcategory: MyEtherWallet
      description: |-
          Multiline descriptions exist in the public feed and should not break decoding.
      reporter: MyCrypto
  """

  describe "parse/1" do
    test "parses entry with addresses array producing one record per address" do
      %{records: records, skipped: []} = EtherScamDB.parse([@phishing_entry])

      assert length(records) == 2
      addresses = Enum.map(records, & &1.address)
      assert "0xScamAddr001" in addresses
      assert "0xScamAddr002" in addresses
    end

    test "all records are ethereum chain with challenge tier" do
      %{records: records, skipped: []} = EtherScamDB.parse([@phishing_entry])

      assert Enum.all?(records, &(&1.chain == "ethereum"))
      assert Enum.all?(records, &(&1.control_tier == :challenge))
      assert Enum.all?(records, &(&1.source == "etherscamdb"))
    end

    test "preserves provenance in reason" do
      %{records: [record | _], skipped: []} = EtherScamDB.parse([@phishing_entry])

      assert record.reason =~ "EtherScamDB"
      assert record.reason =~ "Phishing"
      assert record.reason =~ "ICO Scam"
      assert record.reason =~ "Fake Uniswap"
    end

    test "builds evidence_uri from entry id" do
      %{records: [record | _], skipped: []} = EtherScamDB.parse([@phishing_entry])

      assert record.evidence_uri =~ "etherscamdb.info/scam/12345"
    end

    test "preserves metadata with entry_id, category, subcategory, and status" do
      %{records: [record | _], skipped: []} = EtherScamDB.parse([@phishing_entry])

      assert record.metadata["entry_id"] == 12345
      assert record.metadata["category"] == "Phishing"
      assert record.metadata["subcategory"] == "ICO Scam"
      assert record.metadata["status"] == "Active"
      assert record.metadata["scam_url"] == "https://fake-uniswap.com"
    end

    test "handles single address field (no addresses array)" do
      %{records: [record], skipped: []} = EtherScamDB.parse([@single_address_entry])

      assert record.address == "0xSingleAddr001"
      assert record.chain == "ethereum"
      assert record.control_tier == :challenge
    end

    test "skips entries with no address at all" do
      %{records: [], skipped: [skipped]} = EtherScamDB.parse([@no_address_entry])

      assert skipped.reason =~ "no usable address"
    end

    test "skips entries with empty addresses array" do
      %{records: [], skipped: [skipped]} = EtherScamDB.parse([@empty_addresses_entry])

      assert skipped.reason =~ "no usable address"
    end

    test "skips blank addresses within array" do
      %{records: [], skipped: skipped} = EtherScamDB.parse([@blank_address_entry])

      assert length(skipped) == 2
      assert Enum.all?(skipped, &(&1.reason =~ "empty address"))
    end

    test "category is lowercased" do
      %{records: [record | _], skipped: []} = EtherScamDB.parse([@phishing_entry])

      assert record.category == "phishing"
    end

    test "handles empty list" do
      assert %{records: [], skipped: []} = EtherScamDB.parse([])
    end
  end

  describe "decode_yaml/1" do
    test "decodes canonical EtherScamDB _data/scams.yaml shape" do
      entries = EtherScamDB.decode_yaml(@scams_yaml)

      assert [
               %{
                 "id" => "2",
                 "name" => "myelherwallel.com",
                 "url" => "http://myelherwallel.com",
                 "coin" => "ETH",
                 "category" => "Phishing",
                 "addresses" => [
                   "0xD0cC2B24980CBCCA47EF755Da88B220a82291407",
                   "0x4cdc1cba0aeb5539f2e0ba158281e67e0e54a9b1"
                 ]
               },
               %{"id" => "7", "name" => "xn--mytherwallet-fvb.com"}
             ] = entries
    end

    test "decoded YAML entries feed into the normal parser" do
      %{records: records, skipped: skipped} =
        @scams_yaml
        |> EtherScamDB.decode_yaml()
        |> EtherScamDB.parse()

      assert length(records) == 2
      assert length(skipped) == 1
      assert Enum.all?(records, &(&1.source == "etherscamdb"))
    end
  end
end
