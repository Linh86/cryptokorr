defmodule Bank.AutonomyTest do
  use ExUnit.Case, async: true

  alias Bank.Autonomy
  alias Bank.Policies.Evaluation
  alias Bank.Quotes.Preview

  defp base_intent(overrides \\ %{}) do
    Map.merge(
      %Bank.Intents.AgentIntent{
        asset: "USDC",
        chain: "base",
        amount: Decimal.new("50"),
        target_counterparty_id: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp pass_eval(tier \\ :auto) do
    %Evaluation{
      pass?: true,
      violations: [],
      autonomy_tier: tier,
      constraints: %{},
      matched_rule_ids: []
    }
  end

  defp ok_preview(overrides \\ %{}) do
    Map.merge(
      %Preview{
        balance_impact: %{"USDC" => Decimal.new("-50")},
        provider: "stub",
        generated_at: DateTime.utc_now(),
        freshness_ttl_seconds: 30
      },
      overrides
    )
  end

  test "paused runtime emits :hold with :runtime_paused" do
    decision =
      Autonomy.route(%{
        paused?: true,
        intent: base_intent(),
        policy: pass_eval(),
        epistemic: %{derived_trust: :trusted, confidence: :high},
        preview: {:ok, ok_preview()}
      })

    assert decision.outcome == :hold
    assert decision.reason_code == :runtime_paused
  end

  test "policy violations block" do
    violations = [
      %{
        rule_id: Ecto.UUID.generate(),
        rule_type: :amount_limit,
        code: "amount_above_limit",
        message: "over limit",
        details: %{}
      }
    ]

    eval = %Evaluation{pass?: false, violations: violations, autonomy_tier: :auto}

    decision =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(),
        policy: eval,
        epistemic: %{derived_trust: :trusted, confidence: :high},
        preview: {:ok, ok_preview()}
      })

    assert decision.outcome == :block
    assert decision.risk_tier == :severe
  end

  test "provider unavailable holds" do
    decision =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(),
        policy: pass_eval(),
        epistemic: %{derived_trust: :trusted, confidence: :high},
        preview: {:error, :provider_unavailable}
      })

    assert decision.outcome == :hold
    assert decision.reason_code == :preview_unavailable
  end

  test "simulation failure blocks" do
    decision =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(),
        policy: pass_eval(),
        epistemic: %{derived_trust: :trusted, confidence: :high},
        preview: {:error, {:simulation_failed, "insufficient_liquidity"}}
      })

    assert decision.outcome == :block
    assert decision.reason_code == :simulation_failed
  end

  test "conflicted trust → approval_required with elevated risk" do
    decision =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(),
        policy: pass_eval(),
        epistemic: %{derived_trust: :conflicted, confidence: :low},
        preview: {:ok, ok_preview()}
      })

    assert decision.outcome == :approval_required
    assert decision.risk_tier == :elevated
  end

  test "sensitive → approval_required regardless of amount" do
    decision =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(%{amount: Decimal.new("5")}),
        policy: pass_eval(),
        epistemic: %{derived_trust: :sensitive, confidence: :medium},
        preview: {:ok, ok_preview()}
      })

    assert decision.outcome == :approval_required
  end

  test "unknown small amount → approval, large → block" do
    small =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(%{amount: Decimal.new("10")}),
        policy: pass_eval(),
        epistemic: %{derived_trust: :unknown, confidence: :low},
        preview: {:ok, ok_preview()}
      })

    big =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(%{amount: Decimal.new("500")}),
        policy: pass_eval(),
        epistemic: %{derived_trust: :unknown, confidence: :low},
        preview: {:ok, ok_preview()}
      })

    assert small.outcome == :approval_required
    assert big.outcome == :block
  end

  test "trusted + auto tier + under threshold → auto_exec" do
    decision =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(%{amount: Decimal.new("50")}),
        policy: pass_eval(:auto),
        epistemic: %{derived_trust: :trusted, confidence: :high},
        preview: {:ok, ok_preview()}
      })

    assert decision.outcome == :auto_exec
    assert decision.risk_tier == :low
  end

  test "trusted + manual tier → approval_required" do
    decision =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(%{amount: Decimal.new("50")}),
        policy: pass_eval(:manual),
        epistemic: %{derived_trust: :trusted, confidence: :high},
        preview: {:ok, ok_preview()}
      })

    assert decision.outcome == :approval_required
    assert decision.reason_code == :policy_manual_tier
  end

  test "to_envelope_attrs adds approval_expires_at only for approval_required" do
    attrs =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(%{amount: Decimal.new("50")}),
        policy: pass_eval(:manual),
        epistemic: %{derived_trust: :trusted, confidence: :high},
        preview: {:ok, ok_preview()}
      })
      |> Autonomy.to_envelope_attrs()

    assert %DateTime{} = attrs.approval_expires_at

    auto_attrs =
      Autonomy.route(%{
        paused?: false,
        intent: base_intent(%{amount: Decimal.new("50")}),
        policy: pass_eval(:auto),
        epistemic: %{derived_trust: :trusted, confidence: :high},
        preview: {:ok, ok_preview()}
      })
      |> Autonomy.to_envelope_attrs()

    refute Map.get(auto_attrs, :approval_expires_at)
  end
end
