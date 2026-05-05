defmodule Bank.Decisions.SwapDispatchSafetyTest do
  @moduledoc """
  Per-gate coverage for `Bank.Decisions.SwapDispatchSafety` (#191) —
  the single function every swap dispatch path must call.

  Each test exercises exactly one gate so a regression points to the
  failing gate, not the composition. The route shape gates
  delegated to `Bank.Intents.SwapRoute.validate/2` are smoke-tested
  here rather than re-asserted exhaustively (that suite lives in
  `test/bank/intents/swap_route_test.exs`).
  """

  use Bank.DataCase, async: false

  import Bank.Fixtures

  alias Bank.Decisions.SwapDispatchSafety
  alias Bank.Intents.AgentIntent
  alias Bank.Security
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    on_exit(fn -> PauseState.reset() end)
    :ok
  end

  defp valid_route(overrides \\ %{}) do
    deadline =
      DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

    quote_ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Map.merge(
      %{
        source_asset: "USDC",
        destination_asset: "USDC",
        source_token_address: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        destination_token_address: "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        input_amount: Decimal.new("100"),
        expected_output_amount: Decimal.new("99"),
        minimum_output_amount: Decimal.new("98"),
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

  defp swap_intent(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{kind: :swap, chain: "base-sepolia", amount: Decimal.new("100")},
        overrides
      )

    agent_intent(attrs)
  end

  defp context(intent, workspace_id \\ nil) do
    %{intent: intent, workspace_id: workspace_id || intent.workspace_id}
  end

  describe "happy path" do
    test "returns :ok for a route consistent with the intent on a testnet chain" do
      intent = swap_intent()
      assert :ok = SwapDispatchSafety.validate(valid_route(), context(intent))
    end
  end

  describe "delegated route-shape gates (Bank.Intents.SwapRoute)" do
    test "structural failure is propagated as the validator's atom" do
      intent = swap_intent()
      route = valid_route() |> Map.delete(:calldata)

      assert {:error, :swap_route_field_missing} =
               SwapDispatchSafety.validate(route, context(intent))
    end

    test "stale deadline is propagated as :swap_deadline_expired" do
      intent = swap_intent()

      stale =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      assert {:error, :swap_deadline_expired} =
               SwapDispatchSafety.validate(valid_route(%{deadline: stale}), context(intent))
    end

    test "unsupported asset is propagated as :swap_asset_not_supported" do
      intent = swap_intent()

      assert {:error, :swap_asset_not_supported} =
               SwapDispatchSafety.validate(valid_route(%{source_asset: "ETH"}), context(intent))
    end

    test "slippage above the cap is propagated as :swap_slippage_exceeded" do
      intent = swap_intent()

      assert {:error, :swap_slippage_exceeded} =
               SwapDispatchSafety.validate(valid_route(%{slippage_bps: 5_000}), context(intent))
    end
  end

  describe "route ↔ intent cross-checks" do
    test "rejects when route.chain disagrees with intent.chain" do
      # Intent is on base-sepolia; route claims base. Both are
      # individually valid shapes; the centralised gate catches the
      # cross-field inconsistency that neither validator alone sees.
      intent = swap_intent(%{chain: "base"})
      route = valid_route(%{chain: "base-sepolia", chain_id: 84_532})

      assert {:error, :swap_chain_mismatch_with_intent} =
               SwapDispatchSafety.validate(route, context(intent))
    end

    test "rejects when route.input_amount disagrees with intent.amount" do
      intent = swap_intent(%{amount: Decimal.new("50")})
      route = valid_route(%{input_amount: Decimal.new("100")})

      assert {:error, :swap_amount_mismatch_with_intent} =
               SwapDispatchSafety.validate(route, context(intent))
    end

    test "amount comparison ignores trailing-zero differences" do
      intent = swap_intent(%{amount: Decimal.new("100")})
      route = valid_route(%{input_amount: Decimal.new("100.00")})

      assert :ok = SwapDispatchSafety.validate(route, context(intent))
    end
  end

  describe "native value gate" do
    test "rejects when route.value > 0 (v0.1 ERC20→ERC20 only)" do
      intent = swap_intent()
      route = valid_route(%{value: Decimal.new("1")})

      assert {:error, :swap_native_value_disallowed} =
               SwapDispatchSafety.validate(route, context(intent))
    end

    test "accepts route.value == 0" do
      intent = swap_intent()

      assert :ok =
               SwapDispatchSafety.validate(
                 valid_route(%{value: Decimal.new("0")}),
                 context(intent)
               )
    end
  end

  describe "universal pause gates" do
    test "rejects when the global runtime pause is set" do
      intent = swap_intent()
      {:ok, :paused} = Security.pause(:global)

      assert {:error, :runtime_paused} =
               SwapDispatchSafety.validate(valid_route(), context(intent))
    end

    test "rejects when the workspace+chain pause is set" do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "swap-pause",
          name: "Swap pause",
          mainnet_enabled: false
        })

      intent = swap_intent(%{workspace_id: ws.id})

      {:ok, :paused, _} =
        Bank.Security.Pauses.create_pause(ws.id, :chain, "base-sepolia",
          actor: :runtime,
          reason: "test"
        )

      assert {:error, :chain_paused} =
               SwapDispatchSafety.validate(valid_route(), context(intent))
    end

    test "global pause shadows the chain pause (existing pause precedence)" do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "swap-pause-precedence",
          name: "Swap pause precedence",
          mainnet_enabled: false
        })

      intent = swap_intent(%{workspace_id: ws.id})

      {:ok, :paused, _} =
        Bank.Security.Pauses.create_pause(ws.id, :chain, "base-sepolia",
          actor: :runtime,
          reason: "test"
        )

      {:ok, :paused} = Security.pause(:global)

      assert {:error, :runtime_paused} =
               SwapDispatchSafety.validate(valid_route(), context(intent))
    end
  end

  describe "mainnet capability gate" do
    test "rejects a mainnet route when workspace mainnet is disabled" do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "swap-no-mainnet",
          name: "Swap no mainnet",
          mainnet_enabled: false
        })

      intent = swap_intent(%{chain: "base", workspace_id: ws.id})
      route = valid_route(%{chain: "base", chain_id: 8453})

      # Caps must allow base for the route validator to pass shape
      # before the mainnet gate trips.
      assert {:error, :mainnet_disabled} =
               SwapDispatchSafety.validate(
                 route,
                 context(intent),
                 caps: %{
                   allowed_chains: ["base"],
                   allowed_assets: ["USDC"],
                   max_slippage_bps: 100
                 }
               )
    end

    test "allows a mainnet route when workspace mainnet is enabled" do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "swap-mainnet-on",
          name: "Swap mainnet on",
          mainnet_enabled: true
        })

      intent = swap_intent(%{chain: "base", workspace_id: ws.id})
      route = valid_route(%{chain: "base", chain_id: 8453})

      assert :ok =
               SwapDispatchSafety.validate(
                 route,
                 context(intent),
                 caps: %{
                   allowed_chains: ["base"],
                   allowed_assets: ["USDC"],
                   max_slippage_bps: 100
                 }
               )
    end
  end

  describe "fail-closed behaviour" do
    test "rejects a context without an AgentIntent struct" do
      assert {:error, :swap_route_field_missing} =
               SwapDispatchSafety.validate(valid_route(), %{intent: nil, workspace_id: nil})
    end

    test "rejects a non-map route" do
      intent = swap_intent()

      assert {:error, :swap_route_field_missing} =
               SwapDispatchSafety.validate("not a route", context(intent))
    end

    test "rejects when the intent has no amount (legacy / unscoped)" do
      attrs = %{kind: :swap, chain: "base-sepolia", amount: Decimal.new("100")}
      intent = agent_intent(attrs) |> Map.put(:amount, nil)

      assert match?(%AgentIntent{}, intent)

      assert {:error, :swap_amount_mismatch_with_intent} =
               SwapDispatchSafety.validate(valid_route(), context(intent))
    end
  end
end
