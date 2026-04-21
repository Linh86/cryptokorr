defmodule Bank.WalletScreening.ScamFeedIngestionTest do
  use Bank.DataCase, async: true

  alias Bank.WalletScreening
  alias Bank.WalletScreening.Ingestion

  # --- ScamSniffer fixture data ------------------------------------------

  @scamsniffer_entries [
    %{
      "address" => "0xPhishAddr001",
      "chain" => "ethereum",
      "type" => "phishing",
      "name" => "Inferno Drainer",
      "url" => "https://scamsniffer.io/address/0xPhishAddr001"
    },
    %{
      "address" => "0xDrainerAddr002",
      "chain" => "base",
      "type" => "drainer",
      "name" => "Angel Drainer"
    }
  ]

  @scamsniffer_combined %{
    "degenalgo.art" => [
      "0x3da02e1f29bcbed185eca0d3299efd46e6e7e155",
      "0x398e98b7c19db2f5df086eb4f83624146aa1ab53"
    ]
  }

  # --- EtherScamDB fixture data ------------------------------------------

  @etherscamdb_entries [
    %{
      "id" => 55001,
      "name" => "Fake DEX",
      "category" => "Phishing",
      "subcategory" => "DEX Scam",
      "addresses" => ["0xEthScamAddr001", "0xEthScamAddr002"],
      "url" => "https://fake-dex.com",
      "status" => "Active"
    },
    %{
      "id" => 55002,
      "name" => "Ponzi Token",
      "category" => "Scamming",
      "address" => "0xEthScamAddr003",
      "status" => "Verified"
    }
  ]

  @etherscamdb_yaml """
  -
      id: 55001
      name: Fake DEX
      url: 'https://fake-dex.com'
      coin: ETH
      category: Phishing
      subcategory: DEX Scam
      addresses:
          - '0xEthScamAddr001'
          - '0xEthScamAddr002'
      status: Active
  -
      id: 55002
      name: Ponzi Token
      coin: ETH
      category: Scamming
      addresses:
          - '0xEthScamAddr003'
      status: Verified
  """

  # --- BTC Abuse fixture data --------------------------------------------

  @btc_abuse_csv """
  id,address,abuse_type_id,abuse_type_other,abuser,description,from_country,from_country_code,created_at
  9001,1BTCScamAddr001,1,,hacker@evil.com,Ransomware demand,US,us,2025-01-15T10:00:00Z
  9002,1BTCScamAddr001,5,,scammer@spam.net,Sextortion email,GB,gb,2025-02-20T14:30:00Z
  9003,3BTCScamAddr002,4,,blackmailer@bad.org,Blackmail threat,DE,de,2025-03-10T09:15:00Z
  """

  # --- ScamSniffer ingestion tests ---------------------------------------

  describe "ingest_scamsniffer/1" do
    test "ingests ScamSniffer entries as challenge records" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@scamsniffer_entries))
      end)

      assert {:ok, result} = Ingestion.ingest_scamsniffer()

      assert result.source == "scamsniffer"
      assert result.ingested == 2
      assert result.skipped == 0

      records = WalletScreening.list_records(%{source: "scamsniffer"})
      assert length(records) == 2
      assert Enum.all?(records, &(&1.control_tier == :challenge))
    end

    test "ScamSniffer records produce :challenge screening outcome" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@scamsniffer_entries))
      end)

      {:ok, _} = Ingestion.ingest_scamsniffer()

      result = WalletScreening.screen("ethereum", "0xPhishAddr001")
      assert result.outcome == :challenge
      assert result.winning_record.source == "scamsniffer"
      assert result.winning_record.reason =~ "Inferno Drainer"
    end

    test "ScamSniffer respects explicit chain" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@scamsniffer_entries))
      end)

      {:ok, _} = Ingestion.ingest_scamsniffer()

      base_result = WalletScreening.screen("base", "0xDrainerAddr002")
      assert base_result.outcome == :challenge

      eth_result = WalletScreening.screen("ethereum", "0xDrainerAddr002")
      assert eth_result.outcome == :clean
    end

    test "ScamSniffer ingests current combined.json domain map shape" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@scamsniffer_combined))
      end)

      assert {:ok, %{ingested: 2}} = Ingestion.ingest_scamsniffer()

      result = WalletScreening.screen("ethereum", "0x3da02e1f29bcbed185eca0d3299efd46e6e7e155")
      assert result.outcome == :challenge
      assert result.winning_record.reason =~ "degenalgo.art"
    end

    test "ScamSniffer handles HTTP error" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        Plug.Conn.resp(conn, 503, "Service Unavailable")
      end)

      assert {:error, {:http_error, 503}} = Ingestion.ingest_scamsniffer()
    end
  end

  # --- EtherScamDB ingestion tests ---------------------------------------

  describe "ingest_etherscamdb/1" do
    test "ingests EtherScamDB entries as challenge records" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/yaml")
        |> Plug.Conn.resp(200, @etherscamdb_yaml)
      end)

      assert {:ok, result} = Ingestion.ingest_etherscamdb()

      assert result.source == "etherscamdb"
      assert result.ingested == 3

      records = WalletScreening.list_records(%{source: "etherscamdb"})
      assert length(records) == 3
      assert Enum.all?(records, &(&1.control_tier == :challenge))
      assert Enum.all?(records, &(&1.chain == "ethereum"))
    end

    test "EtherScamDB records produce :challenge screening outcome" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/yaml")
        |> Plug.Conn.resp(200, @etherscamdb_yaml)
      end)

      {:ok, _} = Ingestion.ingest_etherscamdb()

      result = WalletScreening.screen("ethereum", "0xEthScamAddr001")
      assert result.outcome == :challenge
      assert result.winning_record.source == "etherscamdb"
      assert result.winning_record.reason =~ "Fake DEX"
    end

    test "EtherScamDB handles wrapped JSON response" do
      body = %{"result" => @etherscamdb_entries}

      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert {:ok, %{ingested: 3}} = Ingestion.ingest_etherscamdb()
    end
  end

  # --- BTC Abuse ingestion tests -----------------------------------------

  describe "ingest_btc_abuse/1" do
    test "ingests BTC abuse CSV as deduplicated challenge records" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/csv")
        |> Plug.Conn.resp(200, @btc_abuse_csv)
      end)

      assert {:ok, result} = Ingestion.ingest_btc_abuse()

      assert result.source == "btc_abuse"
      assert result.ingested == 2

      records = WalletScreening.list_records(%{source: "btc_abuse"})
      assert length(records) == 2
      assert Enum.all?(records, &(&1.control_tier == :challenge))
      assert Enum.all?(records, &(&1.chain == "bitcoin"))
    end

    test "BTC Abuse records produce :challenge screening outcome" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/csv")
        |> Plug.Conn.resp(200, @btc_abuse_csv)
      end)

      {:ok, _} = Ingestion.ingest_btc_abuse()

      result = WalletScreening.screen("bitcoin", "1BTCScamAddr001")
      assert result.outcome == :challenge
      assert result.winning_record.source == "btc_abuse"
      assert result.winning_record.reason =~ "reports"
    end

    test "BTC Abuse handles HTTP error" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, {:http_error, 500}} = Ingestion.ingest_btc_abuse()
    end

    test "BTC Abuse requires an explicit feed URL because the public bulk API is not currently live" do
      assert {:error, :btc_abuse_feed_url_not_configured} = Ingestion.ingest_btc_abuse(url: nil)
    end
  end

  # --- Cross-source and precedence tests ---------------------------------

  describe "scam feeds vs sanctions precedence" do
    test "sanctions hard_block takes precedence over scam challenge" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        if String.contains?(conn.host, "scamsniffer") do
          entry = %{
            "address" => "0xSharedScamAddr",
            "chain" => "ethereum",
            "type" => "phishing"
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!([entry]))
        else
          ofac_entry = %{
            "id" => 77001,
            "id_type" => "Digital Currency Address - ETH",
            "id_number" => "0xSharedScamAddr",
            "name" => "SANCTIONED ENTITY",
            "programs" => ["SDGT"]
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!([ofac_entry]))
        end
      end)

      {:ok, _} = Ingestion.ingest_scamsniffer()
      {:ok, _} = Ingestion.ingest_ofac()

      result = WalletScreening.screen("ethereum", "0xSharedScamAddr")
      assert result.outcome == :block
      assert result.winning_record.control_tier == :hard_block
      assert length(result.all_records) == 2
    end

    test "scam-only address produces :challenge, not :block" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        entry = %{
          "address" => "0xScamOnlyAddr",
          "chain" => "ethereum",
          "type" => "drainer"
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([entry]))
      end)

      {:ok, _} = Ingestion.ingest_scamsniffer()

      result = WalletScreening.screen("ethereum", "0xScamOnlyAddr")
      assert result.outcome == :challenge
      refute result.outcome == :block
    end
  end

  describe "operator provenance" do
    test "operator can identify which scam source caused a challenge" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@scamsniffer_entries))
      end)

      {:ok, _} = Ingestion.ingest_scamsniffer()

      result = WalletScreening.screen("ethereum", "0xPhishAddr001")
      winning = result.winning_record

      assert winning.source == "scamsniffer"
      assert winning.category == "phishing"
      assert winning.reason =~ "Inferno Drainer"
      assert winning.evidence_uri =~ "scamsniffer.io"
    end
  end
end
