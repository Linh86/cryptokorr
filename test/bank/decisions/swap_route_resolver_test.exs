defmodule Bank.Decisions.SwapRouteResolverTest do
  use ExUnit.Case, async: true

  alias Bank.Decisions.SwapRouteResolver
  alias Bank.Intents.SwapRoute
  alias Bank.Stablecoins.{QuoteRequest, RouteLeg, RouteQuote}

  @taker "0x000000000000000000000000000000000000beef"

  defmodule FakeZeroX do
    @behaviour Bank.Stablecoins.Provider

    @impl true
    def provider_id, do: "zerox"

    @impl true
    def quote(%QuoteRequest{} = req) do
      response = Process.get(:fake_zerox_response, :default)
      build(req, response)
    end

    defp build(_req, {:error, _} = err), do: err

    defp build(req, response) do
      out = Decimal.new("9.95")
      now = DateTime.utc_now()

      leg_meta =
        case response do
          :default -> %{"allowanceTarget" => "0x0000000000000000000000000000000000000aaa"}
          :missing_spender -> %{}
          :empty_allowance -> %{"allowanceTarget" => ""}
          {:meta, m} -> m
          _ -> %{"allowanceTarget" => "0x0000000000000000000000000000000000000aaa"}
        end

      transaction =
        case response do
          :default ->
            %{
              "to" => "0x0000000000001ff3684f28c67538d4d072c22734",
              "data" => "0x12345678abcd",
              "value" => "0"
            }

          :missing_transaction ->
            nil

          :missing_calldata ->
            %{"to" => "0xabc", "data" => "", "value" => "0"}

          :synthetic_calldata ->
            %{"to" => "0xabc", "data" => "0xdeadbeef", "value" => "0"}

          :missing_target ->
            %{"to" => "", "data" => "0x12345678", "value" => "0"}

          {:tx, tx} ->
            tx

          _ ->
            %{
              "to" => "0x0000000000001ff3684f28c67538d4d072c22734",
              "data" => "0x12345678abcd",
              "value" => "0"
            }
        end

      provider_metadata =
        %{}
        |> put_if("transaction", transaction)
        |> Map.put("minBuyAmount", "9900000")

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: req.route_kind,
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
             output_amount: out,
             metadata: leg_meta
           }
         ],
         input_amount: req.amount,
         output_amount: out,
         quoted_at: now,
         expires_at: DateTime.add(now, 60, :second),
         fees: %{
           gas_fee: nil,
           protocol_fee: nil,
           bridge_fee: nil,
           cryptobank_fee: nil,
           total_fee: Decimal.sub(req.amount, out)
         },
         eta_seconds: nil,
         provider_metadata: provider_metadata
       }}
    end

    defp put_if(map, _key, nil), do: map
    defp put_if(map, key, val), do: Map.put(map, key, val)
  end

  defmodule FakeOneInch do
    @behaviour Bank.Stablecoins.Provider

    @impl true
    def provider_id, do: "oneinch"

    @impl true
    def quote(%QuoteRequest{} = req) do
      out = Decimal.new("9.99")
      now = DateTime.utc_now()

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: req.route_kind,
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
             output_amount: out,
             metadata: %{}
           }
         ],
         input_amount: req.amount,
         output_amount: out,
         quoted_at: now,
         expires_at: DateTime.add(now, 60, :second),
         fees: %{
           gas_fee: nil,
           protocol_fee: nil,
           bridge_fee: nil,
           cryptobank_fee: nil,
           total_fee: Decimal.sub(req.amount, out)
         },
         eta_seconds: nil,
         # 1inch returns NO `transaction` in v0.1 — quote-only.
         provider_metadata: %{}
       }}
    end
  end

  defp payload do
    %{
      "agent_id" => "test-agent",
      "source" => "user",
      "idempotency_key" => "swap-test",
      "kind" => "swap",
      "chain" => "base",
      "asset" => "USDC",
      "amount" => "10.0",
      "target" => %{"raw_address" => "0x0000000000000000000000000000000000000001"}
    }
  end

  defp resolve(payload, overrides \\ [], response \\ :default) do
    Process.put(:fake_zerox_response, response)

    opts =
      Keyword.merge(
        [taker_address: @taker, providers: [FakeZeroX], caps: caps()],
        overrides
      )

    SwapRouteResolver.resolve(payload, opts)
  end

  defp caps do
    %{
      allowed_chains: ["base", "base-sepolia"],
      allowed_assets: ["USDC", "USDT"],
      max_slippage_bps: 50
    }
  end

  # ── Happy path ───────────────────────────────────────────────────────

  test "returns a SwapRoute-validate-clean map from a real 0x quote" do
    assert {:ok, route} = resolve(payload())

    # Every required SwapRoute field traces back to either the
    # provider response or the cap-derived slippage.
    assert route.source_asset == "USDC"
    assert route.destination_asset == "USDT"
    assert route.route_provider == "zerox"
    assert route.calldata == "0x12345678abcd"
    assert route.spender == "0x0000000000000000000000000000000000000aaa"
    assert route.swap_target_contract == "0x0000000000001ff3684f28c67538d4d072c22734"
    assert route.chain == "base"
    assert route.chain_id == 8453
    assert route.slippage_bps == 50
    assert %Decimal{} = route.input_amount
    assert %Decimal{} = route.expected_output_amount
    assert %Decimal{} = route.value
    assert Decimal.compare(route.value, Decimal.new(0)) == :eq

    assert :ok =
             SwapRoute.validate(route,
               caps: %{
                 allowed_chains: ["base"],
                 allowed_assets: ["USDC", "USDT"],
                 max_slippage_bps: 50
               }
             )
  end

  test "uses provider minBuyAmount as minimum_output when present" do
    assert {:ok, route} = resolve(payload())

    assert Decimal.compare(route.minimum_output_amount, Decimal.new("9.9")) == :eq
  end

  # ── Failure modes ────────────────────────────────────────────────────

  test "rejects when no taker_address supplied" do
    assert {:error, :missing_taker_address} =
             resolve(payload(), taker_address: nil)
  end

  test "rejects when transaction is missing" do
    assert {:error, :missing_executable_transaction} =
             resolve(payload(), [], :missing_transaction)
  end

  test "rejects empty calldata" do
    assert {:error, :missing_calldata} =
             resolve(payload(), [], :missing_calldata)
  end

  test "rejects synthetic 0xdeadbeef calldata" do
    assert {:error, :synthetic_calldata_rejected} =
             resolve(payload(), [], :synthetic_calldata)
  end

  test "rejects missing transaction target" do
    assert {:error, :missing_transaction_target} =
             resolve(payload(), [], :missing_target)
  end

  test "rejects missing allowanceTarget (spender)" do
    assert {:error, :missing_spender} =
             resolve(payload(), [], :missing_spender)
  end

  test "rejects empty allowanceTarget (spender)" do
    assert {:error, :missing_spender} =
             resolve(payload(), [], :empty_allowance)
  end

  test "rejects a quote from a non-zerox provider" do
    assert {:error, :non_executable_provider} =
             resolve(payload(), providers: [FakeOneInch])
  end

  test "propagates RouteSelector error verbatim" do
    assert {:error, {:route_unavailable, {:no_quotes, _}}} =
             resolve(payload(), [], {:error, :no_route_found})
  end

  test "propagates QuoteRequest.build error verbatim (unsupported chain)" do
    bad_payload = Map.put(payload(), "chain", "base-sepolia")
    assert {:error, {:quote_request_build, :unsupported_source_chain}} = resolve(bad_payload)
  end

  test "rejects invalid amount" do
    bad = Map.put(payload(), "amount", "0")
    assert {:error, :invalid_amount} = resolve(bad)
  end

  test "rejects missing chain" do
    bad = Map.put(payload(), "chain", "")
    assert {:error, :invalid_chain} = resolve(bad)
  end

  test "rejects missing source asset" do
    bad = Map.put(payload(), "asset", "")
    assert {:error, :invalid_source_asset} = resolve(bad)
  end
end
