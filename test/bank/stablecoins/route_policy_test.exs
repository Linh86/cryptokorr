defmodule Bank.Stablecoins.RoutePolicyTest do
  use ExUnit.Case, async: true

  alias Bank.Stablecoins.{QuoteRequest, RouteLeg, RoutePolicy, RouteQuote}

  defmodule FakeProvider do
    @behaviour Bank.Stablecoins.Provider

    @impl true
    def provider_id, do: "fake"

    @impl true
    def quote(%QuoteRequest{} = req) do
      out_amount = fake_output(req)
      now = DateTime.utc_now()

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: req.route_kind,
         legs: [
           %RouteLeg{
             step: 1,
             kind: leg_kind(req.route_kind),
             source_chain: req.source_chain,
             source_asset: req.source_asset,
             dest_chain: req.dest_chain,
             dest_asset: req.dest_asset,
             input_amount: req.amount,
             output_amount: out_amount
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
           cryptobank_fee: nil,
           total_fee: Decimal.sub(req.amount, out_amount)
         },
         eta_seconds: Process.get(:fake_eta),
         risk_flags: Process.get(:fake_risk_flags, [])
       }}
    end

    defp fake_output(req) do
      case Process.get(:fake_output) do
        nil -> Decimal.sub(req.amount, Decimal.new("0.5"))
        raw -> Decimal.new(raw)
      end
    end

    defp leg_kind(:bridge), do: :bridge
    defp leg_kind(_), do: :swap
  end

  defmodule FailProvider do
    @behaviour Bank.Stablecoins.Provider

    @impl true
    def provider_id, do: "fail"

    @impl true
    def quote(%QuoteRequest{}), do: {:error, :provider_unavailable}
  end

  defmodule SwapProvider do
    @behaviour Bank.Stablecoins.Provider

    @impl true
    def provider_id, do: "test_swap"

    @impl true
    def quote(%QuoteRequest{route_kind: :swap} = req) do
      out = Decimal.sub(req.amount, Decimal.new("0.5"))
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
             output_amount: out
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
         }
       }}
    end

    def quote(%QuoteRequest{}), do: {:error, :unsupported_route}
  end

  defmodule BridgeProvider do
    @behaviour Bank.Stablecoins.Provider

    @impl true
    def provider_id, do: "test_bridge"

    @impl true
    def quote(%QuoteRequest{route_kind: :bridge} = req) do
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
             output_amount: req.amount
           }
         ],
         input_amount: req.amount,
         output_amount: req.amount,
         quoted_at: DateTime.utc_now(),
         fees: %{
           gas_fee: nil,
           protocol_fee: nil,
           bridge_fee: nil,
           cryptobank_fee: nil,
           total_fee: Decimal.new(0)
         },
         eta_seconds: 120
       }}
    end

    def quote(%QuoteRequest{}), do: {:error, :unsupported_route}
  end

  setup do
    for key <- [:fake_output, :fake_eta, :fake_risk_flags], do: Process.delete(key)

    on_exit(fn ->
      for key <- [:fake_output, :fake_eta, :fake_risk_flags], do: Process.delete(key)
    end)
  end

  describe "evaluate/2 — allowed" do
    test "active canonical tokens on allowed chain are allowed" do
      req = build_swap_request()

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts())

      assert eval.decision == :allowed
      assert eval.reasons == []
      assert eval.score > 0
    end

    test "preserves quote, request, and selector metadata for audit/replay" do
      req = build_swap_request()

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts())

      assert eval.request == req
      assert eval.quote.provider == "fake"
      assert eval.selector_metadata.considered == 1
      assert [%RouteQuote{provider: "fake"}] = eval.selector_metadata.all_quotes
    end
  end

  describe "evaluate/2 — approval_required" do
    test "approval_only source token requires approval" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "base",
          source_asset: "USDT",
          dest_chain: "base",
          dest_asset: "USDC",
          amount: Decimal.new("100"),
          metadata: %{taker_address: taker_address()}
        })

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts())

      assert eval.decision == :approval_required
      assert has_reason?(eval, :token_approval_only, :approval)
    end

    test "non-canonical token requires approval by default" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "base",
          source_asset: "USDT",
          dest_chain: "base",
          dest_asset: "USDC",
          amount: Decimal.new("100"),
          metadata: %{taker_address: taker_address()}
        })

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts())

      assert eval.decision == :approval_required
      assert has_reason?(eval, :token_non_canonical, :approval)
    end

    test "non-canonical approval can be explicitly allowed while status approval still applies" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "base",
          source_asset: "USDT",
          dest_chain: "base",
          dest_asset: "USDC",
          amount: Decimal.new("100"),
          metadata: %{taker_address: taker_address()}
        })

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts(allow_non_canonical: true))

      refute has_reason?(eval, :token_non_canonical, :approval)
      assert has_reason?(eval, :token_approval_only, :approval)
      assert eval.decision == :approval_required
    end

    test "amount above max_amount requires approval" do
      req = build_swap_request(%{amount: Decimal.new("50000")})

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts(max_amount: 10_000))

      assert eval.decision == :approval_required
      assert has_reason?(eval, :amount_above_threshold, :approval)
    end

    test "risk flags require approval" do
      req = build_swap_request()
      Process.put(:fake_risk_flags, ["high_slippage"])

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts())

      assert eval.decision == :approval_required
      assert has_reason?(eval, :risk_flag, :approval)
    end
  end

  describe "evaluate/2 — blocked" do
    test "blocked source token blocks" do
      req = build_raw_request(source_status: :blocked)
      quote = build_raw_quote(req)

      eval = RoutePolicy.evaluate_quote(req, quote, %{considered: 1})

      assert eval.decision == :blocked
      assert has_reason?(eval, :token_blocked, :block)
    end

    test "blocked dest token blocks" do
      req = build_raw_request(dest_status: :blocked)
      quote = build_raw_quote(req)

      eval = RoutePolicy.evaluate_quote(req, quote, %{considered: 1})

      assert eval.decision == :blocked
      assert has_reason?(eval, :token_blocked, :block)
    end

    test "fee above max_fee_bps blocks" do
      req = build_swap_request()
      Process.put(:fake_output, "90")

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts(max_fee_bps: 50))

      assert eval.decision == :blocked
      assert has_reason?(eval, :fee_above_threshold, :block)
    end

    test "chain outside allowed_chains blocks" do
      req = build_swap_request()

      assert {:ok, eval} =
               RoutePolicy.evaluate(req, eval_opts(allowed_chains: ["base", "polygon"]))

      assert eval.decision == :blocked
      assert has_reason?(eval, :chain_not_allowed, :block)
    end

    test "route kind outside allowed_route_kinds blocks" do
      req = build_swap_request()

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts(allowed_route_kinds: [:bridge]))

      assert eval.decision == :blocked
      assert has_reason?(eval, :route_kind_not_allowed, :block)
    end

    test "block overrides approval reasons" do
      req = build_raw_request(source_status: :blocked, dest_status: :approval_only)
      quote = build_raw_quote(req)

      eval = RoutePolicy.evaluate_quote(req, quote, %{considered: 1})

      assert eval.decision == :blocked
      assert has_reason?(eval, :token_blocked, :block)
      assert has_reason?(eval, :token_approval_only, :approval)
    end
  end

  describe "fee_summary" do
    test "calculates explicit CryptoBank fee from input amount" do
      req = build_swap_request(%{amount: Decimal.new("1000")})

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts(cryptobank_fee_bps: 10))

      assert Decimal.equal?(eval.fee_summary.cryptobank_fee, Decimal.new("1"))
    end

    test "total_fee includes provider fee plus CryptoBank fee" do
      req = build_swap_request()

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts(cryptobank_fee_bps: 10))

      expected =
        Decimal.new("0.5")
        |> Decimal.add(Decimal.new("0.1"))

      assert Decimal.equal?(eval.fee_summary.total_fee, expected)
    end

    test "output_impact_pct reflects input-output loss" do
      req = build_swap_request()

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts())

      assert Decimal.equal?(eval.fee_summary.output_impact_pct, Decimal.new("0.5"))
    end

    test "supports zero CryptoBank fee" do
      req = build_swap_request()

      assert {:ok, eval} = RoutePolicy.evaluate(req, eval_opts(cryptobank_fee_bps: 0))

      assert Decimal.equal?(eval.fee_summary.cryptobank_fee, Decimal.new(0))
    end
  end

  describe "scoring" do
    test "higher output gives higher score" do
      req = build_swap_request()

      Process.put(:fake_output, "99.8")
      assert {:ok, eval_high} = RoutePolicy.evaluate(req, eval_opts())

      Process.put(:fake_output, "98.0")
      assert {:ok, eval_low} = RoutePolicy.evaluate(req, eval_opts())

      assert eval_high.score > eval_low.score
    end

    test "risk flags reduce score but do not override block/approval precedence" do
      req = build_swap_request()

      Process.put(:fake_risk_flags, [])
      assert {:ok, eval_clean} = RoutePolicy.evaluate(req, eval_opts())

      Process.put(:fake_risk_flags, ["risky_pool", "low_liquidity"])
      assert {:ok, eval_risky} = RoutePolicy.evaluate(req, eval_opts())

      assert eval_clean.score > eval_risky.score
      assert eval_risky.decision == :approval_required
    end

    test "long ETA reduces score" do
      req = build_swap_request()

      Process.put(:fake_eta, 15)
      assert {:ok, eval_fast} = RoutePolicy.evaluate(req, eval_opts())

      Process.put(:fake_eta, 1200)
      assert {:ok, eval_slow} = RoutePolicy.evaluate(req, eval_opts())

      assert eval_fast.score > eval_slow.score
    end
  end

  describe "swap_plus_bridge" do
    test "ethereum USDT to base USDC composite route can be allowed" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDT",
          dest_chain: "base",
          dest_asset: "USDC",
          amount: Decimal.new("100"),
          metadata: %{taker_address: taker_address()}
        })

      assert {:ok, eval} =
               RoutePolicy.evaluate(req,
                 swap_providers: [SwapProvider],
                 bridge_providers: [BridgeProvider]
               )

      assert eval.decision == :allowed
      assert eval.quote.route_kind == :swap_plus_bridge
      assert [%RouteLeg{kind: :swap}, %RouteLeg{kind: :bridge}] = eval.quote.legs
    end

    test "approval_only source token in composite route requires approval" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "base",
          source_asset: "USDT",
          dest_chain: "ethereum",
          dest_asset: "USDC",
          amount: Decimal.new("100"),
          metadata: %{taker_address: taker_address()}
        })

      assert {:ok, eval} =
               RoutePolicy.evaluate(req,
                 swap_providers: [SwapProvider],
                 bridge_providers: [BridgeProvider]
               )

      assert eval.decision == :approval_required
      assert has_reason?(eval, :token_approval_only, :approval)
      assert eval.quote.route_kind == :swap_plus_bridge
    end
  end

  describe "selector integration" do
    test "passes through selector unsupported_route errors" do
      req = build_swap_request()

      assert {:error, :unsupported_route} = RoutePolicy.evaluate(req, providers: [])
    end

    test "passes through provider no_quotes errors" do
      req = build_swap_request()

      assert {:error, {:no_quotes, [%{provider: FailProvider, error: :provider_unavailable}]}} =
               RoutePolicy.evaluate(req, providers: [FailProvider])
    end
  end

  defp build_swap_request(overrides \\ %{}) do
    defaults = %{
      source_chain: "ethereum",
      source_asset: "USDC",
      dest_chain: "ethereum",
      dest_asset: "USDT",
      amount: Decimal.new("100"),
      metadata: %{taker_address: taker_address()}
    }

    {:ok, req} = QuoteRequest.build(Map.merge(defaults, overrides))
    req
  end

  defp build_raw_request(opts) do
    source_status = Keyword.get(opts, :source_status, :active)
    dest_status = Keyword.get(opts, :dest_status, :active)
    source_canonical = Keyword.get(opts, :source_canonical, source_status == :active)
    dest_canonical = Keyword.get(opts, :dest_canonical, dest_status == :active)

    %QuoteRequest{
      source_chain: "ethereum",
      source_asset: "USDC",
      source_token: token("ethereum", "USDC", source_status, source_canonical),
      dest_chain: "ethereum",
      dest_asset: "USDT",
      dest_token: token("ethereum", "USDT", dest_status, dest_canonical),
      amount: Decimal.new("100"),
      route_kind: :swap,
      metadata: %{}
    }
  end

  defp build_raw_quote(req) do
    out = Decimal.sub(req.amount, Decimal.new("0.5"))

    %RouteQuote{
      provider: "fake",
      request: req,
      route_kind: req.route_kind,
      legs: [
        %RouteLeg{
          step: 1,
          kind: :swap,
          source_chain: req.source_chain,
          source_asset: req.source_asset,
          dest_chain: req.dest_chain,
          dest_asset: req.dest_asset,
          input_amount: req.amount,
          output_amount: out
        }
      ],
      input_amount: req.amount,
      output_amount: out,
      quoted_at: DateTime.utc_now(),
      fees: %{
        gas_fee: nil,
        protocol_fee: nil,
        bridge_fee: nil,
        cryptobank_fee: nil,
        total_fee: Decimal.sub(req.amount, out)
      },
      risk_flags: []
    }
  end

  defp eval_opts(extra \\ []) do
    Keyword.merge([providers: [FakeProvider]], extra)
  end

  defp has_reason?(eval, rule, severity) do
    Enum.any?(eval.reasons, &(&1.rule == rule and &1.severity == severity))
  end

  defp token(chain, asset, status, canonical) do
    %{
      chain: chain,
      asset: asset,
      address: "#{chain}:#{asset}",
      decimals: 6,
      name: asset,
      standard: :erc20,
      status: status,
      issuer: "test",
      canonical: canonical,
      variant: :native,
      notes: "test"
    }
  end

  defp taker_address, do: "0x0000000000000000000000000000000000000abc"
end
