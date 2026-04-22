defmodule Bank.Stablecoins.IntentRoutingTest do
  use ExUnit.Case, async: false

  alias Bank.Stablecoins.{IntentRouting, ProviderHealth, QuoteRequest, RouteLeg, RouteQuote}

  defmodule FakeProvider do
    @behaviour Bank.Stablecoins.Provider

    @impl true
    def provider_id, do: "fake"

    @impl true
    def quote(%QuoteRequest{} = req) do
      out = Decimal.sub(req.amount, Decimal.new("0.5"))
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
             dest_chain: req.dest_chain,
             dest_asset: req.dest_asset,
             input_amount: req.amount,
             output_amount: out
           }
         ],
         input_amount: req.amount,
         output_amount: out,
         quoted_at: now,
         fees: %{
           gas_fee: nil,
           protocol_fee: nil,
           bridge_fee: nil,
           cryptobank_fee: nil,
           total_fee: Decimal.new("0.5")
         },
         risk_flags: []
       }}
    end
  end

  setup do
    start_supervised!(ProviderHealth)
    :ok
  end

  describe "evaluate_for_intent/2 — allowed" do
    test "allowed route maps to auto_exec with planned state" do
      {:ok, result} =
        IntentRouting.evaluate_for_intent(
          %{
            source_chain: "ethereum",
            source_asset: "USDC",
            dest_chain: "ethereum",
            dest_asset: "USDT",
            amount: Decimal.new("100"),
            metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
          },
          providers: [FakeProvider]
        )

      assert result.outcome == :auto_exec
      assert result.reason_code == :stablecoin_route_allowed
      assert result.execution_state == :planned
      assert result.evaluation != nil
      assert result.evaluation.decision == :allowed
    end
  end

  describe "evaluate_for_intent/2 — approval_required" do
    test "approval_only token maps to approval_required" do
      {:ok, result} =
        IntentRouting.evaluate_for_intent(
          %{
            source_chain: "base",
            source_asset: "USDT",
            dest_chain: "base",
            dest_asset: "USDC",
            amount: Decimal.new("100"),
            metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
          },
          providers: [FakeProvider]
        )

      assert result.outcome == :approval_required
      assert result.reason_code == :stablecoin_route_needs_approval
      assert result.execution_state == :planned
    end
  end

  describe "evaluate_for_intent/2 — blocked" do
    test "blocked chain maps to block with blocked state" do
      {:ok, result} =
        IntentRouting.evaluate_for_intent(
          %{
            source_chain: "ethereum",
            source_asset: "USDC",
            dest_chain: "ethereum",
            dest_asset: "USDT",
            amount: Decimal.new("100"),
            metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
          },
          providers: [FakeProvider],
          allowed_chains: ["base"]
        )

      assert result.outcome == :block
      assert result.reason_code == :stablecoin_route_blocked
      assert result.execution_state == :blocked
    end
  end

  describe "evaluate_for_intent/2 — errors" do
    test "unsupported route returns error" do
      assert {:error, :unsupported_route} =
               IntentRouting.evaluate_for_intent(
                 %{
                   source_chain: "ethereum",
                   source_asset: "USDC",
                   dest_chain: "base",
                   dest_asset: "USDT",
                   amount: Decimal.new("100"),
                   metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
                 },
                 providers: []
               )
    end

    test "invalid params return error" do
      assert {:error, _} =
               IntentRouting.evaluate_for_intent(%{
                 source_chain: "bsc",
                 source_asset: "USDC",
                 dest_chain: "ethereum",
                 dest_asset: "USDT",
                 amount: Decimal.new("100")
               })
    end
  end

  describe "build_evidence/1" do
    test "includes route details for allowed route" do
      {:ok, result} =
        IntentRouting.evaluate_for_intent(
          %{
            source_chain: "ethereum",
            source_asset: "USDC",
            dest_chain: "ethereum",
            dest_asset: "USDT",
            amount: Decimal.new("100"),
            metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
          },
          providers: [FakeProvider]
        )

      evidence = IntentRouting.build_evidence(result)
      route = evidence.stablecoin_route

      assert route.decision == :auto_exec
      assert route.policy_decision == :allowed
      assert route.route_kind == :swap
      assert route.provider == "fake"
      assert length(route.legs) == 1
      assert route.fee_summary != nil
      assert route.score > 0
      assert route.selector_metadata.considered == 1
    end

    test "nil evaluation returns nil evidence" do
      evidence =
        IntentRouting.build_evidence(%{
          outcome: :block,
          reason_code: :error,
          reason: "failed",
          evaluation: nil,
          execution_state: :blocked
        })

      assert evidence.stablecoin_route == nil
    end
  end

  describe "provider health integration" do
    test "records success in provider health" do
      {:ok, _result} =
        IntentRouting.evaluate_for_intent(
          %{
            source_chain: "ethereum",
            source_asset: "USDC",
            dest_chain: "ethereum",
            dest_asset: "USDT",
            amount: Decimal.new("100"),
            metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
          },
          providers: [FakeProvider]
        )

      state = ProviderHealth.get("fake")
      assert state.success_count >= 1
      assert state.status == :healthy
    end
  end
end
