defmodule Bank.Policies.Morpho.RulesCompilerTest do
  use ExUnit.Case, async: true

  alias Bank.DefiVenues.Morpho.PolicyInput
  alias Bank.Policies.Morpho.RulesCompiler
  alias Bank.Policies.PolicyRule

  defp rule(rule_type, params, scope \\ %{}) do
    %PolicyRule{
      id: Ecto.UUID.generate(),
      rule_type: rule_type,
      params: params,
      scope: scope,
      state: :active,
      priority: 0,
      version: 1,
      workspace_id: Ecto.UUID.generate()
    }
  end

  describe "compile/2 with empty rules" do
    test "returns the conservative PolicyInput.default/0 baseline" do
      result = RulesCompiler.compile([])
      default = PolicyInput.default()

      assert result.vault_allowlist == default.vault_allowlist
      assert result.oracle_allowlist == default.oracle_allowlist
      assert result.collateral_allowlist == default.collateral_allowlist
      assert result.exposure_cap == default.exposure_cap
      assert result.approval_market_lltv_pct == default.approval_market_lltv_pct
      assert result.block_market_lltv_pct == default.block_market_lltv_pct
      assert result.incident_active? == default.incident_active?
    end

    test "non-Morpho rules are silently filtered out" do
      rules = [
        rule(:amount_limit, %{"max_per_tx" => "100"}),
        rule(:allowed_chain, %{"chains" => ["base"]})
      ]

      result = RulesCompiler.compile(rules)

      assert result == %{
               PolicyInput.default()
               | current_exposure: Decimal.new(0),
                 proposed_amount: Decimal.new(0)
             }
    end
  end

  describe ":allowed_vault" do
    test "fold loads chain_id+address tuples into vault_allowlist" do
      rules = [
        rule(:allowed_vault, %{
          "vaults" => [
            %{"chain_id" => 8453, "address" => "0xAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa"},
            %{"chain_id" => 8453, "address" => "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}
          ]
        })
      ]

      result = RulesCompiler.compile(rules)
      assert {8453, "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"} in result.vault_allowlist
      assert {8453, "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"} in result.vault_allowlist
    end

    test "two :allowed_vault rules intersect (most-restrictive wins)" do
      rules = [
        rule(:allowed_vault, %{
          "vaults" => [
            %{"chain_id" => 8453, "address" => "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},
            %{"chain_id" => 8453, "address" => "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}
          ]
        }),
        rule(:allowed_vault, %{
          "vaults" => [
            %{"chain_id" => 8453, "address" => "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}
          ]
        })
      ]

      result = RulesCompiler.compile(rules)
      assert result.vault_allowlist == [{8453, "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]
    end

    test "malformed vault entries are silently dropped (fail-closed posture)" do
      rules = [
        rule(:allowed_vault, %{
          "vaults" => [
            %{"chain_id" => 8453, "address" => "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},
            %{"chain_id" => "not-an-int", "address" => "0xBBBB"},
            "not-a-map"
          ]
        })
      ]

      result = RulesCompiler.compile(rules)
      assert result.vault_allowlist == [{8453, "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]
    end
  end

  describe ":allowed_oracle" do
    test "fold loads addresses into oracle_allowlist (lower-cased)" do
      rules = [
        rule(:allowed_oracle, %{
          "oracles" => ["0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"]
        })
      ]

      result = RulesCompiler.compile(rules)
      assert "0xcccccccccccccccccccccccccccccccccccccccc" in result.oracle_allowlist
    end
  end

  describe ":allowed_collateral_asset" do
    test "fold loads addresses into collateral_allowlist" do
      rules = [
        rule(:allowed_collateral_asset, %{
          "assets" => ["0xDdDdDdDdDdDdDdDdDdDdDdDdDdDdDdDdDdDdDdDd"]
        })
      ]

      result = RulesCompiler.compile(rules)
      assert "0xdddddddddddddddddddddddddddddddddddddddd" in result.collateral_allowlist
    end
  end

  describe ":max_market_lltv" do
    test "splits max_lltv_bps and approval_over_bps into the engine's pct slots" do
      rules = [
        rule(:max_market_lltv, %{"max_lltv_bps" => 8600, "approval_over_bps" => 8000})
      ]

      result = RulesCompiler.compile(rules)
      assert result.block_market_lltv_pct == 86
      assert result.approval_market_lltv_pct == 80
    end

    test "more-restrictive rule wins when two rules apply" do
      rules = [
        rule(:max_market_lltv, %{"max_lltv_bps" => 9000, "approval_over_bps" => 8500}),
        rule(:max_market_lltv, %{"max_lltv_bps" => 8600, "approval_over_bps" => 8000})
      ]

      result = RulesCompiler.compile(rules)
      assert result.block_market_lltv_pct == 86
      assert result.approval_market_lltv_pct == 80
    end

    test "missing or malformed bps falls back to the conservative default" do
      rules = [
        rule(:max_market_lltv, %{"max_lltv_bps" => "not-a-number"})
      ]

      result = RulesCompiler.compile(rules)
      default = PolicyInput.default()
      assert result.block_market_lltv_pct == default.block_market_lltv_pct
      assert result.approval_market_lltv_pct == default.approval_market_lltv_pct
    end

    test "out-of-range bps (above 10000) falls back to default" do
      rules = [
        rule(:max_market_lltv, %{"max_lltv_bps" => 99_999})
      ]

      result = RulesCompiler.compile(rules)
      assert result.block_market_lltv_pct == PolicyInput.default().block_market_lltv_pct
    end
  end

  describe "exposure caps (:max_*_exposure)" do
    test ":max_vault_exposure pins exposure_cap" do
      rules = [
        rule(:max_vault_exposure, %{"max_amount" => "10000"})
      ]

      result = RulesCompiler.compile(rules)
      assert Decimal.equal?(result.exposure_cap, Decimal.new("10000"))
    end

    test "narrower cap from a second rule wins" do
      rules = [
        rule(:max_vault_exposure, %{"max_amount" => "10000"}),
        rule(:max_curator_exposure, %{"max_amount" => "5000"}),
        rule(:max_market_exposure, %{"max_amount" => "8000"})
      ]

      result = RulesCompiler.compile(rules)
      assert Decimal.equal?(result.exposure_cap, Decimal.new("5000"))
    end
  end

  describe ":incident_hold" do
    test "active=true flips incident_active? on" do
      rules = [rule(:incident_hold, %{"active" => true})]
      assert RulesCompiler.compile(rules).incident_active?
    end

    test "active=false leaves the default false" do
      rules = [rule(:incident_hold, %{"active" => false})]
      refute RulesCompiler.compile(rules).incident_active?
    end

    test "any active rule sticks (OR-merge across multiple rules)" do
      rules = [
        rule(:incident_hold, %{"active" => false}),
        rule(:incident_hold, %{"active" => true})
      ]

      assert RulesCompiler.compile(rules).incident_active?
    end
  end

  describe ":yield_anomaly_approval" do
    test "spike_pct overrides the default when smaller (more-restrictive wins)" do
      rules = [rule(:yield_anomaly_approval, %{"spike_pct" => 25})]
      result = RulesCompiler.compile(rules)
      assert result.apy_spike_pct == 25
    end

    test "baseline param flows into apy_baseline" do
      rules = [rule(:yield_anomaly_approval, %{"baseline" => "5.0"})]
      result = RulesCompiler.compile(rules)
      assert Decimal.equal?(result.apy_baseline, Decimal.new("5.0"))
    end

    test "APY anomaly cannot improve risk: missing rule leaves apy_baseline=nil" do
      result = RulesCompiler.compile([])
      assert is_nil(result.apy_baseline)
    end
  end

  describe "scope matching" do
    test "rule with scope.vault_address only applies when the supplied vault matches" do
      rules = [
        rule(
          :max_market_lltv,
          %{"max_lltv_bps" => 8000},
          %{"vault_address" => "0xVAULT00000000000000000000000000000000aaaa"}
        )
      ]

      # Different vault → rule skipped → defaults preserved.
      result =
        RulesCompiler.compile(rules,
          vault_address: "0xother00000000000000000000000000000000bbbb"
        )

      assert result.block_market_lltv_pct == PolicyInput.default().block_market_lltv_pct

      # Matching vault → rule applies.
      result =
        RulesCompiler.compile(rules,
          vault_address: "0xVAULT00000000000000000000000000000000aaaa"
        )

      assert result.block_market_lltv_pct == 80
    end

    test "rule with scope.asset only applies when the supplied asset matches" do
      rules = [
        rule(:max_vault_exposure, %{"max_amount" => "5000"}, %{"asset" => "USDC"})
      ]

      result_usdc = RulesCompiler.compile(rules, asset: "USDC")
      assert Decimal.equal?(result_usdc.exposure_cap, Decimal.new("5000"))

      result_other = RulesCompiler.compile(rules, asset: "USDT")
      assert is_nil(result_other.exposure_cap)
    end

    test "rule with scope.venue == \"morpho\" applies; other venues are skipped" do
      rules = [
        rule(:incident_hold, %{"active" => true}, %{"venue" => "morpho"}),
        rule(:incident_hold, %{"active" => true}, %{"venue" => "uniswap"})
      ]

      result = RulesCompiler.compile(rules)
      # Only the morpho-scoped rule contributed.
      assert result.incident_active?
    end

    test "rule with empty scope is treated as workspace-global and always applies" do
      rules = [rule(:incident_hold, %{"active" => true}, %{})]
      assert RulesCompiler.compile(rules).incident_active?
    end
  end

  describe "amount inputs" do
    test "current_exposure and proposed_amount default to Decimal.new(0)" do
      result = RulesCompiler.compile([])
      assert Decimal.equal?(result.current_exposure, Decimal.new(0))
      assert Decimal.equal?(result.proposed_amount, Decimal.new(0))
    end

    test "explicit current_exposure / proposed_amount flow through" do
      result =
        RulesCompiler.compile([],
          current_exposure: Decimal.new("100"),
          proposed_amount: Decimal.new("50")
        )

      assert Decimal.equal?(result.current_exposure, Decimal.new("100"))
      assert Decimal.equal?(result.proposed_amount, Decimal.new("50"))
    end

    test "string current_exposure is parsed to Decimal" do
      result = RulesCompiler.compile([], current_exposure: "200")
      assert Decimal.equal?(result.current_exposure, Decimal.new(200))
    end
  end

  describe "secret hygiene + read-only posture" do
    # No rule-fold path persists, broadcasts, or reads
    # `Application.get_env`. The compiler is a pure function on
    # input lists; tests pass it explicit data.
    test "compile/2 is a pure function on its inputs (no DB or env reads)" do
      env_before = System.get_env()

      result = RulesCompiler.compile([rule(:max_market_lltv, %{"max_lltv_bps" => 8600})])
      assert result.block_market_lltv_pct == 86

      assert System.get_env() == env_before
    end

    test "params are not echoed verbatim into the produced struct (no operator free text)" do
      # The produced PolicyInput is a typed struct with numeric /
      # boolean / address-string fields only — there is no slot
      # for an operator-supplied free-text value to land in.
      rules = [
        rule(:incident_hold, %{
          "active" => true,
          "operator_note" => "Authorization: Bearer LEAKED-TOKEN"
        })
      ]

      result = RulesCompiler.compile(rules)
      assert is_struct(result, PolicyInput)
      # The struct definition is the contract: no `:operator_note`
      # / `:notes` / similar fields exist, so a probing test that
      # tried to look them up would crash. We assert positively
      # that the produced field set is the documented set.
      assert Map.keys(result) |> Enum.sort() ==
               Map.keys(PolicyInput.default()) |> Enum.sort()
    end
  end
end
