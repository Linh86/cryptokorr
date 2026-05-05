defmodule Bank.Decisions.SwapRouteArtifactsTest do
  use ExUnit.Case, async: true

  alias Bank.Decisions.SwapRouteArtifacts

  defp valid_route(overrides \\ %{}) do
    deadline = ~U[2030-01-01 00:00:00.000000Z]
    quote_ts = ~U[2026-01-01 00:00:00.000000Z]

    Map.merge(
      %{
        source_asset: "USDC",
        destination_asset: "USDC",
        source_token_address: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        destination_token_address: "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        input_amount: Decimal.new("100.00"),
        expected_output_amount: Decimal.new("99.00"),
        minimum_output_amount: Decimal.new("98.00"),
        spender: "0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
        swap_target_contract: "0xDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
        calldata: "0xdeadbeef",
        value: Decimal.new("0"),
        route_provider: "test_provider",
        quote_timestamp: quote_ts,
        deadline: deadline,
        chain: "base-sepolia",
        chain_id: 84_532,
        slippage_bps: 50
      },
      overrides
    )
  end

  describe "from_route/1" do
    test "returns hash, chain, asset (=destination_asset), steps and audit metadata" do
      route = valid_route()
      artifacts = SwapRouteArtifacts.from_route(route)

      assert is_binary(artifacts.route_hash)
      assert artifacts.chain == "base-sepolia"
      assert artifacts.asset == "USDC"

      assert artifacts.audit_metadata == %{
               route_hash: artifacts.route_hash,
               route_provider: "test_provider"
             }

      steps = artifacts.steps
      assert steps["kind"] == "swap"
      assert steps["route_hash"] == artifacts.route_hash
      assert steps["route_provider"] == "test_provider"
      assert steps["chain"] == "base-sepolia"
      assert steps["chain_id"] == 84_532
      assert steps["source_asset"] == "USDC"
      assert steps["destination_asset"] == "USDC"
      assert steps["input_amount"] == "100"
      assert steps["expected_output_amount"] == "99"
      assert steps["minimum_output_amount"] == "98"
      assert steps["calldata"] == "0xdeadbeef"
      assert steps["slippage_bps"] == 50
      assert steps["quote_timestamp"] == "2026-01-01T00:00:00.000000Z"
      assert steps["deadline"] == "2030-01-01T00:00:00.000000Z"
    end
  end

  describe "route_hash/1" do
    test "is deterministic for the same route" do
      route = valid_route()
      assert SwapRouteArtifacts.route_hash(route) == SwapRouteArtifacts.route_hash(route)
    end

    test "is sha256 lowercase hex (64 chars)" do
      hash = SwapRouteArtifacts.route_hash(valid_route())
      assert String.length(hash) == 64
      assert hash == String.downcase(hash)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)
    end

    test "ignores case differences in addresses" do
      lower =
        valid_route(%{
          source_token_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          destination_token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          spender: "0xcccccccccccccccccccccccccccccccccccccccc",
          swap_target_contract: "0xdddddddddddddddddddddddddddddddddddddddd"
        })

      assert SwapRouteArtifacts.route_hash(lower) == SwapRouteArtifacts.route_hash(valid_route())
    end

    test "changes when minimum_output_amount changes" do
      base = SwapRouteArtifacts.route_hash(valid_route())

      tighter =
        SwapRouteArtifacts.route_hash(valid_route(%{minimum_output_amount: Decimal.new("97.0")}))

      refute base == tighter
    end

    test "ignores trailing-zero differences in decimals" do
      a = SwapRouteArtifacts.route_hash(valid_route(%{input_amount: Decimal.new("100")}))
      b = SwapRouteArtifacts.route_hash(valid_route(%{input_amount: Decimal.new("100.00")}))
      assert a == b
    end

    test "is independent of calldata (calldata is dispatch-only, not load-bearing)" do
      a = SwapRouteArtifacts.route_hash(valid_route(%{calldata: "0xdeadbeef"}))
      b = SwapRouteArtifacts.route_hash(valid_route(%{calldata: "0xfeedface"}))
      assert a == b
    end
  end
end
