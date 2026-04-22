defmodule Bank.AutonomyStablecoinRouteTest do
  use ExUnit.Case, async: true

  alias Bank.Autonomy
  alias Bank.Policies.Evaluation
  alias Bank.Quotes.Preview

  defp base_inputs(stablecoin_route) do
    %{
      paused?: false,
      intent: %Bank.Intents.AgentIntent{
        asset: "USDC",
        chain: "base",
        amount: Decimal.new("50"),
        target_counterparty_id: Ecto.UUID.generate()
      },
      policy: %Evaluation{
        pass?: true,
        violations: [],
        autonomy_tier: :auto,
        constraints: %{},
        matched_rule_ids: []
      },
      trust: %{derived_trust: :trusted, confidence: :high},
      preview:
        {:ok,
         %Preview{
           balance_impact: %{"USDC" => Decimal.new("-50")},
           provider: "stub",
           generated_at: DateTime.utc_now(),
           freshness_ttl_seconds: 30
         }},
      screening: %{status: :not_applicable},
      stablecoin_route: stablecoin_route
    }
  end

  test "blocked stablecoin route blocks before trusted auto execution" do
    route = %{
      outcome: :block,
      reason_code: :stablecoin_route_blocked,
      reason: "Stablecoin route blocked: fee_above_threshold",
      execution_state: :blocked
    }

    decision = Autonomy.route(base_inputs(route))

    assert decision.outcome == :block
    assert decision.risk_tier == :severe
    assert decision.reason_code == :stablecoin_route_blocked
    assert decision.rationale.stablecoin_route.outcome == :block
  end

  test "approval-required stablecoin route prevents auto execution" do
    route = %{
      outcome: :approval_required,
      reason_code: :stablecoin_route_needs_approval,
      reason: "Stablecoin route requires approval: token_approval_only",
      execution_state: :requires_adapter
    }

    decision = Autonomy.route(base_inputs(route))

    assert decision.outcome == :approval_required
    assert decision.risk_tier == :elevated
    assert decision.reason_code == :stablecoin_route_needs_approval
    assert decision.rationale.stablecoin_route.execution_state == :requires_adapter
  end

  test "allowed stablecoin route annotates but preserves existing route outcome" do
    route = %{
      outcome: :auto_exec,
      reason_code: :stablecoin_route_allowed,
      reason: "Stablecoin route allowed",
      execution_state: :requires_adapter
    }

    decision = Autonomy.route(base_inputs(route))

    assert decision.outcome == :auto_exec
    assert decision.reason_code == :trusted_low_value
    assert decision.rationale.stablecoin_route.reason_code == :stablecoin_route_allowed
  end
end
