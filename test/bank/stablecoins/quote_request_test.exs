defmodule Bank.Stablecoins.QuoteRequestTest do
  use ExUnit.Case, async: true

  alias Bank.Stablecoins.QuoteRequest

  describe "build/1 — same-chain swap" do
    test "builds valid USDC->USDT swap on ethereum" do
      assert {:ok, req} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "ethereum",
                 dest_asset: "USDT",
                 amount: Decimal.new("100")
               })

      assert req.route_kind == :swap
      assert req.source_chain == "ethereum"
      assert req.source_asset == "USDC"
      assert req.dest_chain == "ethereum"
      assert req.dest_asset == "USDT"
      assert req.source_token.address == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      assert req.dest_token.asset == "USDT"
      assert Decimal.equal?(req.amount, Decimal.new("100"))
    end

    test "builds swap on solana" do
      assert {:ok, req} =
               QuoteRequest.build(%{
                 source_chain: "solana",
                 source_asset: "USDC",
                 dest_chain: "solana",
                 dest_asset: "USDT",
                 amount: Decimal.new("50")
               })

      assert req.route_kind == :swap
      assert req.source_token.standard == :spl_token
      assert req.dest_token.standard == :spl_token
    end
  end

  describe "build/1 — cross-chain bridge" do
    test "builds valid USDC bridge ethereum->base" do
      assert {:ok, req} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "base",
                 dest_asset: "USDC",
                 amount: Decimal.new("1000")
               })

      assert req.route_kind == :bridge
      assert req.source_chain == "ethereum"
      assert req.dest_chain == "base"
    end

    test "builds USDC bridge to solana" do
      assert {:ok, req} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "solana",
                 dest_asset: "USDC",
                 amount: Decimal.new("500")
               })

      assert req.route_kind == :bridge
      assert req.dest_token.standard == :spl_token
    end
  end

  describe "build/1 — swap plus bridge" do
    test "builds swap+bridge for USDC->USDT cross-chain" do
      assert {:ok, req} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "base",
                 dest_asset: "USDT",
                 amount: Decimal.new("200")
               })

      assert req.route_kind == :swap_plus_bridge
    end
  end

  describe "build/1 — token metadata from registry" do
    test "source token has full registry metadata" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "base",
          source_asset: "USDC",
          dest_chain: "base",
          dest_asset: "USDT",
          amount: Decimal.new("10")
        })

      assert req.source_token.decimals == 6
      assert req.source_token.issuer == "Circle"
      assert req.source_token.chain == "base"
    end
  end

  describe "build/1 — validation errors" do
    test "rejects unsupported source chain" do
      assert {:error, :unsupported_source_chain} =
               QuoteRequest.build(%{
                 source_chain: "bsc",
                 source_asset: "USDC",
                 dest_chain: "ethereum",
                 dest_asset: "USDT",
                 amount: Decimal.new("100")
               })
    end

    test "rejects unsupported source asset" do
      assert {:error, :unsupported_source_asset} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "DAI",
                 dest_chain: "ethereum",
                 dest_asset: "USDT",
                 amount: Decimal.new("100")
               })
    end

    test "rejects unsupported dest chain" do
      assert {:error, :unsupported_dest_chain} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "bsc",
                 dest_asset: "USDC",
                 amount: Decimal.new("100")
               })
    end

    test "rejects unsupported dest asset" do
      assert {:error, :unsupported_dest_asset} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "ethereum",
                 dest_asset: "WETH",
                 amount: Decimal.new("100")
               })
    end

    test "rejects zero amount" do
      assert {:error, :invalid_amount} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "ethereum",
                 dest_asset: "USDT",
                 amount: Decimal.new("0")
               })
    end

    test "rejects negative amount" do
      assert {:error, :invalid_amount} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "ethereum",
                 dest_asset: "USDT",
                 amount: Decimal.new("-10")
               })
    end

    test "rejects same source and dest token" do
      assert {:error, :same_token} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "ethereum",
                 dest_asset: "USDC",
                 amount: Decimal.new("100")
               })
    end

    test "accepts string amount" do
      assert {:ok, req} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "ethereum",
                 dest_asset: "USDT",
                 amount: "100.50"
               })

      assert Decimal.equal?(req.amount, Decimal.new("100.50"))
    end

    test "preserves slippage_bps" do
      assert {:ok, req} =
               QuoteRequest.build(%{
                 source_chain: "ethereum",
                 source_asset: "USDC",
                 dest_chain: "ethereum",
                 dest_asset: "USDT",
                 amount: Decimal.new("100"),
                 slippage_bps: 50
               })

      assert req.slippage_bps == 50
    end
  end
end
