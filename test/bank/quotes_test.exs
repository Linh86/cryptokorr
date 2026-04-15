defmodule Bank.QuotesTest do
  use Bank.DataCase, async: true

  alias Bank.Fixtures
  alias Bank.Quotes
  alias Bank.Quotes.{Persistence, Preview, StubProvider}

  describe "preview/2 — happy path" do
    test "returns a populated preview for a transfer" do
      intent = Fixtures.agent_intent(kind: :transfer, asset: "USDC", chain: "base")
      assert {:ok, %Preview{} = preview} = Quotes.preview(intent, provider: StubProvider)
      assert Map.get(preview.balance_impact, "USDC")
      assert preview.estimated_gas == 120_000
      refute preview.slippage_bps
      assert preview.provider == "stub"
    end

    test "returns a preview with slippage for swaps" do
      intent = Fixtures.agent_intent(kind: :swap, asset: "USDC", chain: "base")

      assert {:ok, %Preview{slippage_bps: bps, expected_output: out}} =
               Quotes.preview(intent, provider: StubProvider)

      assert is_integer(bps) and bps > 0
      assert %Decimal{} = out
    end
  end

  describe "preview/2 — degraded posture" do
    test "provider_unavailable is surfaced as-is" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:error, :provider_unavailable} =
               Quotes.preview(intent, provider: StubProvider, outcome: :unavailable)
    end

    test "simulation_failed carries the reason" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:error, {:simulation_failed, "insufficient_liquidity"}} =
               Quotes.preview(intent,
                 provider: StubProvider,
                 outcome: {:simulation_failed, "insufficient_liquidity"}
               )
    end

    test "unsupported chain is rejected before hitting the provider" do
      intent = Fixtures.agent_intent(chain: "ethereum")
      assert {:error, {:unsupported, _}} = Quotes.preview(intent, provider: StubProvider)
    end
  end

  describe "stale?/2" do
    test "returns true once the freshness TTL has elapsed" do
      preview = %Preview{
        generated_at: ~U[2026-04-01 00:00:00.000000Z],
        freshness_ttl_seconds: 30,
        provider: "stub"
      }

      refute Quotes.stale?(preview, ~U[2026-04-01 00:00:15.000000Z])
      assert Quotes.stale?(preview, ~U[2026-04-01 00:00:35.000000Z])
    end
  end

  describe "persistence" do
    test "to_simulation_attrs/4 shapes the preview for simulation_reports" do
      intent = Fixtures.agent_intent(kind: :transfer, asset: "USDC", chain: "base")
      {:ok, preview} = Quotes.preview(intent, provider: StubProvider)

      attrs = Persistence.to_simulation_attrs(preview, intent.id, :completed, chain: "base")

      assert attrs.intent_id == intent.id
      assert attrs.provider == "stub"
      assert attrs.status == :completed
      assert %{"items" => items} = attrs.predicted_balance_changes
      assert [_ | _] = items
    end
  end
end
