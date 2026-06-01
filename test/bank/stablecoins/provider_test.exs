defmodule Bank.Stablecoins.ProviderTest do
  use ExUnit.Case, async: true

  alias Bank.Stablecoins.{Provider, QuoteRequest, RouteQuote, RouteLeg}

  # In-test fake provider — not a production stub.
  defmodule FakeSwapProvider do
    @behaviour Provider

    @impl true
    def provider_id, do: "fake_swap"

    @impl true
    def quote(%QuoteRequest{route_kind: :swap} = req) do
      leg = %RouteLeg{
        step: 1,
        kind: :swap,
        source_chain: req.source_chain,
        source_asset: req.source_asset,
        source_address: req.source_token.address,
        dest_chain: req.dest_chain,
        dest_asset: req.dest_asset,
        dest_address: req.dest_token.address,
        input_amount: req.amount,
        output_amount: Decimal.sub(req.amount, Decimal.new("0.50")),
        protocol: "fake_dex",
        metadata: %{}
      }

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: :swap,
         legs: [leg],
         input_amount: req.amount,
         output_amount: leg.output_amount,
         quoted_at: DateTime.utc_now(),
         expires_at: DateTime.add(DateTime.utc_now(), 30, :second),
         fees: %{
           gas_fee: Decimal.new("0.10"),
           protocol_fee: Decimal.new("0.30"),
           bridge_fee: nil,
           cryptokorr_fee: Decimal.new("0.10"),
           total_fee: Decimal.new("0.50")
         },
         eta_seconds: 15,
         risk_flags: [],
         explanation: "Direct USDC->USDT swap via fake_dex"
       }}
    end

    def quote(%QuoteRequest{}), do: {:error, :unsupported_route}
  end

  describe "behaviour conformance" do
    test "fake provider implements quote/1 for swap" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "ethereum",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      assert {:ok, %RouteQuote{} = quote} = FakeSwapProvider.quote(req)
      assert quote.provider == "fake_swap"
      assert quote.route_kind == :swap
      assert length(quote.legs) == 1
      assert Decimal.equal?(quote.input_amount, Decimal.new("100"))
      assert quote.fees.total_fee != nil
      assert quote.eta_seconds == 15
      assert quote.expires_at != nil
    end

    test "fake provider returns unsupported_route for bridge" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "base",
          dest_asset: "USDC",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = FakeSwapProvider.quote(req)
    end

    test "provider_id returns stable identifier" do
      assert FakeSwapProvider.provider_id() == "fake_swap"
    end
  end

  describe "RouteQuote shape" do
    test "quote preserves request reference" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "ethereum",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      {:ok, quote} = FakeSwapProvider.quote(req)
      assert quote.request == req
      assert quote.request.source_token.chain == "ethereum"
    end
  end

  describe "RouteLeg shape" do
    test "swap leg has correct structure" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "ethereum",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      {:ok, quote} = FakeSwapProvider.quote(req)
      [leg] = quote.legs

      assert leg.step == 1
      assert leg.kind == :swap
      assert leg.source_chain == "ethereum"
      assert leg.dest_chain == "ethereum"
      assert leg.source_asset == "USDC"
      assert leg.dest_asset == "USDT"
      assert leg.protocol == "fake_dex"
    end
  end
end
