defmodule Bank.Stablecoins.Providers.ZeroXTest do
  use ExUnit.Case, async: false

  alias Bank.Stablecoins.{QuoteRequest, RouteQuote, RouteLeg}
  alias Bank.Stablecoins.Providers.ZeroX

  @taker_address "0x0000000000000000000000000000000000000abc"

  # -- Fixtures -------------------------------------------------------------

  defp build_swap_request(overrides \\ %{}) do
    defaults = %{
      source_chain: "ethereum",
      source_asset: "USDC",
      dest_chain: "ethereum",
      dest_asset: "USDT",
      amount: Decimal.new("100"),
      metadata: %{taker_address: @taker_address}
    }

    QuoteRequest.build(Map.merge(defaults, overrides))
  end

  defp success_body(opts \\ []) do
    sell = Keyword.get(opts, :sell_amount, "100000000")
    buy = Keyword.get(opts, :buy_amount, "99500000")

    %{
      "sellAmount" => sell,
      "buyAmount" => buy,
      "estimatedGas" => "250000",
      "gasPrice" => "30000000000",
      "totalNetworkFee" => "7500000000000000",
      "allowanceTarget" => "0x0000000000000000000000000000000000000001",
      "route" => %{
        "fills" => [
          %{"source" => "Uniswap_V3", "proportionBps" => "10000"}
        ]
      },
      "sources" => [
        %{"name" => "Uniswap_V3", "proportion" => "1"}
      ],
      "fees" => %{
        "zeroExFee" => nil
      },
      "transaction" => %{
        "to" => "0xdef1c0ded9bec7f1a1670819833240f027b25eff",
        "data" => "0xabcdef",
        "value" => "0",
        "gas" => "250000",
        "gasPrice" => "30000000000"
      },
      "permit2" => %{
        "eip712" => %{"domain" => %{}, "types" => %{}, "value" => %{}}
      },
      "minBuyAmount" => "98500000"
    }
  end

  # -- Provider identity ----------------------------------------------------

  describe "provider_id/0" do
    test "returns stable identifier" do
      assert ZeroX.provider_id() == "zerox"
    end
  end

  # -- Successful quotes ----------------------------------------------------

  describe "quote/1 — successful swap" do
    test "returns normalized RouteQuote for USDC->USDT on ethereum" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{} = quote} = ZeroX.quote(req)
      assert quote.provider == "zerox"
      assert quote.route_kind == :swap
      assert quote.request == req
      assert Decimal.equal?(quote.input_amount, Decimal.new("100"))
      assert Decimal.equal?(quote.output_amount, Decimal.new("99.5"))
      assert quote.quoted_at != nil
      assert quote.expires_at != nil
      assert quote.explanation =~ "USDC->USDT"
      assert quote.explanation =~ "ethereum"
    end

    test "quote has correct fee breakdown" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = ZeroX.quote(req)

      assert Decimal.equal?(quote.fees.total_fee, Decimal.new("0.5"))
      assert quote.fees.bridge_fee == nil
      assert quote.fees.cryptokorr_fee == nil
    end

    test "quote has single swap leg with correct structure" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = ZeroX.quote(req)
      assert [%RouteLeg{} = leg] = quote.legs
      assert leg.step == 1
      assert leg.kind == :swap
      assert leg.source_chain == "ethereum"
      assert leg.source_asset == "USDC"
      assert leg.dest_chain == "ethereum"
      assert leg.dest_asset == "USDT"
      assert leg.protocol == "Uniswap_V3"
      assert Decimal.equal?(leg.input_amount, Decimal.new("100"))
      assert Decimal.equal?(leg.output_amount, Decimal.new("99.5"))
    end

    test "preserves provider execution metadata" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = ZeroX.quote(req)

      assert %{"transaction" => %{"to" => _}} = quote.provider_metadata
      assert %{"permit2" => %{"eip712" => _}} = quote.provider_metadata
      assert %{"minBuyAmount" => _} = quote.provider_metadata
      assert %{"totalNetworkFee" => _} = quote.provider_metadata
    end

    test "works for USDT->USDC on ethereum" do
      {:ok, req} =
        build_swap_request(%{
          source_asset: "USDT",
          dest_asset: "USDC"
        })

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{} = quote} = ZeroX.quote(req)
      assert quote.explanation =~ "USDT->USDC"
    end

    test "works for swap on base" do
      {:ok, req} =
        build_swap_request(%{
          source_chain: "base",
          dest_chain: "base"
        })

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{}} = ZeroX.quote(req)
    end

    test "works for swap on arbitrum" do
      {:ok, req} =
        build_swap_request(%{
          source_chain: "arbitrum",
          dest_chain: "arbitrum"
        })

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{}} = ZeroX.quote(req)
    end

    test "works for swap on optimism" do
      {:ok, req} =
        build_swap_request(%{
          source_chain: "optimism",
          dest_chain: "optimism"
        })

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{}} = ZeroX.quote(req)
    end

    test "works for swap on polygon" do
      {:ok, req} =
        build_swap_request(%{
          source_chain: "polygon",
          dest_chain: "polygon"
        })

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{}} = ZeroX.quote(req)
    end

    test "sends correct query params to 0x API" do
      {:ok, req} = build_swap_request(%{amount: Decimal.new("250.50"), slippage_bps: 75})

      Req.Test.stub(ZeroX, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        params = conn.query_params

        assert params["chainId"] == "1"
        assert params["sellToken"] == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        assert params["buyToken"] == "0xdAC17F958D2ee523a2206206994597C13D831ec7"
        assert params["sellAmount"] == "250500000"
        assert params["taker"] == @taker_address
        assert params["slippageBps"] == "75"

        Req.Test.json(conn, success_body(sell_amount: "250500000", buy_amount: "249500000"))
      end)

      assert {:ok, _quote} = ZeroX.quote(req)
    end

    test "sends 0x-api-key header" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        headers = Map.new(conn.req_headers)
        api_key = Map.fetch!(headers, "0x-api-key")
        version = Map.fetch!(headers, "0x-version")

        assert api_key == "test-0x-api-key"
        assert version == "v2"

        Req.Test.json(conn, success_body())
      end)

      assert {:ok, _quote} = ZeroX.quote(req)
    end

    test "handles 0x protocol fee in response" do
      {:ok, req} = build_swap_request()

      body =
        success_body()
        |> put_in(["fees", "zeroExFee"], %{
          "amount" => "100000",
          "token" => "0xdAC17F958D2ee523a2206206994597C13D831ec7",
          "type" => "volume"
        })

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, body)
      end)

      {:ok, quote} = ZeroX.quote(req)
      assert Decimal.equal?(quote.fees.protocol_fee, Decimal.new("0.1"))
    end
  end

  # -- Unsupported routes ---------------------------------------------------

  describe "quote/1 — unsupported routes" do
    test "rejects bridge routes" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "base",
          dest_asset: "USDC",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = ZeroX.quote(req)
    end

    test "rejects swap_plus_bridge routes" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "base",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = ZeroX.quote(req)
    end

    test "rejects solana (non-EVM) chain" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "solana",
          source_asset: "USDC",
          dest_chain: "solana",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = ZeroX.quote(req)
    end
  end

  # -- Error classification -------------------------------------------------

  describe "quote/1 — error classification" do
    test "missing taker address returns provider_error before HTTP" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "ethereum",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      assert {:error, {:provider_error, %{reason: "missing_taker"}}} = ZeroX.quote(req)
    end

    test "missing API key returns provider_error before HTTP" do
      previous = Application.get_env(:bank, ZeroX, [])

      on_exit(fn ->
        Application.put_env(:bank, ZeroX, previous)
      end)

      Application.put_env(:bank, ZeroX, Keyword.delete(previous, :api_key))

      {:ok, req} = build_swap_request()

      assert {:error, {:provider_error, %{reason: "missing_api_key"}}} = ZeroX.quote(req)
    end

    test "429 maps to :rate_limited" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Plug.Conn.send_resp(conn, 429, "")
      end)

      assert {:error, :rate_limited} = ZeroX.quote(req)
    end

    test "500 maps to :provider_unavailable" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn |> Plug.Conn.put_status(500), %{"error" => "internal"})
      end)

      assert {:error, :provider_unavailable} = ZeroX.quote(req)
    end

    test "503 maps to :provider_unavailable" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Plug.Conn.send_resp(conn, 503, "")
      end)

      assert {:error, :provider_unavailable} = ZeroX.quote(req)
    end

    test "400 with INSUFFICIENT_ASSET_LIQUIDITY maps to :no_route_found" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(400),
          %{"reason" => "INSUFFICIENT_ASSET_LIQUIDITY", "code" => 100}
        )
      end)

      assert {:error, :no_route_found} = ZeroX.quote(req)
    end

    test "200 with liquidityAvailable=false maps to :no_route_found" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, %{"liquidityAvailable" => false})
      end)

      assert {:error, :no_route_found} = ZeroX.quote(req)
    end

    test "400 with validation error maps to provider_error" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(400),
          %{
            "reason" => "Validation Failed",
            "validationErrors" => [%{"field" => "sellAmount", "reason" => "too_small"}]
          }
        )
      end)

      assert {:error, {:provider_error, %{status: 400, body: _}}} = ZeroX.quote(req)
    end

    test "malformed 200 body maps to provider_error" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, %{"unexpected" => "shape"})
      end)

      assert {:error, {:provider_error, %{reason: "malformed_response"}}} = ZeroX.quote(req)
    end

    test "transport error maps to :provider_unavailable" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :provider_unavailable} = ZeroX.quote(req)
    end
  end

  # -- Leg metadata ---------------------------------------------------------

  describe "leg metadata" do
    test "includes estimatedGas and allowanceTarget when present" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(ZeroX, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = ZeroX.quote(req)
      [leg] = quote.legs

      assert leg.metadata["estimatedGas"] == "250000"
      assert leg.metadata["allowanceTarget"] == "0x0000000000000000000000000000000000000001"
    end
  end
end
