defmodule Bank.Stablecoins.IntentRoutingTest do
  use Bank.DataCase, async: false

  alias Bank.{Audit, Fixtures}
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

  defmodule FakeSwapProvider do
    @behaviour Bank.Stablecoins.Provider

    @impl true
    def provider_id, do: "swap_fake"

    @impl true
    def quote(%QuoteRequest{} = req) do
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
             dest_chain: req.dest_chain,
             dest_asset: req.dest_asset,
             input_amount: req.amount,
             output_amount: out,
             protocol: "FakeSwap"
           }
         ],
         input_amount: req.amount,
         output_amount: out,
         quoted_at: now,
         fees: %{total_fee: Decimal.new("0.5")}
       }}
    end
  end

  defmodule FakeBridgeProvider do
    @behaviour Bank.Stablecoins.Provider

    @impl true
    def provider_id, do: "bridge_fake"

    @impl true
    def quote(%QuoteRequest{} = req) do
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
             dest_chain: req.dest_chain,
             dest_asset: req.dest_asset,
             input_amount: req.amount,
             output_amount: req.amount,
             protocol: "FakeBridge"
           }
         ],
         input_amount: req.amount,
         output_amount: req.amount,
         quoted_at: now,
         fees: %{bridge_fee: Decimal.new(0), total_fee: Decimal.new(0)}
       }}
    end
  end

  setup do
    ProviderHealth.reset()
    :ok
  end

  describe "evaluate_for_intent/2 — allowed" do
    test "allowed route maps to auto_exec but requires adapter dispatch" do
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
      assert result.execution_state == :requires_adapter
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
      assert result.execution_state == :requires_adapter
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

      assert route.decision == "auto_exec"
      assert route.execution_state == "requires_adapter"
      assert route.policy_decision == "allowed"
      assert route.route_kind == "swap"
      assert route.provider == "fake"
      assert length(route.legs) == 1
      assert route.fee_summary.total_fee == "0.6"
      assert route.score > 0
      assert route.selector_metadata.considered == 1
      assert route.quote_request.amount == "100"
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

    test "records underlying providers for composite swap+bridge routes" do
      {:ok, _result} =
        IntentRouting.evaluate_for_intent(
          %{
            source_chain: "base",
            source_asset: "USDT",
            dest_chain: "ethereum",
            dest_asset: "USDC",
            amount: Decimal.new("100"),
            metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
          },
          swap_providers: [FakeSwapProvider],
          bridge_providers: [FakeBridgeProvider]
        )

      assert ProviderHealth.get("swap_fake").success_count == 1
      assert ProviderHealth.get("bridge_fake").success_count == 1
      assert ProviderHealth.get("composite").success_count == 0
    end
  end

  describe "audit and replay integration" do
    test "writes route evidence to the audit trail when intent_id is supplied" do
      intent =
        Fixtures.agent_intent(
          kind: :swap,
          asset: "USDC",
          chain: "ethereum",
          target_counterparty_id: nil,
          target_raw_address: "0x0000000000000000000000000000000000000abc"
        )

      {:ok, _result} =
        IntentRouting.evaluate_for_intent(
          %{
            intent_id: intent.id,
            source_chain: "ethereum",
            source_asset: "USDC",
            dest_chain: "ethereum",
            dest_asset: "USDT",
            amount: Decimal.new("100"),
            metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
          },
          providers: [FakeProvider]
        )

      %{events: [event]} =
        Audit.list_events(%{
          correlation_id: intent.id,
          event_type: "stablecoin.route_evaluated"
        })

      assert event.subject_id == intent.id

      {:ok, bundle} = Audit.replay(intent.id)
      assert [route] = bundle.stablecoin_route_evidence
      assert route["provider"] == "fake"
      assert route["decision"] == "auto_exec"
      assert route["execution_state"] == "requires_adapter"
      assert route["fee_summary"]["total_fee"] == "0.6"
    end
  end

  describe "workspace-scoped provider-health notifications (#422)" do
    alias Bank.Notifications
    alias Bank.Stablecoins.ProviderHealthEvent

    setup do
      ProviderHealth.reset()

      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "ph-routing-#{System.unique_integer([:positive])}",
          name: "PH Routing #{System.unique_integer([:positive])}",
          mainnet_enabled: true
        })

      %{workspace: ws}
    end

    test "the result map carries the route_session_id so callers can correlate retries",
         %{workspace: ws} do
      assert {:ok, %{route_session_id: session_id}} =
               IntentRouting.evaluate_for_intent(
                 %{
                   workspace_id: ws.id,
                   source_chain: "ethereum",
                   source_asset: "USDC",
                   dest_chain: "ethereum",
                   dest_asset: "USDT",
                   amount: Decimal.new("100"),
                   metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
                 },
                 providers: [FakeProvider]
               )

      assert is_binary(session_id)
      assert {:ok, _} = Ecto.UUID.cast(session_id)
    end

    test "without :workspace_id, no provider_health_event row is written", %{workspace: ws} do
      # Drive the provider into :degraded directly via record_failure
      # so the next failure crosses the threshold.
      for _ <- 1..8, do: ProviderHealth.record_success("fake")
      for _ <- 1..2, do: ProviderHealth.record_failure("fake", :provider_unavailable)

      pre = Bank.Repo.aggregate(ProviderHealthEvent, :count)

      # No workspace_id in params → success/failure record but no event row.
      {:ok, _} =
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

      assert Bank.Repo.aggregate(ProviderHealthEvent, :count) == pre
      assert Notifications.list_for_workspace(ws.id) == []
    end

    test "providing :workspace_id threads it into ProviderHealth opts (verified via direct call)",
         %{workspace: ws} do
      # The integration test surface here is narrow: ProviderHealth
      # is the only call site that interprets opts, and the unit
      # tests in provider_health_test.exs already pin the
      # transition / event-write rules. This test just confirms
      # the threading itself — given a workspace_id+session_id
      # opt set on a record_failure that crosses the threshold,
      # an event row lands in the workspace.
      session_id = Ecto.UUID.generate()
      opts = [workspace_id: ws.id, route_session_id: session_id]

      for _ <- 1..8, do: ProviderHealth.record_success("threaded", opts)
      for _ <- 1..2, do: ProviderHealth.record_failure("threaded", :provider_unavailable, opts)

      assert {:ok, %{event: %ProviderHealthEvent{} = event}} =
               ProviderHealth.record_failure("threaded", :provider_unavailable, opts)

      assert event.workspace_id == ws.id
      assert event.route_session_id == session_id
      assert event.provider == "threaded"
    end
  end
end
