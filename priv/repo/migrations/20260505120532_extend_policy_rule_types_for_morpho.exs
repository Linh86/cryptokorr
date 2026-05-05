defmodule Bank.Repo.Migrations.ExtendPolicyRuleTypesForMorpho do
  use Ecto.Migration

  @moduledoc """
  Extends the `policy_rules.rule_type` CHECK constraint with the
  Morpho/DeFi rule type vocabulary added by #202.

  ## Why a constraint swap, not a column rewrite

  `rule_type` is a `text` column with a CHECK constraint pinning it
  to the v1 enum. Adding new rule types is a constraint-only
  change: no row data is rewritten, no per-row scan is needed.
  PostgreSQL re-evaluates the constraint against existing rows,
  but every existing row carries one of the v1 types so the
  validation is a no-op.

  ## v1 vocabulary (preserved)

      amount_limit, rolling_spend_cap, slippage_ceiling,
      allowed_router, allowed_asset, allowed_chain, autonomy_tier,
      time_window

  ## #202 additions (16 new Morpho types)

      allowed_defi_venue, allowed_vault, allowed_curator,
      allowed_collateral_asset, allowed_oracle, max_vault_exposure,
      max_curator_exposure, max_market_exposure,
      max_collateral_exposure, max_oracle_exposure,
      max_market_lltv, min_vault_liquidity, min_timelock_seconds,
      deny_morpho_warning, incident_hold, yield_anomaly_approval

  Folding-into-`Bank.DefiVenues.Morpho.PolicyInput` semantics live
  in `Bank.Policies.Morpho.RulesCompiler`. The existing
  non-Morpho evaluator skips these rule types as `:not_applicable`
  for non-Morpho intent kinds, preserving #202's
  *"existing non-DeFi policy behavior is not regressed"* acceptance
  bullet.
  """

  @v1_types ~w(
    amount_limit rolling_spend_cap slippage_ceiling allowed_router
    allowed_asset allowed_chain autonomy_tier time_window
  )

  @morpho_types ~w(
    allowed_defi_venue allowed_vault allowed_curator
    allowed_collateral_asset allowed_oracle max_vault_exposure
    max_curator_exposure max_market_exposure max_collateral_exposure
    max_oracle_exposure max_market_lltv min_vault_liquidity
    min_timelock_seconds deny_morpho_warning incident_hold
    yield_anomaly_approval
  )

  @all_types @v1_types ++ @morpho_types

  def up do
    drop constraint(:policy_rules, :rule_type_valid)

    create constraint(:policy_rules, :rule_type_valid,
             check: "rule_type IN (#{quoted_list(@all_types)})"
           )
  end

  def down do
    drop constraint(:policy_rules, :rule_type_valid)

    create constraint(:policy_rules, :rule_type_valid,
             check: "rule_type IN (#{quoted_list(@v1_types)})"
           )
  end

  defp quoted_list(types) do
    types
    |> Enum.map(&"'#{&1}'")
    |> Enum.join(",")
  end
end
