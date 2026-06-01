defmodule Bank.Stablecoins.RouteSelector.SwapPlusBridgeTest do
  use ExUnit.Case, async: true

  alias Bank.Stablecoins.{QuoteRequest, RouteQuote, RouteLeg, RouteSelector}

  # -- In-test fake providers -----------------------------------------------

  defmodule SwapProvider do
    @behaviour Bank.Stablecoins.Provider
    @impl true
    def provider_id, do: "fake_swap"
    @impl true
    def quote(%QuoteRequest{route_kind: :swap} = req) do
      case Process.get(:swap_response) do
        {:error, _} = err ->
          err

        nil ->
          build_quote(req, "99.5")

        {:ok, amount} ->
          build_quote(req, amount)
      end
    end

    def quote(%QuoteRequest{}), do: {:error, :unsupported_route}

    defp build_quote(req, out) do
      out_amount = Decimal.new(out)
      now = DateTime.utc_now()

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: :swap,
         legs: [
           %RouteLeg{
             step: 1,
             kind: :swap,
             source_chain: req.source_chain,
             source_asset: req.source_asset,
             source_address: req.source_token.address,
             dest_chain: req.dest_chain,
             dest_asset: req.dest_asset,
             dest_address: req.dest_token.address,
             input_amount: req.amount,
             output_amount: out_amount,
             protocol: "FakeDEX"
           }
         ],
         input_amount: req.amount,
         output_amount: out_amount,
         quoted_at: now,
         expires_at: DateTime.add(now, 60, :second),
         fees: %{
           gas_fee: nil,
           protocol_fee: nil,
           bridge_fee: nil,
           cryptokorr_fee: nil,
           total_fee: Decimal.sub(req.amount, out_amount)
         },
         eta_seconds: Process.get(:swap_eta, nil),
         provider_metadata: %{"tx" => "0xfake"}
       }}
    end
  end

  defmodule BridgeProvider do
    @behaviour Bank.Stablecoins.Provider
    @impl true
    def provider_id, do: "fake_bridge"
    @impl true
    def quote(%QuoteRequest{route_kind: :bridge} = req) do
      case Process.get(:bridge_response) do
        {:error, _} = err ->
          err

        _ ->
          build_quote(req)
      end
    end

    def quote(%QuoteRequest{}), do: {:error, :unsupported_route}

    defp build_quote(req) do
      now = DateTime.utc_now()

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: :bridge,
         legs: [
           %RouteLeg{
             step: 1,
             kind: :bridge,
             source_chain: req.source_chain,
             source_asset: req.source_asset,
             source_address: req.source_token.address,
             dest_chain: req.dest_chain,
             dest_asset: req.dest_asset,
             dest_address: req.dest_token.address,
             input_amount: req.amount,
             output_amount: req.amount,
             protocol: "FakeBridge"
           }
         ],
         input_amount: req.amount,
         output_amount: req.amount,
         quoted_at: now,
         fees: %{
           gas_fee: nil,
           protocol_fee: nil,
           bridge_fee: nil,
           cryptokorr_fee: nil,
           total_fee: Decimal.new(0)
         },
         eta_seconds: Process.get(:bridge_eta, 120),
         provider_metadata: %{"domain" => "fake"}
       }}
    end
  end

  defmodule FailingSwapProvider do
    @behaviour Bank.Stablecoins.Provider
    @impl true
    def provider_id, do: "failing_swap"
    @impl true
    def quote(%QuoteRequest{}), do: {:error, :provider_unavailable}
  end

  defmodule FailingBridgeProvider do
    @behaviour Bank.Stablecoins.Provider
    @impl true
    def provider_id, do: "failing_bridge"
    @impl true
    def quote(%QuoteRequest{route_kind: :bridge}), do: {:error, :provider_unavailable}
    def quote(%QuoteRequest{}), do: {:error, :unsupported_route}
  end

  # -- Fixtures -------------------------------------------------------------

  defp build_composite_request(overrides \\ %{}) do
    defaults = %{
      source_chain: "ethereum",
      source_asset: "USDT",
      dest_chain: "base",
      dest_asset: "USDC",
      amount: Decimal.new("100"),
      metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
    }

    {:ok, req} = QuoteRequest.build(Map.merge(defaults, overrides))
    req
  end

  defp composite_opts(swap_providers \\ [SwapProvider], bridge_providers \\ [BridgeProvider]) do
    [swap_providers: swap_providers, bridge_providers: bridge_providers]
  end

  # -- Successful composition -----------------------------------------------

  describe "select/2 — swap_plus_bridge success" do
    test "composes USDT->USDC swap + USDC bridge across chains" do
      req = build_composite_request()

      assert {:ok, %RouteQuote{} = quote, _meta} =
               RouteSelector.select(req, composite_opts())

      assert quote.provider == "composite"
      assert quote.route_kind == :swap_plus_bridge
      assert quote.request == req
      assert Decimal.equal?(quote.input_amount, Decimal.new("100"))
      assert Decimal.equal?(quote.output_amount, Decimal.new("99.5"))
    end

    test "quote has two legs in correct order" do
      req = build_composite_request()

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      assert [swap_leg, bridge_leg] = quote.legs
      assert swap_leg.step == 1
      assert swap_leg.kind == :swap
      assert bridge_leg.step == 2
      assert bridge_leg.kind == :bridge
    end

    test "swap leg swaps source asset to USDC on source chain" do
      req = build_composite_request()

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      [swap_leg, _bridge_leg] = quote.legs
      assert swap_leg.source_chain == "ethereum"
      assert swap_leg.source_asset == "USDT"
      assert swap_leg.dest_chain == "ethereum"
      assert swap_leg.dest_asset == "USDC"
    end

    test "bridge leg bridges USDC from source to dest chain" do
      req = build_composite_request()

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      [_swap_leg, bridge_leg] = quote.legs
      assert bridge_leg.source_chain == "ethereum"
      assert bridge_leg.source_asset == "USDC"
      assert bridge_leg.dest_chain == "base"
      assert bridge_leg.dest_asset == "USDC"
    end

    test "bridge input equals swap output" do
      req = build_composite_request()

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      [swap_leg, bridge_leg] = quote.legs
      assert Decimal.equal?(bridge_leg.input_amount, swap_leg.output_amount)
    end

    test "final output equals bridge output" do
      req = build_composite_request()

      Process.put(:swap_response, {:ok, "98.0"})

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      [_swap_leg, bridge_leg] = quote.legs
      assert Decimal.equal?(quote.output_amount, bridge_leg.output_amount)
      assert Decimal.equal?(quote.output_amount, Decimal.new("98.0"))
    end
  end

  # -- Fee composition ------------------------------------------------------

  describe "select/2 — fee and ETA composition" do
    test "total_fee sums swap and bridge fees" do
      req = build_composite_request()

      Process.put(:swap_response, {:ok, "99.5"})

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      assert Decimal.equal?(quote.fees.total_fee, Decimal.new("0.5"))
    end

    test "ETA sums swap and bridge ETAs" do
      req = build_composite_request()

      Process.put(:swap_eta, 15)
      Process.put(:bridge_eta, 120)

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      assert quote.eta_seconds == 135
    after
      Process.delete(:swap_eta)
      Process.delete(:bridge_eta)
    end

    test "ETA is bridge-only when swap has nil ETA" do
      req = build_composite_request()

      Process.put(:swap_eta, nil)
      Process.put(:bridge_eta, 120)

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      assert quote.eta_seconds == 120
    after
      Process.delete(:swap_eta)
      Process.delete(:bridge_eta)
    end

    test "expires_at comes from swap quote" do
      req = build_composite_request()

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      assert quote.expires_at != nil
    end
  end

  # -- Provider metadata ----------------------------------------------------

  describe "select/2 — composite metadata" do
    test "provider_metadata includes swap and bridge leg metadata" do
      req = build_composite_request()

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      assert %{"swap_leg" => swap_meta, "bridge_leg" => bridge_meta} =
               quote.provider_metadata

      assert swap_meta["provider"] == "fake_swap"
      assert swap_meta["provider_metadata"] == %{"tx" => "0xfake"}

      assert bridge_meta["provider"] == "fake_bridge"
      assert bridge_meta["provider_metadata"] == %{"domain" => "fake"}
    end

    test "select metadata includes swap_meta and bridge_meta" do
      req = build_composite_request()

      {:ok, _quote, meta} = RouteSelector.select(req, composite_opts())

      assert Map.has_key?(meta, :swap_meta)
      assert Map.has_key?(meta, :bridge_meta)
      assert meta.swap_meta.considered >= 1
      assert meta.bridge_meta.considered >= 1
    end

    test "explanation describes the two-step route" do
      req = build_composite_request()

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      assert quote.explanation =~ "USDT->USDC swap"
      assert quote.explanation =~ "ethereum"
      assert quote.explanation =~ "bridge"
      assert quote.explanation =~ "base"
    end
  end

  # -- Swap provider selection ----------------------------------------------

  describe "select/2 — swap provider selection" do
    test "selects best swap provider from multiple" do
      req = build_composite_request()

      Process.put(:swap_response, {:ok, "99.8"})

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      [swap_leg, _] = quote.legs
      assert Decimal.equal?(swap_leg.output_amount, Decimal.new("99.8"))
    end
  end

  # -- Unsupported routes ---------------------------------------------------

  describe "select/2 — unsupported composite routes" do
    test "rejects USDC->USDT cross-chain (wrong direction)" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "base",
          dest_asset: "USDT",
          amount: Decimal.new("100"),
          metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
        })

      assert {:error, :unsupported_route} =
               RouteSelector.select(req, composite_opts())
    end

    test "does not treat USDT->USDT cross-chain as swap_plus_bridge" do
      req = build_composite_request(%{dest_asset: "USDT"})

      assert req.route_kind == :bridge
      assert {:error, :unsupported_route} = RouteSelector.select(req, providers: [])
    end
  end

  # -- Failure handling -----------------------------------------------------

  describe "select/2 — composite failure handling" do
    test "swap leg failure returns composite_route_failed with :swap stage" do
      req = build_composite_request()

      assert {:error, {:composite_route_failed, detail}} =
               RouteSelector.select(req,
                 swap_providers: [FailingSwapProvider],
                 bridge_providers: [BridgeProvider]
               )

      assert detail.failed_leg == :swap
    end

    test "bridge leg failure returns composite_route_failed with :bridge stage" do
      req = build_composite_request()

      assert {:error, {:composite_route_failed, detail}} =
               RouteSelector.select(req,
                 swap_providers: [SwapProvider],
                 bridge_providers: [FailingBridgeProvider]
               )

      assert detail.failed_leg == :bridge
    end

    test "swap failure preserves provider errors" do
      req = build_composite_request()

      assert {:error, {:composite_route_failed, detail}} =
               RouteSelector.select(req,
                 swap_providers: [FailingSwapProvider],
                 bridge_providers: [BridgeProvider]
               )

      assert detail.failed_leg == :swap
      assert {:no_quotes, errors} = detail.reason
      assert length(errors) == 1
      assert hd(errors).error == :provider_unavailable
    end

    test "bridge failure preserves provider errors" do
      req = build_composite_request()

      assert {:error, {:composite_route_failed, detail}} =
               RouteSelector.select(req,
                 swap_providers: [SwapProvider],
                 bridge_providers: [FailingBridgeProvider]
               )

      assert detail.failed_leg == :bridge
      assert {:no_quotes, errors} = detail.reason
      assert length(errors) == 1
      assert hd(errors).error == :provider_unavailable
    end
  end

  # -- Deterministic output -------------------------------------------------

  describe "select/2 — deterministic leg ordering" do
    test "legs are always [swap, bridge] regardless of call order" do
      req = build_composite_request()

      {:ok, quote, _meta} = RouteSelector.select(req, composite_opts())

      assert [%RouteLeg{kind: :swap, step: 1}, %RouteLeg{kind: :bridge, step: 2}] = quote.legs
    end
  end
end
