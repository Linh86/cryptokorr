defmodule Bank.Stablecoins.Providers.CircleCCTPTest do
  use ExUnit.Case, async: true

  alias Bank.Stablecoins.{QuoteRequest, RouteQuote, RouteLeg}
  alias Bank.Stablecoins.Providers.CircleCCTP

  # -- Fixtures -------------------------------------------------------------

  defp build_bridge_request(overrides \\ %{}) do
    defaults = %{
      source_chain: "ethereum",
      source_asset: "USDC",
      dest_chain: "base",
      dest_asset: "USDC",
      amount: Decimal.new("1000")
    }

    QuoteRequest.build(Map.merge(defaults, overrides))
  end

  defp build_raw_request(attrs) do
    source_token = attrs[:source_token] || default_source_token()
    dest_token = attrs[:dest_token] || default_dest_token()

    %QuoteRequest{
      source_chain: attrs[:source_chain] || "ethereum",
      source_asset: attrs[:source_asset] || "USDC",
      source_token: source_token,
      dest_chain: attrs[:dest_chain] || "base",
      dest_asset: attrs[:dest_asset] || "USDC",
      dest_token: dest_token,
      amount: attrs[:amount] || Decimal.new("100"),
      route_kind: attrs[:route_kind] || :bridge
    }
  end

  defp default_source_token do
    %{
      chain: "ethereum",
      asset: "USDC",
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      decimals: 6,
      name: "USD Coin",
      standard: :erc20,
      status: :active,
      issuer: "Circle",
      canonical: true,
      variant: :native,
      notes: "Circle native USDC"
    }
  end

  defp default_dest_token do
    %{
      chain: "base",
      asset: "USDC",
      address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      decimals: 6,
      name: "USD Coin",
      standard: :erc20,
      status: :active,
      issuer: "Circle",
      canonical: true,
      variant: :native,
      notes: "Circle native USDC"
    }
  end

  # -- Provider identity ----------------------------------------------------

  describe "provider_id/0" do
    test "returns stable identifier" do
      assert CircleCCTP.provider_id() == "circle_cctp"
    end
  end

  # -- Successful bridge routes ---------------------------------------------

  describe "quote/1 — successful bridge" do
    test "returns normalized RouteQuote for USDC bridge ethereum->base" do
      {:ok, req} = build_bridge_request()

      assert {:ok, %RouteQuote{} = quote} = CircleCCTP.quote(req)
      assert quote.provider == "circle_cctp"
      assert quote.route_kind == :bridge
      assert quote.request == req
      assert Decimal.equal?(quote.input_amount, Decimal.new("1000"))
      assert Decimal.equal?(quote.output_amount, Decimal.new("1000"))
      assert quote.quoted_at != nil
      assert quote.explanation =~ "USDC bridge via Circle CCTP"
      assert quote.explanation =~ "ethereum"
      assert quote.explanation =~ "base"
    end

    test "output equals input (1:1 bridge, no slippage)" do
      {:ok, req} = build_bridge_request(%{amount: Decimal.new("12345.67")})

      {:ok, quote} = CircleCCTP.quote(req)

      assert Decimal.equal?(quote.input_amount, quote.output_amount)
      assert Decimal.equal?(quote.input_amount, Decimal.new("12345.67"))
    end

    test "total_fee is zero" do
      {:ok, req} = build_bridge_request()

      {:ok, quote} = CircleCCTP.quote(req)

      assert Decimal.equal?(quote.fees.total_fee, Decimal.new(0))
      assert quote.fees.bridge_fee == nil
      assert quote.fees.gas_fee == nil
      assert quote.fees.protocol_fee == nil
      assert quote.fees.cryptobank_fee == nil
    end

    test "expires_at is nil (deterministic quote)" do
      {:ok, req} = build_bridge_request()

      {:ok, quote} = CircleCCTP.quote(req)

      assert quote.expires_at == nil
    end

    test "quote has single bridge leg" do
      {:ok, req} = build_bridge_request()

      {:ok, quote} = CircleCCTP.quote(req)
      assert [%RouteLeg{} = leg] = quote.legs
      assert leg.step == 1
      assert leg.kind == :bridge
      assert leg.source_chain == "ethereum"
      assert leg.source_asset == "USDC"
      assert leg.dest_chain == "base"
      assert leg.dest_asset == "USDC"
      assert leg.protocol == "Circle CCTP"
      assert Decimal.equal?(leg.input_amount, Decimal.new("1000"))
      assert Decimal.equal?(leg.output_amount, Decimal.new("1000"))
    end

    test "leg uses registry-resolved addresses" do
      {:ok, req} = build_bridge_request()

      {:ok, quote} = CircleCCTP.quote(req)
      [leg] = quote.legs

      assert leg.source_address == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      assert leg.dest_address == "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    end

    test "leg includes CCTP domain metadata" do
      {:ok, req} = build_bridge_request()

      {:ok, quote} = CircleCCTP.quote(req)
      [leg] = quote.legs

      assert leg.metadata["source_domain"] == 0
      assert leg.metadata["dest_domain"] == 6
    end

    test "leg has ETA based on chain finality" do
      {:ok, req} = build_bridge_request()

      {:ok, quote} = CircleCCTP.quote(req)
      [leg] = quote.legs

      assert leg.eta_seconds > 0
      assert quote.eta_seconds == leg.eta_seconds
    end
  end

  # -- CCTP domain mapping --------------------------------------------------

  describe "quote/1 — CCTP domain mapping" do
    test "ethereum -> base: domains 0 -> 6" do
      {:ok, req} = build_bridge_request(%{source_chain: "ethereum", dest_chain: "base"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["source_domain"] == 0
      assert quote.provider_metadata["dest_domain"] == 6
    end

    test "ethereum -> arbitrum: domains 0 -> 3" do
      {:ok, req} = build_bridge_request(%{source_chain: "ethereum", dest_chain: "arbitrum"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["source_domain"] == 0
      assert quote.provider_metadata["dest_domain"] == 3
    end

    test "ethereum -> optimism: domains 0 -> 2" do
      {:ok, req} = build_bridge_request(%{source_chain: "ethereum", dest_chain: "optimism"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["source_domain"] == 0
      assert quote.provider_metadata["dest_domain"] == 2
    end

    test "ethereum -> polygon: domains 0 -> 7" do
      {:ok, req} = build_bridge_request(%{source_chain: "ethereum", dest_chain: "polygon"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["source_domain"] == 0
      assert quote.provider_metadata["dest_domain"] == 7
    end

    test "ethereum -> solana: domains 0 -> 5" do
      {:ok, req} = build_bridge_request(%{source_chain: "ethereum", dest_chain: "solana"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["source_domain"] == 0
      assert quote.provider_metadata["dest_domain"] == 5
    end

    test "base -> ethereum: domains 6 -> 0" do
      {:ok, req} = build_bridge_request(%{source_chain: "base", dest_chain: "ethereum"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["source_domain"] == 6
      assert quote.provider_metadata["dest_domain"] == 0
    end

    test "arbitrum -> optimism: domains 3 -> 2" do
      {:ok, req} = build_bridge_request(%{source_chain: "arbitrum", dest_chain: "optimism"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["source_domain"] == 3
      assert quote.provider_metadata["dest_domain"] == 2
    end

    test "solana -> base: domains 5 -> 6" do
      {:ok, req} = build_bridge_request(%{source_chain: "solana", dest_chain: "base"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["source_domain"] == 5
      assert quote.provider_metadata["dest_domain"] == 6
    end
  end

  # -- Provider metadata ----------------------------------------------------

  describe "quote/1 — provider metadata" do
    test "includes CCTP protocol version" do
      {:ok, req} = build_bridge_request()

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["protocol_version"] == "v2"
    end

    test "includes attestation URL" do
      {:ok, req} = build_bridge_request()

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["attestation_url"] =~ "circle.com"
    end

    test "includes execution flow description" do
      {:ok, req} = build_bridge_request()

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.provider_metadata["execution_flow"] == "burn → attestation → mint"
    end
  end

  # -- ETA ------------------------------------------------------------------

  describe "quote/1 — ETA" do
    test "ethereum source has longer ETA (L1 finality)" do
      {:ok, req} = build_bridge_request(%{source_chain: "ethereum", dest_chain: "base"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.eta_seconds >= 780
    end

    test "L2 to L2 has shorter ETA" do
      {:ok, req} = build_bridge_request(%{source_chain: "base", dest_chain: "arbitrum"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.eta_seconds <= 300
    end

    test "solana to base has moderate ETA" do
      {:ok, req} = build_bridge_request(%{source_chain: "solana", dest_chain: "base"})

      {:ok, quote} = CircleCCTP.quote(req)
      assert quote.eta_seconds >= 60
    end
  end

  # -- Unsupported routes ---------------------------------------------------

  describe "quote/1 — unsupported routes" do
    test "rejects same-chain swap (USDC->USDT)" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "ethereum",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = CircleCCTP.quote(req)
    end

    test "rejects swap_plus_bridge (different chain + different asset)" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "base",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = CircleCCTP.quote(req)
    end

    test "rejects USDT bridge (CCTP only supports USDC)" do
      req =
        build_raw_request(%{
          source_asset: "USDT",
          dest_asset: "USDT",
          route_kind: :bridge,
          source_token: %{default_source_token() | asset: "USDT"},
          dest_token: %{default_dest_token() | asset: "USDT"}
        })

      assert {:error, :unsupported_route} = CircleCCTP.quote(req)
    end

    test "rejects non-canonical source token" do
      req =
        build_raw_request(%{
          source_token: %{default_source_token() | canonical: false, variant: :bridged}
        })

      assert {:error, :unsupported_route} = CircleCCTP.quote(req)
    end

    test "rejects approval_only source token" do
      req =
        build_raw_request(%{
          source_token: %{default_source_token() | status: :approval_only, canonical: false}
        })

      assert {:error, :unsupported_route} = CircleCCTP.quote(req)
    end

    test "rejects blocked source token" do
      req =
        build_raw_request(%{
          source_token: %{default_source_token() | status: :blocked}
        })

      assert {:error, :unsupported_route} = CircleCCTP.quote(req)
    end

    test "rejects non-canonical dest token" do
      req =
        build_raw_request(%{
          dest_token: %{default_dest_token() | canonical: false, variant: :bridged}
        })

      assert {:error, :unsupported_route} = CircleCCTP.quote(req)
    end

    test "rejects approval_only dest token" do
      req =
        build_raw_request(%{
          dest_token: %{default_dest_token() | status: :approval_only, canonical: false}
        })

      assert {:error, :unsupported_route} = CircleCCTP.quote(req)
    end

    test "rejects blocked dest token" do
      req =
        build_raw_request(%{
          dest_token: %{default_dest_token() | status: :blocked}
        })

      assert {:error, :unsupported_route} = CircleCCTP.quote(req)
    end
  end

  # -- Cross-provider comparability -----------------------------------------

  describe "cross-provider comparability" do
    test "quote output has same normalized shape as swap providers" do
      {:ok, req} = build_bridge_request()

      {:ok, quote} = CircleCCTP.quote(req)

      assert %RouteQuote{
               provider: "circle_cctp",
               route_kind: :bridge,
               legs: [%RouteLeg{step: 1, kind: :bridge}],
               fees: %{total_fee: %Decimal{}}
             } = quote

      assert quote.input_amount != nil
      assert quote.output_amount != nil
      assert quote.quoted_at != nil
    end
  end
end
