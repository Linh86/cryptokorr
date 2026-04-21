defmodule Bank.WalletScreening.GraphSenseIngestionTest do
  use Bank.DataCase, async: true

  alias Bank.WalletScreening
  alias Bank.WalletScreening.Ingestion

  @tagpack %{
    "title" => "Exchange Tags",
    "creator" => "graphsense-test",
    "tags" => [
      %{
        "address" => "0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8",
        "currency" => "ETH",
        "label" => "Binance Hot Wallet",
        "source" => "https://etherscan.io/address/0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8",
        "category" => "exchange",
        "lastmod" => "2025-06-01"
      },
      %{
        "address" => "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
        "currency" => "BTC",
        "label" => "Satoshi Genesis",
        "category" => "mining",
        "lastmod" => "2009-01-03"
      },
      %{
        "address" => "DogeUnsupported",
        "currency" => "DOGE",
        "label" => "Unsupported Chain"
      }
    ]
  }

  @bare_tags [
    %{
      "address" => "0xBareTags001",
      "currency" => "ETH",
      "label" => "Bare Tags DeFi",
      "category" => "defi"
    }
  ]

  describe "ingest_graphsense/1" do
    test "ingests GraphSense tagpack as context records" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@tagpack))
      end)

      assert {:ok, result} = Ingestion.ingest_graphsense()

      assert result.source == "graphsense"
      assert result.ingested == 2
      assert result.skipped == 1

      records = WalletScreening.list_records(%{source: "graphsense"})
      assert length(records) == 2
      assert Enum.all?(records, &(&1.control_tier == :context))
    end

    test "GraphSense records produce :clean screening outcome (context only)" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@tagpack))
      end)

      {:ok, _} = Ingestion.ingest_graphsense()

      result = WalletScreening.screen("ethereum", "0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8")
      assert result.outcome == :clean
      assert length(result.context_records) == 1
      assert result.winning_record.source == "graphsense"
      assert result.winning_record.reason =~ "Binance Hot Wallet"
    end

    test "GraphSense context does not override sanctions hard_block" do
      ofac_attrs = %{
        chain: "ethereum",
        address: "0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8",
        control_tier: :hard_block,
        source: "ofac",
        source_record_id: "sdn-shared-001",
        category: "sanctions",
        reason: "OFAC sanctioned"
      }

      {:ok, _} = WalletScreening.upsert_record(ofac_attrs)

      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@tagpack))
      end)

      {:ok, _} = Ingestion.ingest_graphsense()

      result = WalletScreening.screen("ethereum", "0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8")
      assert result.outcome == :block
      assert result.winning_record.control_tier == :hard_block
      assert length(result.all_records) == 2
      assert length(result.context_records) == 1
    end

    test "GraphSense context does not override scam challenge" do
      scam_attrs = %{
        chain: "ethereum",
        address: "0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8",
        control_tier: :challenge,
        source: "scamsniffer",
        source_record_id: "ss-shared-001",
        category: "phishing",
        reason: "known phishing"
      }

      {:ok, _} = WalletScreening.upsert_record(scam_attrs)

      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@tagpack))
      end)

      {:ok, _} = Ingestion.ingest_graphsense()

      result = WalletScreening.screen("ethereum", "0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8")
      assert result.outcome == :challenge
      assert result.winning_record.control_tier == :challenge
      assert length(result.context_records) == 1
    end

    test "handles bare tag array" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@bare_tags))
      end)

      assert {:ok, %{ingested: 1}} = Ingestion.ingest_graphsense()
    end

    test "upsert is idempotent" do
      stub = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@tagpack))
      end

      Req.Test.stub(Bank.WalletScreening.Ingestion, stub)
      {:ok, _} = Ingestion.ingest_graphsense()

      Req.Test.stub(Bank.WalletScreening.Ingestion, stub)
      {:ok, _} = Ingestion.ingest_graphsense()

      records = WalletScreening.list_records(%{source: "graphsense"})
      assert length(records) == 2
    end

    test "handles HTTP error" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        Plug.Conn.resp(conn, 503, "Service Unavailable")
      end)

      assert {:error, {:http_error, 503}} = Ingestion.ingest_graphsense()
    end

    test "preserves provenance for operator identification" do
      Req.Test.stub(Bank.WalletScreening.Ingestion, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@tagpack))
      end)

      {:ok, _} = Ingestion.ingest_graphsense()

      result = WalletScreening.screen("bitcoin", "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
      winning = result.winning_record

      assert winning.source == "graphsense"
      assert winning.category == "mining"
      assert winning.reason =~ "Satoshi Genesis"
      assert winning.metadata["label"] == "Satoshi Genesis"
      assert winning.metadata["category"] == "mining"
    end
  end
end
