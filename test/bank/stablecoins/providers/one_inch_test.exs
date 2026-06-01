defmodule Bank.Stablecoins.Providers.OneInchTest do
  use ExUnit.Case, async: false

  alias Bank.Stablecoins.{QuoteRequest, RouteQuote, RouteLeg}
  alias Bank.Stablecoins.Providers.OneInch

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
    dst = Keyword.get(opts, :dst_amount, "99500000")

    %{
      "dstAmount" => dst,
      "srcToken" => %{
        "address" => "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "symbol" => "USDC",
        "name" => "USD Coin",
        "decimals" => 6
      },
      "dstToken" => %{
        "address" => "0xdAC17F958D2ee523a2206206994597C13D831ec7",
        "symbol" => "USDT",
        "name" => "Tether USD",
        "decimals" => 6
      },
      "protocols" => [
        %{
          "token" => "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          "hops" => [
            %{
              "part" => 100,
              "dst" => "0xdAC17F958D2ee523a2206206994597C13D831ec7",
              "fromTokenId" => 0,
              "toTokenId" => 1,
              "protocols" => [
                %{"name" => "UNISWAP_V3", "part" => 100}
              ]
            }
          ]
        }
      ],
      "tx" => %{
        "from" => @taker_address,
        "to" => "0x111111125421ca6dc452d289314280a0f8842a65",
        "data" => "0x07ed2379abcdef",
        "value" => "0",
        "gas" => 250_000,
        "gasPrice" => "30000000000"
      }
    }
  end

  # -- Provider identity ----------------------------------------------------

  describe "provider_id/0" do
    test "returns stable identifier" do
      assert OneInch.provider_id() == "oneinch"
    end
  end

  # -- Successful quotes ----------------------------------------------------

  describe "quote/1 — successful swap" do
    test "returns normalized RouteQuote for USDC->USDT on ethereum" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{} = quote} = OneInch.quote(req)
      assert quote.provider == "oneinch"
      assert quote.route_kind == :swap
      assert quote.request == req
      assert Decimal.equal?(quote.input_amount, Decimal.new("100"))
      assert Decimal.equal?(quote.output_amount, Decimal.new("99.5"))
      assert quote.quoted_at != nil
      assert quote.expires_at != nil
      assert quote.explanation =~ "USDC->USDT"
      assert quote.explanation =~ "1inch"
      assert quote.explanation =~ "ethereum"
    end

    test "quote has correct fee breakdown" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = OneInch.quote(req)

      assert Decimal.equal?(quote.fees.total_fee, Decimal.new("0.5"))
      assert quote.fees.bridge_fee == nil
      assert quote.fees.cryptokorr_fee == nil
      assert quote.fees.gas_fee == nil
      assert quote.fees.protocol_fee == nil
    end

    test "quote has single swap leg with correct structure" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = OneInch.quote(req)
      assert [%RouteLeg{} = leg] = quote.legs
      assert leg.step == 1
      assert leg.kind == :swap
      assert leg.source_chain == "ethereum"
      assert leg.source_asset == "USDC"
      assert leg.dest_chain == "ethereum"
      assert leg.dest_asset == "USDT"
      assert leg.protocol == "UNISWAP_V3"
      assert Decimal.equal?(leg.input_amount, Decimal.new("100"))
      assert Decimal.equal?(leg.output_amount, Decimal.new("99.5"))
    end

    test "preserves provider execution metadata" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = OneInch.quote(req)

      assert %{"tx" => %{"to" => _, "data" => _, "from" => _}} = quote.provider_metadata
      assert %{"protocols" => [_ | _]} = quote.provider_metadata
    end

    test "works for USDT->USDC on ethereum" do
      {:ok, req} =
        build_swap_request(%{
          source_asset: "USDT",
          dest_asset: "USDC"
        })

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{} = quote} = OneInch.quote(req)
      assert quote.explanation =~ "USDT->USDC"
    end

    test "works for swap on base" do
      {:ok, req} =
        build_swap_request(%{
          source_chain: "base",
          dest_chain: "base"
        })

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{}} = OneInch.quote(req)
    end

    test "works for swap on arbitrum" do
      {:ok, req} =
        build_swap_request(%{
          source_chain: "arbitrum",
          dest_chain: "arbitrum"
        })

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{}} = OneInch.quote(req)
    end

    test "works for swap on optimism" do
      {:ok, req} =
        build_swap_request(%{
          source_chain: "optimism",
          dest_chain: "optimism"
        })

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{}} = OneInch.quote(req)
    end

    test "works for swap on polygon" do
      {:ok, req} =
        build_swap_request(%{
          source_chain: "polygon",
          dest_chain: "polygon"
        })

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{}} = OneInch.quote(req)
    end

    test "sends correct request params and URL path" do
      {:ok, req} = build_swap_request(%{amount: Decimal.new("250.50"), slippage_bps: 50})

      Req.Test.stub(OneInch, fn conn ->
        assert conn.request_path == "/swap/v6.1/1/swap"

        conn = Plug.Conn.fetch_query_params(conn)
        params = conn.query_params

        assert params["src"] == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        assert params["dst"] == "0xdAC17F958D2ee523a2206206994597C13D831ec7"
        assert params["amount"] == "250500000"
        assert params["from"] == @taker_address
        assert params["disableEstimate"] == "true"
        assert params["slippage"] == "0.5"

        Req.Test.json(conn, success_body(dst_amount: "249500000"))
      end)

      assert {:ok, _quote} = OneInch.quote(req)
    end

    test "sends correct chain-specific URL path for base" do
      {:ok, req} = build_swap_request(%{source_chain: "base", dest_chain: "base"})

      Req.Test.stub(OneInch, fn conn ->
        assert conn.request_path == "/swap/v6.1/8453/swap"
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, _} = OneInch.quote(req)
    end

    test "sends Bearer authorization header" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        headers = Map.new(conn.req_headers)
        assert headers["authorization"] == "Bearer test-1inch-api-key"

        Req.Test.json(conn, success_body())
      end)

      assert {:ok, _quote} = OneInch.quote(req)
    end

    test "leg metadata includes gas info from tx" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = OneInch.quote(req)
      [leg] = quote.legs

      assert leg.metadata["gas"] == 250_000
      assert leg.metadata["gasPrice"] == "30000000000"
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
          amount: Decimal.new("100"),
          metadata: %{taker_address: @taker_address}
        })

      assert {:error, :unsupported_route} = OneInch.quote(req)
    end

    test "rejects swap_plus_bridge routes" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "base",
          dest_asset: "USDT",
          amount: Decimal.new("100"),
          metadata: %{taker_address: @taker_address}
        })

      assert {:error, :unsupported_route} = OneInch.quote(req)
    end

    test "rejects solana (non-EVM) chain" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "solana",
          source_asset: "USDC",
          dest_chain: "solana",
          dest_asset: "USDT",
          amount: Decimal.new("100"),
          metadata: %{taker_address: @taker_address}
        })

      assert {:error, :unsupported_route} = OneInch.quote(req)
    end
  end

  # -- Error classification -------------------------------------------------

  describe "quote/1 — error classification" do
    test "429 maps to :rate_limited" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Plug.Conn.send_resp(conn, 429, "")
      end)

      assert {:error, :rate_limited} = OneInch.quote(req)
    end

    test "500 maps to :provider_unavailable" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn |> Plug.Conn.put_status(500), %{"error" => "internal"})
      end)

      assert {:error, :provider_unavailable} = OneInch.quote(req)
    end

    test "503 maps to :provider_unavailable" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Plug.Conn.send_resp(conn, 503, "")
      end)

      assert {:error, :provider_unavailable} = OneInch.quote(req)
    end

    test "400 with insufficient liquidity maps to :no_route_found" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(400),
          %{
            "statusCode" => 400,
            "error" => "Bad Request",
            "description" => "insufficient liquidity"
          }
        )
      end)

      assert {:error, :no_route_found} = OneInch.quote(req)
    end

    test "400 with Cannot estimate maps to :no_route_found" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(400),
          %{
            "statusCode" => 400,
            "error" => "Bad Request",
            "description" => "Cannot estimate. Don't forget about miner fee."
          }
        )
      end)

      assert {:error, :no_route_found} = OneInch.quote(req)
    end

    test "400 with not enough allowance maps to provider_error" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(400),
          %{
            "statusCode" => 400,
            "error" => "Not enough allowance",
            "description" => "Details"
          }
        )
      end)

      assert {:error, {:provider_error, %{status: 400, body: _}}} = OneInch.quote(req)
    end

    test "400 with unrecognized error maps to provider_error" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(400),
          %{
            "statusCode" => 400,
            "error" => "Validation error",
            "description" => "Invalid src token address"
          }
        )
      end)

      assert {:error, {:provider_error, %{status: 400, body: _}}} = OneInch.quote(req)
    end

    test "malformed 200 body maps to provider_error" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, %{"unexpected" => "shape"})
      end)

      assert {:error, {:provider_error, %{reason: "malformed_response"}}} = OneInch.quote(req)
    end

    test "transport error maps to :provider_unavailable" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :provider_unavailable} = OneInch.quote(req)
    end
  end

  # -- Missing config -------------------------------------------------------

  describe "quote/1 — missing config" do
    test "missing api_key returns provider_error" do
      original = Application.get_env(:bank, OneInch)

      Application.put_env(:bank, OneInch,
        base_url: "http://oneinch.test",
        api_key: nil,
        req_options: Keyword.get(original, :req_options, [])
      )

      {:ok, req} = build_swap_request()
      assert {:error, {:provider_error, %{reason: "missing_api_key"}}} = OneInch.quote(req)
    after
      Application.put_env(:bank, OneInch,
        base_url: "http://oneinch.test",
        api_key: "test-1inch-api-key",
        req_options: [plug: {Req.Test, OneInch}]
      )
    end

    test "missing from address returns provider_error" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "ethereum",
          dest_asset: "USDT",
          amount: Decimal.new("100"),
          metadata: %{}
        })

      assert {:error, {:provider_error, %{reason: "missing_from_address"}}} = OneInch.quote(req)
    end
  end

  # -- Output comparable to 0x ----------------------------------------------

  describe "cross-provider comparability" do
    test "quote output has same normalized shape as ZeroX" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(OneInch, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = OneInch.quote(req)

      assert %RouteQuote{
               provider: "oneinch",
               route_kind: :swap,
               legs: [%RouteLeg{step: 1, kind: :swap}],
               fees: %{total_fee: %Decimal{}}
             } = quote

      assert quote.input_amount != nil
      assert quote.output_amount != nil
      assert quote.quoted_at != nil
    end
  end
end
