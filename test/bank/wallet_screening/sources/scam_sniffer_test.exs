defmodule Bank.WalletScreening.Sources.ScamSnifferTest do
  use ExUnit.Case, async: true

  alias Bank.WalletScreening.Sources.ScamSniffer

  @phishing_entry %{
    "address" => "0xDeAdBeEf00000000000000000000000000000099",
    "chain" => "ethereum",
    "type" => "phishing",
    "name" => "Inferno Drainer",
    "url" => "https://scamsniffer.io/address/0xDeAdBeEf00000000000000000000000000000099"
  }

  @drainer_entry %{
    "address" => "0xABCD1234567890abcdef1234567890ABCDEF1234",
    "chain" => "base",
    "type" => "drainer",
    "name" => "Angel Drainer"
  }

  @no_chain_entry %{
    "address" => "0xNoChainAddr",
    "type" => "scam"
  }

  @missing_address_entry %{
    "chain" => "ethereum",
    "type" => "phishing"
  }

  @blank_address_entry %{
    "address" => "   ",
    "chain" => "ethereum",
    "type" => "phishing"
  }

  @combined_json_shape %{
    "degenalgo.art" => [
      "0x3da02e1f29bcbed185eca0d3299efd46e6e7e155",
      "0x398e98b7c19db2f5df086eb4f83624146aa1ab53"
    ],
    "bad-entry.example" => "not-a-list"
  }

  describe "parse/1" do
    test "parses phishing entry with correct chain and control_tier" do
      %{records: [record], skipped: []} = ScamSniffer.parse([@phishing_entry])

      assert record.chain == "ethereum"
      assert record.address == "0xDeAdBeEf00000000000000000000000000000099"
      assert record.control_tier == :challenge
      assert record.source == "scamsniffer"
      assert record.category == "phishing"
    end

    test "preserves provenance in reason and evidence_uri" do
      %{records: [record], skipped: []} = ScamSniffer.parse([@phishing_entry])

      assert record.reason =~ "ScamSniffer"
      assert record.reason =~ "phishing"
      assert record.reason =~ "Inferno Drainer"
      assert record.evidence_uri =~ "scamsniffer.io"
    end

    test "respects explicit chain field" do
      %{records: [record], skipped: []} = ScamSniffer.parse([@drainer_entry])

      assert record.chain == "base"
      assert record.category == "drainer"
    end

    test "defaults chain to ethereum when missing" do
      %{records: [record], skipped: []} = ScamSniffer.parse([@no_chain_entry])

      assert record.chain == "ethereum"
    end

    test "generates fallback evidence_uri when url missing" do
      %{records: [record], skipped: []} = ScamSniffer.parse([@no_chain_entry])

      assert record.evidence_uri =~ "scamsniffer.io/address/"
    end

    test "skips entries with missing address" do
      %{records: [], skipped: [skipped]} = ScamSniffer.parse([@missing_address_entry])

      assert skipped.reason =~ "missing or empty address"
    end

    test "skips entries with blank address" do
      %{records: [], skipped: [skipped]} = ScamSniffer.parse([@blank_address_entry])

      assert skipped.reason =~ "missing or empty address"
    end

    test "preserves raw metadata" do
      %{records: [record], skipped: []} = ScamSniffer.parse([@phishing_entry])

      assert record.metadata["type"] == "phishing"
      assert record.metadata["name"] == "Inferno Drainer"
    end

    test "all records have challenge tier" do
      entries = [@phishing_entry, @drainer_entry, @no_chain_entry]
      %{records: records, skipped: []} = ScamSniffer.parse(entries)

      assert length(records) == 3
      assert Enum.all?(records, &(&1.control_tier == :challenge))
    end

    test "all records have scamsniffer source" do
      %{records: records, skipped: []} = ScamSniffer.parse([@phishing_entry, @drainer_entry])

      assert Enum.all?(records, &(&1.source == "scamsniffer"))
    end

    test "handles empty list" do
      assert %{records: [], skipped: []} = ScamSniffer.parse([])
    end

    test "parses ScamSniffer combined.json domain-to-address-map shape" do
      %{records: records, skipped: [skipped]} = ScamSniffer.parse(@combined_json_shape)

      assert length(records) == 2
      assert skipped.reason =~ "not an address list"

      assert Enum.all?(records, &(&1.chain == "ethereum"))
      assert Enum.all?(records, &(&1.category == "phishing"))
      assert Enum.all?(records, &(&1.metadata["domain"] == "degenalgo.art"))
      assert Enum.all?(records, &(&1.reason =~ "degenalgo.art"))
    end

    test "parses ScamSniffer address.json bare-address array shape" do
      %{records: [record], skipped: []} =
        ScamSniffer.parse(["0x101ce0cedd142f199c9ef61739ae59b6611a0fc0"])

      assert record.chain == "ethereum"
      assert record.address == "0x101ce0cedd142f199c9ef61739ae59b6611a0fc0"
      assert record.category == "phishing"
    end
  end
end
