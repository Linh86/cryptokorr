defmodule Bank.AcceptanceTest do
  @moduledoc """
  End-to-end acceptance scenarios mapped to the v0.1 MVP memo:

    * trusted low-value transfer → `:auto_exec`
    * trusted high-value transfer → `:approval_required`
    * unknown address → `:block` (over ceiling) or `:approval_required`
      (under ceiling)
    * conflicted evidence → `:approval_required`, risk `:elevated`
    * slippage-bound swap simulation failure → `:block`
    * revoked delegation / paused runtime → no `:auto_exec`

  These assemble the full routing inputs (intent + policy eval +
  epistemic claim + preview) and drive `Bank.Autonomy.route/2`. They
  deliberately exercise the decision surface, not the persistence
  wiring — per the ticket, "prefer high-signal checks over broad
  unfinished test infrastructure."
  """

  use ExUnit.Case, async: true

  alias Bank.Autonomy
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.Evaluation
  alias Bank.Quotes.Preview

  defp intent(overrides \\ %{}) do
    Map.merge(
      %AgentIntent{
        asset: "USDC",
        chain: "base",
        kind: :transfer,
        amount: Decimal.new("50"),
        target_counterparty_id: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp policy_pass(tier \\ :auto) do
    %Evaluation{
      pass?: true,
      violations: [],
      autonomy_tier: tier,
      constraints: %{},
      matched_rule_ids: []
    }
  end

  defp preview_ok(overrides \\ %{}) do
    {:ok,
     Map.merge(
       %Preview{
         balance_impact: %{"USDC" => Decimal.new("-50")},
         provider: "stub",
         generated_at: DateTime.utc_now(),
         freshness_ttl_seconds: 30
       },
       overrides
     )}
  end

  describe "memo scenarios" do
    test "trusted low-value transfer auto-executes" do
      decision =
        Autonomy.route(%{
          paused?: false,
          intent: intent(%{amount: Decimal.new("25")}),
          policy: policy_pass(:auto),
          epistemic: %{derived_trust: :trusted, confidence: :high},
          preview: preview_ok()
        })

      assert decision.outcome == :auto_exec
      assert decision.risk_tier == :low
    end

    test "trusted high-value transfer requires approval" do
      decision =
        Autonomy.route(%{
          paused?: false,
          intent: intent(%{amount: Decimal.new("5000")}),
          policy: policy_pass(:manual),
          epistemic: %{derived_trust: :trusted, confidence: :high},
          preview: preview_ok()
        })

      assert decision.outcome == :approval_required
    end

    test "unknown address over ceiling blocks" do
      decision =
        Autonomy.route(%{
          paused?: false,
          intent: intent(%{amount: Decimal.new("500"), target_counterparty_id: nil}),
          policy: policy_pass(),
          epistemic: %{derived_trust: :unknown, confidence: :low},
          preview: preview_ok()
        })

      assert decision.outcome == :block
      assert decision.reason_code in [:unknown_over_ceiling, :unknown_without_amount]
    end

    test "unknown address under ceiling routes to approval" do
      decision =
        Autonomy.route(%{
          paused?: false,
          intent: intent(%{amount: Decimal.new("10"), target_counterparty_id: nil}),
          policy: policy_pass(),
          epistemic: %{derived_trust: :unknown, confidence: :low},
          preview: preview_ok()
        })

      assert decision.outcome == :approval_required
      assert decision.reason_code == :trust_unknown
    end

    test "conflicted evidence forces elevated approval" do
      decision =
        Autonomy.route(%{
          paused?: false,
          intent: intent(),
          policy: policy_pass(),
          epistemic: %{derived_trust: :conflicted, confidence: :low},
          preview: preview_ok()
        })

      assert decision.outcome == :approval_required
      assert decision.risk_tier == :elevated
    end

    test "slippage-bound swap simulation failure blocks" do
      swap_intent = intent(%{kind: :swap, amount: Decimal.new("500")})

      decision =
        Autonomy.route(%{
          paused?: false,
          intent: swap_intent,
          policy: policy_pass(:auto),
          epistemic: %{derived_trust: :trusted, confidence: :high},
          preview: {:error, {:simulation_failed, "slippage_exceeded"}}
        })

      assert decision.outcome == :block
      assert decision.reason_code == :simulation_failed
    end

    test "paused runtime prevents auto-execution even for trusted+auto" do
      decision =
        Autonomy.route(%{
          paused?: true,
          intent: intent(%{amount: Decimal.new("10")}),
          policy: policy_pass(:auto),
          epistemic: %{derived_trust: :trusted, confidence: :high},
          preview: preview_ok()
        })

      assert decision.outcome == :hold
      assert decision.reason_code == :runtime_paused
    end

    test "provider outage degrades to hold, not silent execution" do
      decision =
        Autonomy.route(%{
          paused?: false,
          intent: intent(),
          policy: policy_pass(:auto),
          epistemic: %{derived_trust: :trusted, confidence: :high},
          preview: {:error, :provider_unavailable}
        })

      assert decision.outcome == :hold
      assert decision.reason_code == :preview_unavailable
    end
  end
end
