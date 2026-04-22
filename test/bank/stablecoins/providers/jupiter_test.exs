defmodule Bank.Stablecoins.Providers.JupiterTest do
  use ExUnit.Case, async: false

  alias Bank.Stablecoins.{QuoteRequest, RouteQuote, RouteLeg}
  alias Bank.Stablecoins.Providers.Jupiter

  @usdc_mint "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  @usdt_mint "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"

  # -- Fixtures -------------------------------------------------------------

  defp build_swap_request(overrides \\ %{}) do
    defaults = %{
      source_chain: "solana",
      source_asset: "USDC",
      dest_chain: "solana",
      dest_asset: "USDT",
      amount: Decimal.new("100")
    }

    QuoteRequest.build(Map.merge(defaults, overrides))
  end

  defp success_body(opts \\ []) do
    in_amount = Keyword.get(opts, :in_amount, "100000000")
    out_amount = Keyword.get(opts, :out_amount, "99500000")

    %{
      "inputMint" => @usdc_mint,
      "inAmount" => in_amount,
      "outputMint" => @usdt_mint,
      "outAmount" => out_amount,
      "otherAmountThreshold" => "98500000",
      "swapMode" => "ExactIn",
      "slippageBps" => 50,
      "platformFee" => nil,
      "priceImpactPct" => "0.001",
      "routePlan" => [
        %{
          "swapInfo" => %{
            "ammKey" => "HcoJfuPBgt3WPRMEUFo2sF1hSqGsqo65c9m3u6GBpETk",
            "label" => "Raydium CLMM",
            "inputMint" => @usdc_mint,
            "outputMint" => @usdt_mint,
            "inAmount" => in_amount,
            "outAmount" => out_amount,
            "feeAmount" => "50000",
            "feeMint" => @usdc_mint
          },
          "percent" => 100
        }
      ],
      "contextSlot" => 250_000_000,
      "timeTaken" => 0.42
    }
  end

  # -- Provider identity ----------------------------------------------------

  describe "provider_id/0" do
    test "returns stable identifier" do
      assert Jupiter.provider_id() == "jupiter"
    end
  end

  # -- Successful quotes ----------------------------------------------------

  describe "quote/1 — successful swap" do
    test "returns normalized RouteQuote for USDC->USDT on solana" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{} = quote} = Jupiter.quote(req)
      assert quote.provider == "jupiter"
      assert quote.route_kind == :swap
      assert quote.request == req
      assert Decimal.equal?(quote.input_amount, Decimal.new("100"))
      assert Decimal.equal?(quote.output_amount, Decimal.new("99.5"))
      assert quote.quoted_at != nil
      assert quote.expires_at != nil
      assert quote.explanation =~ "USDC->USDT"
      assert quote.explanation =~ "Jupiter"
      assert quote.explanation =~ "solana"
    end

    test "quote has correct fee breakdown" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = Jupiter.quote(req)

      assert Decimal.equal?(quote.fees.total_fee, Decimal.new("0.5"))
      assert quote.fees.bridge_fee == nil
      assert quote.fees.cryptobank_fee == nil
      assert quote.fees.gas_fee == nil
    end

    test "quote has single swap leg with correct structure" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = Jupiter.quote(req)
      assert [%RouteLeg{} = leg] = quote.legs
      assert leg.step == 1
      assert leg.kind == :swap
      assert leg.source_chain == "solana"
      assert leg.source_asset == "USDC"
      assert leg.dest_chain == "solana"
      assert leg.dest_asset == "USDT"
      assert leg.source_address == @usdc_mint
      assert leg.dest_address == @usdt_mint
      assert leg.protocol == "Raydium CLMM"
      assert Decimal.equal?(leg.input_amount, Decimal.new("100"))
      assert Decimal.equal?(leg.output_amount, Decimal.new("99.5"))
    end

    test "uses Solana SPL token mint addresses from registry" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        params = conn.query_params

        assert params["inputMint"] == @usdc_mint
        assert params["outputMint"] == @usdt_mint

        Req.Test.json(conn, success_body())
      end)

      assert {:ok, _} = Jupiter.quote(req)
    end

    test "preserves full quote response in provider_metadata" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = Jupiter.quote(req)

      assert %{"quoteResponse" => qr} = quote.provider_metadata
      assert qr["inputMint"] == @usdc_mint
      assert qr["outputMint"] == @usdt_mint
      assert is_list(qr["routePlan"])
      assert qr["swapMode"] == "ExactIn"
    end

    test "works for USDT->USDC on solana" do
      {:ok, req} =
        build_swap_request(%{
          source_asset: "USDT",
          dest_asset: "USDC"
        })

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %RouteQuote{} = quote} = Jupiter.quote(req)
      assert quote.explanation =~ "USDT->USDC"
    end

    test "sends correct query params to Jupiter API" do
      {:ok, req} = build_swap_request(%{amount: Decimal.new("250.50"), slippage_bps: 75})

      Req.Test.stub(Jupiter, fn conn ->
        assert conn.request_path == "/swap/v1/quote"

        conn = Plug.Conn.fetch_query_params(conn)
        params = conn.query_params

        assert params["inputMint"] == @usdc_mint
        assert params["outputMint"] == @usdt_mint
        assert params["amount"] == "250500000"
        assert params["slippageBps"] == "75"
        assert params["swapMode"] == "ExactIn"

        Req.Test.json(conn, success_body(in_amount: "250500000", out_amount: "249500000"))
      end)

      assert {:ok, _quote} = Jupiter.quote(req)
    end

    test "uses default slippage of 50 bps when not specified" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["slippageBps"] == "50"

        Req.Test.json(conn, success_body())
      end)

      assert {:ok, _} = Jupiter.quote(req)
    end

    test "leg metadata includes price impact and context slot" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = Jupiter.quote(req)
      [leg] = quote.legs

      assert leg.metadata["priceImpactPct"] == "0.001"
      assert leg.metadata["contextSlot"] == 250_000_000
      assert leg.metadata["otherAmountThreshold"] == "98500000"
    end

    test "parses platform fee when present" do
      {:ok, req} = build_swap_request()

      body =
        success_body()
        |> Map.put("platformFee", %{
          "amount" => "100000",
          "feeBps" => 10
        })

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(conn, body)
      end)

      {:ok, quote} = Jupiter.quote(req)
      assert Decimal.equal?(quote.fees.protocol_fee, Decimal.new("0.1"))
    end

    test "works without API key (public Jupiter API)" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        headers = Map.new(conn.req_headers)
        refute Map.has_key?(headers, "authorization")
        refute Map.has_key?(headers, "x-api-key")

        Req.Test.json(conn, success_body())
      end)

      assert {:ok, _} = Jupiter.quote(req)
    end

    test "sends x-api-key header when API key is configured" do
      original = Application.get_env(:bank, Jupiter)

      Application.put_env(:bank, Jupiter,
        base_url: "http://jupiter.test",
        api_key: "test-jupiter-key",
        req_options: Keyword.get(original, :req_options, [])
      )

      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        headers = Map.new(conn.req_headers)
        assert headers["x-api-key"] == "test-jupiter-key"

        Req.Test.json(conn, success_body())
      end)

      assert {:ok, _} = Jupiter.quote(req)
    after
      Application.put_env(:bank, Jupiter,
        base_url: "http://jupiter.test",
        req_options: [plug: {Req.Test, Jupiter}]
      )
    end
  end

  # -- Unsupported routes ---------------------------------------------------

  describe "quote/1 — unsupported routes" do
    test "rejects ethereum (EVM chain)" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "ethereum",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = Jupiter.quote(req)
    end

    test "rejects base (EVM chain)" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "base",
          source_asset: "USDC",
          dest_chain: "base",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = Jupiter.quote(req)
    end

    test "rejects arbitrum (EVM chain)" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "arbitrum",
          source_asset: "USDC",
          dest_chain: "arbitrum",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = Jupiter.quote(req)
    end

    test "rejects bridge routes" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "solana",
          dest_asset: "USDC",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = Jupiter.quote(req)
    end

    test "rejects swap_plus_bridge routes" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "solana",
          dest_asset: "USDT",
          amount: Decimal.new("100")
        })

      assert {:error, :unsupported_route} = Jupiter.quote(req)
    end
  end

  # -- Error classification -------------------------------------------------

  describe "quote/1 — error classification" do
    test "429 maps to :rate_limited" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Plug.Conn.send_resp(conn, 429, "")
      end)

      assert {:error, :rate_limited} = Jupiter.quote(req)
    end

    test "500 maps to :provider_unavailable" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(conn |> Plug.Conn.put_status(500), %{"error" => "internal"})
      end)

      assert {:error, :provider_unavailable} = Jupiter.quote(req)
    end

    test "503 maps to :provider_unavailable" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Plug.Conn.send_resp(conn, 503, "")
      end)

      assert {:error, :provider_unavailable} = Jupiter.quote(req)
    end

    test "400 with 'Could not find route' maps to :no_route_found" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(400),
          %{"error" => "Could not find route for the given input"}
        )
      end)

      assert {:error, :no_route_found} = Jupiter.quote(req)
    end

    test "400 with ROUTE_NOT_FOUND errorCode maps to :no_route_found" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(400),
          %{"errorCode" => "ROUTE_NOT_FOUND", "error" => "No routes found"}
        )
      end)

      assert {:error, :no_route_found} = Jupiter.quote(req)
    end

    test "400 with insufficient liquidity maps to :no_route_found" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(400),
          %{"error" => "Insufficient liquidity for this trade"}
        )
      end)

      assert {:error, :no_route_found} = Jupiter.quote(req)
    end

    test "400 with unrecognized error maps to provider_error" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(400),
          %{"error" => "Invalid mint address"}
        )
      end)

      assert {:error, {:provider_error, %{status: 400, body: _}}} = Jupiter.quote(req)
    end

    test "malformed 200 body maps to provider_error" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(conn, %{"unexpected" => "shape"})
      end)

      assert {:error, {:provider_error, %{reason: "malformed_response"}}} = Jupiter.quote(req)
    end

    test "transport error maps to :provider_unavailable" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :provider_unavailable} = Jupiter.quote(req)
    end
  end

  # -- Cross-provider comparability -----------------------------------------

  describe "cross-provider comparability" do
    test "quote output has same normalized shape as EVM providers" do
      {:ok, req} = build_swap_request()

      Req.Test.stub(Jupiter, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      {:ok, quote} = Jupiter.quote(req)

      assert %RouteQuote{
               provider: "jupiter",
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
