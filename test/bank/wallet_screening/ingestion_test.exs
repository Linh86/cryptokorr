defmodule Bank.WalletScreening.IngestionTest do
  use Bank.DataCase, async: true

  alias Bank.WalletScreening
  alias Bank.WalletScreening.{Ingestion, ScreeningRecord}

  # --- OFAC fixture data ------------------------------------------------

  @ofac_eth_entry %{
    "id" => 99001,
    "id_type" => "Digital Currency Address - ETH",
    "id_number" => "0xSanctionedAddr001",
    "name" => "TEST ENTITY A",
    "programs" => ["SDGT"]
  }

  @ofac_btc_entry %{
    "id" => 99002,
    "id_type" => "Digital Currency Address - XBT",
    "id_number" => "1TestBtcSanctionedAddr",
    "name" => "TEST ENTITY B",
    "programs" => ["CYBER2"]
  }

  @ofac_bad_entry %{
    "id" => 99099,
    "id_type" => "Digital Currency Address - DOGE",
    "id_number" => "DUnsupported",
    "name" => "UNSUPPORTED"
  }

  @ofac_non_crypto %{
    "id" => 50001,
    "id_type" => "Passport",
    "id_number" => "AB123"
  }

  defp ofac_feed_body do
    [@ofac_eth_entry, @ofac_btc_entry, @ofac_bad_entry, @ofac_non_crypto]
  end

  # --- OpenSanctions fixture data ---------------------------------------

  @os_btc_entity %{
    "id" => "os-test-001",
    "schema" => "CryptoWallet",
    "properties" => %{
      "publicKey" => ["1OsSanctionedBtcAddr"],
      "currency" => ["BTC"],
      "holder" => ["os-holder-test"],
      "topics" => ["sanction"],
      "sourceUrl" => ["https://opensanctions.org/entities/os-test-001/"]
    }
  }

  @os_eth_entity %{
    "id" => "os-test-002",
    "schema" => "CryptoWallet",
    "properties" => %{
      "publicKey" => ["0xOsSanctionedEthAddr"],
      "currency" => ["ETH"],
      "topics" => ["sanction"]
    }
  }

  @os_non_wallet %{
    "id" => "os-person-001",
    "schema" => "Person",
    "properties" => %{
      "name" => ["Test Person"],
      "topics" => ["sanction"]
    }
  }

  defp opensanctions_ndjson_body do
    [@os_btc_entity, @os_eth_entity, @os_non_wallet]
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
  end

  # --- OFAC ingestion tests ---------------------------------------------

  describe "ingest_ofac/1" do
    test "ingests valid OFAC entries as hard_block records" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(ofac_feed_body()))
      end)

      assert {:ok, result} = Ingestion.ingest_ofac()

      assert result.source == "ofac"
      assert result.ingested == 2
      assert result.skipped == 1

      records = WalletScreening.list_records(%{source: "ofac"})
      assert length(records) == 2
      assert Enum.all?(records, &(&1.control_tier == :hard_block))
    end

    test "OFAC records are screenable via exact match" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([@ofac_eth_entry]))
      end)

      {:ok, _} = Ingestion.ingest_ofac()

      result = WalletScreening.screen("ethereum", "0xSanctionedAddr001")
      assert result.outcome == :block
      assert result.winning_record.source == "ofac"
      assert result.winning_record.reason =~ "TEST ENTITY A"
    end

    test "OFAC upsert is idempotent — second ingestion updates, not duplicates" do
      stub = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([@ofac_eth_entry]))
      end

      Req.Test.stub(Bank.WalletScreening.Ingestion, stub)
      {:ok, first} = Ingestion.ingest_ofac()

      Req.Test.stub(Bank.WalletScreening.Ingestion, stub)
      {:ok, second} = Ingestion.ingest_ofac()

      assert first.ingested == 1
      assert second.ingested == 1

      records = WalletScreening.list_records(%{source: "ofac"})
      assert length(records) == 1
    end

    test "OFAC handles HTTP error gracefully" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        Plug.Conn.resp(conn, 503, "Service Unavailable")
      end)

      assert {:error, {:http_error, 503}} = Ingestion.ingest_ofac()
    end

    test "OFAC handles empty feed" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([]))
      end)

      assert {:ok, %{ingested: 0, skipped: 0}} = Ingestion.ingest_ofac()
    end
  end

  # --- OpenSanctions ingestion tests ------------------------------------

  describe "ingest_opensanctions/1" do
    test "ingests sanctioned wallets as hard_block records" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.resp(200, opensanctions_ndjson_body())
      end)

      assert {:ok, result} = Ingestion.ingest_opensanctions()

      assert result.source == "opensanctions"
      assert result.ingested == 2
      assert result.skipped == 0

      records = WalletScreening.list_records(%{source: "opensanctions"})
      assert length(records) == 2
      assert Enum.all?(records, &(&1.control_tier == :hard_block))
    end

    test "OpenSanctions records are screenable via exact match" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.resp(200, opensanctions_ndjson_body())
      end)

      {:ok, _} = Ingestion.ingest_opensanctions()

      btc_result = WalletScreening.screen("bitcoin", "1OsSanctionedBtcAddr")
      assert btc_result.outcome == :block
      assert btc_result.winning_record.source == "opensanctions"

      eth_result = WalletScreening.screen("ethereum", "0xOsSanctionedEthAddr")
      assert eth_result.outcome == :block
    end

    test "OpenSanctions upsert is idempotent" do
      stub = fn conn ->
        body = Jason.encode!(@os_btc_entity)

        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.resp(200, body)
      end

      Req.Test.stub(Bank.WalletScreening.Ingestion, stub)
      {:ok, _} = Ingestion.ingest_opensanctions()

      Req.Test.stub(Bank.WalletScreening.Ingestion, stub)
      {:ok, _} = Ingestion.ingest_opensanctions()

      records = WalletScreening.list_records(%{source: "opensanctions"})
      assert length(records) == 1
    end

    test "OpenSanctions handles HTTP error gracefully" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, {:http_error, 500}} = Ingestion.ingest_opensanctions()
    end
  end

  # --- Cross-source provenance tests -----------------------------------

  describe "provenance across sources" do
    test "OFAC and OpenSanctions records for the same address coexist" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        case conn.request_path do
          path when path =~ "sanctions" ->
            entry = %{
              "id" => 88001,
              "id_type" => "Digital Currency Address - ETH",
              "id_number" => "0xSharedAddress",
              "name" => "SHARED ENTITY",
              "programs" => ["SDGT"]
            }

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, Jason.encode!([entry]))

          _ ->
            entity = %{
              "id" => "os-shared-001",
              "schema" => "CryptoWallet",
              "properties" => %{
                "publicKey" => ["0xSharedAddress"],
                "currency" => ["ETH"],
                "topics" => ["sanction"]
              }
            }

            conn
            |> Plug.Conn.put_resp_content_type("application/x-ndjson")
            |> Plug.Conn.resp(200, Jason.encode!(entity))
        end
      end)

      {:ok, ofac_result} = Ingestion.ingest_ofac()
      {:ok, os_result} = Ingestion.ingest_opensanctions()

      assert ofac_result.ingested == 1
      assert os_result.ingested == 1

      screening = WalletScreening.screen("ethereum", "0xSharedAddress")
      assert screening.outcome == :block
      assert length(screening.all_records) == 2

      sources = Enum.map(screening.all_records, & &1.source) |> Enum.sort()
      assert sources == ["ofac", "opensanctions"]
    end

    test "operator can identify which source caused a block" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([@ofac_btc_entry]))
      end)

      {:ok, _} = Ingestion.ingest_ofac()

      screening = WalletScreening.screen("bitcoin", "1TestBtcSanctionedAddr")
      winning = screening.winning_record

      assert winning.source == "ofac"
      assert winning.source_record_id == "sdn-99002"
      assert winning.reason =~ "TEST ENTITY B"
      assert winning.evidence_uri =~ "99002"
      assert winning.metadata["programs"] == ["CYBER2"]
    end
  end
end
