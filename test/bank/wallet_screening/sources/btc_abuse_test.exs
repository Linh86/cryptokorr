defmodule Bank.WalletScreening.Sources.BTCAbuseTest do
  use ExUnit.Case, async: true

  alias Bank.WalletScreening.Sources.BTCAbuse

  @csv_header "id,address,abuse_type_id,abuse_type_other,abuser,description,from_country,from_country_code,created_at"

  @csv_ransomware "1001,1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa,1,,hacker@evil.com,Ransomware demand,US,us,2025-01-15T10:00:00Z"
  @csv_sextortion "1002,1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa,5,,scammer@spam.net,Sextortion email,GB,gb,2025-02-20T14:30:00Z"
  @csv_other_addr "1003,3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy,4,,blackmailer@bad.org,Blackmail threat,DE,de,2025-03-10T09:15:00Z"
  @csv_missing_addr "1004,,1,,unknown,No address given,,,2025-04-01T00:00:00Z"

  defp csv_body(rows) do
    [@csv_header | rows] |> Enum.join("\n")
  end

  @json_entries [
    %{
      "id" => "2001",
      "address" => "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
      "abuse_type_id" => "1",
      "created_at" => "2025-01-15T10:00:00Z"
    },
    %{
      "id" => "2002",
      "address" => "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
      "abuse_type_id" => "5",
      "created_at" => "2025-06-01T12:00:00Z"
    },
    %{
      "id" => "2003",
      "address" => "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy",
      "abuse_type_id" => "4",
      "created_at" => "2025-03-10T09:15:00Z"
    }
  ]

  describe "parse_csv/1" do
    test "deduplicates by address — two reports for the same address produce one record" do
      body = csv_body([@csv_ransomware, @csv_sextortion, @csv_other_addr])

      %{records: records, skipped: []} = BTCAbuse.parse_csv(body)

      assert length(records) == 2
      addresses = Enum.map(records, & &1.address)
      assert "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa" in addresses
      assert "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy" in addresses
    end

    test "all records are bitcoin chain with challenge tier" do
      body = csv_body([@csv_ransomware, @csv_other_addr])
      %{records: records, skipped: []} = BTCAbuse.parse_csv(body)

      assert Enum.all?(records, &(&1.chain == "bitcoin"))
      assert Enum.all?(records, &(&1.control_tier == :challenge))
      assert Enum.all?(records, &(&1.source == "btc_abuse"))
    end

    test "aggregates report count in metadata" do
      body = csv_body([@csv_ransomware, @csv_sextortion])
      %{records: [record], skipped: []} = BTCAbuse.parse_csv(body)

      assert record.metadata["report_count"] == 2
    end

    test "picks dominant abuse type from frequencies" do
      body = csv_body([@csv_ransomware, @csv_sextortion])
      %{records: [record], skipped: []} = BTCAbuse.parse_csv(body)

      assert record.category in ["ransomware", "sextortion"]
      assert record.reason =~ "2 reports"
    end

    test "preserves first_seen and last_seen from reports" do
      body = csv_body([@csv_ransomware, @csv_sextortion])
      %{records: [record], skipped: []} = BTCAbuse.parse_csv(body)

      assert record.metadata["first_report"] == "2025-01-15T10:00:00Z"
      assert record.metadata["last_report"] == "2025-02-20T14:30:00Z"
    end

    test "builds evidence_uri with address" do
      body = csv_body([@csv_other_addr])
      %{records: [record], skipped: []} = BTCAbuse.parse_csv(body)

      assert record.evidence_uri =~ "btcabuse.com/browse/"
      assert record.evidence_uri =~ "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"
    end

    test "skips rows with missing address" do
      body = csv_body([@csv_missing_addr])
      %{records: [], skipped: [skipped]} = BTCAbuse.parse_csv(body)

      assert skipped.reason =~ "missing or empty address"
    end

    test "handles empty CSV" do
      assert %{records: [], skipped: []} = BTCAbuse.parse_csv("")
    end

    test "handles header-only CSV" do
      assert %{records: [], skipped: []} = BTCAbuse.parse_csv(@csv_header)
    end
  end

  describe "parse/1 (JSON variant)" do
    test "deduplicates by address" do
      %{records: records, skipped: []} = BTCAbuse.parse(@json_entries)

      assert length(records) == 2
    end

    test "all records have challenge tier and btc_abuse source" do
      %{records: records, skipped: []} = BTCAbuse.parse(@json_entries)

      assert Enum.all?(records, &(&1.control_tier == :challenge))
      assert Enum.all?(records, &(&1.source == "btc_abuse"))
      assert Enum.all?(records, &(&1.chain == "bitcoin"))
    end

    test "handles empty list" do
      assert %{records: [], skipped: []} = BTCAbuse.parse([])
    end
  end
end
