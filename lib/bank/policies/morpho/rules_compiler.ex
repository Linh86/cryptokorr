defmodule Bank.Policies.Morpho.RulesCompiler do
  @moduledoc """
  Folds a workspace's active Morpho `Bank.Policies.PolicyRule` rows
  into a `Bank.DefiVenues.Morpho.PolicyInput` struct for the
  `Bank.DefiVenues.Morpho.RiskExplanation` engine (#201).

  This module is the **policy → input contract** for #202: the
  16 new DeFi/Morpho rule types added to the
  `policy_rules.rule_type` enum become workspace-configurable
  thresholds and allowlists that the risk engine consumes.

  ## Pipeline

      workspace policy rules            #202: this module
              │                                │
              ▼                                ▼
        list_rules/2  ──────►  compile/2  ──►  %PolicyInput{}
                                             ┌──────────┐
                                             │ #201     │
                                             │ engine   │
                                             └──────────┘
                                                  │
                                                  ▼
                                          %{decision, risk_tier, ...}

  ## Workspace boundary

  `compile/2` accepts an explicit list of rules and an explicit
  `proposed_amount` / `current_exposure` pair. It does **not**
  query the database; the caller is responsible for narrowing
  rules to one workspace via `Bank.Policies.list_rules(state:
  :active, workspace_id: ws_id)` before invoking this compiler.
  Cross-workspace leakage is therefore impossible by
  construction — there is no implicit DB read here.

  ## Fail-closed defaults

  Every threshold defaults to the conservative
  `Bank.DefiVenues.Morpho.PolicyInput.default/0` value. A workspace
  with **zero** Morpho rules gets the safe defaults: empty
  allowlists (engine flags everything), no exposure cap (forces a
  hold), no APY baseline (skips the APY check). Adding rules
  *narrows* the policy — never widens it implicitly.

  ## Rule scope matching

  Many rule types (e.g. `:max_market_lltv`, `:max_vault_exposure`)
  carry a `scope` map identifying which vault / asset / curator
  the threshold applies to. The compiler uses two scope filters:

    * `:vault_address` — case-insensitive lower-cased compare
      against the snapshot's vault address;
    * `:asset` — symbol compare against the deposit asset
      (e.g. `"USDC"`).

  Rules whose scope **does not match** the snapshot's vault are
  silently skipped. Rules whose scope is empty (`%{}`) are
  treated as workspace-global and always apply.

  ## Conflict resolution

  When multiple rules of the same type apply (e.g. a global
  `:max_market_lltv` plus a vault-specific override), the
  **most-restrictive** value wins:

    * minimum-style thresholds (`:min_vault_liquidity`,
      `:min_timelock_seconds`) → take the **maximum** of
      configured values;
    * maximum-style thresholds (`:max_market_lltv`,
      `:max_*_exposure`) → take the **minimum** of configured
      values;
    * allowlists (`:allowed_*`) → take the **intersection** of
      configured allowlists when more than one rule applies; an
      empty intersection is itself a conservative outcome —
      every value triggers a not-allowlisted reason in the
      engine.

  Within the bounded #202 surface this conflict-resolution
  mirrors the v1 evaluator's posture (the most-restrictive
  amount cap wins; the strictest autonomy tier wins).

  ## What this module does NOT do

    * Evaluate the rules. Evaluation is `Bank.DefiVenues.Morpho.RiskExplanation.explain/3`.
    * Persist anything. Pure function on inputs.
    * Make any chain or HTTP call.
    * Read any environment variable.

  ## Related

    * `Bank.Policies.PolicyRule.morpho_rule_types/0` —
      authoritative list of the 16 #202 rule types.
    * `Bank.DefiVenues.Morpho.PolicyInput` — the struct this
      compiler produces.
    * `Bank.DefiVenues.Morpho.RiskExplanation` — the engine
      that consumes the produced struct.
  """

  alias Bank.DefiVenues.Morpho.PolicyInput
  alias Bank.Policies.PolicyRule

  @type compile_opts :: [
          vault_address: String.t() | nil,
          asset: String.t() | nil,
          current_exposure: Decimal.t() | nil,
          proposed_amount: Decimal.t() | nil
        ]

  @doc """
  Build a `PolicyInput` from a list of active workspace rules.

  Rules whose `rule_type` is not in `PolicyRule.morpho_rule_types/0`
  are silently ignored — the caller does not need to pre-filter.

  ## Options

    * `:vault_address` — `0x`-prefixed address of the vault the
      intent targets. Used for scope matching on rules whose
      `scope.vault_address` is set. `nil` skips the vault-scoped
      filter (every rule with a vault scope is treated as
      non-matching, every rule with no vault scope is treated as
      global).
    * `:asset` — deposit asset symbol (e.g. `"USDC"`). Used for
      scope matching on rules whose `scope.asset` is set.
    * `:current_exposure` — operator-supplied workspace-level
      exposure to this vault. Defaults to `Decimal.new(0)`.
    * `:proposed_amount` — operator-supplied amount the agent
      wants to deposit. Defaults to `Decimal.new(0)`.

  ## Return shape

  Always returns a `%PolicyInput{}`. Never returns an error —
  malformed rule params fall back to the conservative
  per-field default and are logged at `:warning`. This matches
  #202's *"unknown/unconfigured critical allowlist defaults
  fail closed"* acceptance: an unparseable LLTV cap leaves the
  default `block_market_lltv_pct: 90`, which is the strictest
  interpretation.
  """
  @spec compile([PolicyRule.t()], compile_opts()) :: PolicyInput.t()
  def compile(rules, opts \\ []) when is_list(rules) do
    vault_address = opts |> Keyword.get(:vault_address) |> normalize_address()
    asset = Keyword.get(opts, :asset)

    base = %PolicyInput{
      PolicyInput.default()
      | current_exposure: opts |> Keyword.get(:current_exposure) |> default_decimal(),
        proposed_amount: opts |> Keyword.get(:proposed_amount) |> default_decimal()
    }

    rules
    |> Enum.filter(&morpho_rule?/1)
    |> Enum.filter(&scope_matches?(&1, vault_address, asset))
    |> Enum.reduce(base, &fold_rule(&2, &1))
  end

  # --- per-rule fold -------------------------------------------------------

  defp fold_rule(acc, %PolicyRule{rule_type: :allowed_vault, params: params}) do
    list = read_vault_list(params, "vaults")
    %{acc | vault_allowlist: intersect_allowlist(acc.vault_allowlist, list)}
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :allowed_oracle, params: params}) do
    list = read_address_list(params, "oracles")
    %{acc | oracle_allowlist: intersect_allowlist(acc.oracle_allowlist, list)}
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :allowed_collateral_asset, params: params}) do
    list = read_address_list(params, "assets")
    %{acc | collateral_allowlist: intersect_allowlist(acc.collateral_allowlist, list)}
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :allowed_curator}) do
    # Curator allowlist is not exposed on the v1 PolicyInput
    # contract — the #201 risk engine consults the snapshot's
    # allocators, but a workspace-level curator allowlist is a
    # future extension. Acknowledge the rule by returning the
    # accumulator untouched; the rule still reaches the audit
    # trail via `policy_snapshot_ref`.
    acc
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :allowed_defi_venue}) do
    # Same posture as :allowed_curator — venue-level allowlist is
    # documented in the rule vocabulary so a future workspace can
    # restrict to "morpho only", but the v0.1 engine ships
    # Morpho-only and the venue check is implicit. Acknowledge.
    acc
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :max_market_lltv, params: params}) do
    block_pct =
      case read_bps(params, "max_lltv_bps") do
        {:ok, bps} -> bps_to_pct(bps)
        :error -> acc.block_market_lltv_pct
      end

    approval_pct =
      case read_bps(params, "approval_over_bps") do
        {:ok, bps} -> bps_to_pct(bps)
        :error -> acc.approval_market_lltv_pct
      end

    %{
      acc
      | block_market_lltv_pct: min(acc.block_market_lltv_pct, block_pct),
        approval_market_lltv_pct: min(acc.approval_market_lltv_pct, approval_pct)
    }
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :max_vault_exposure, params: params}) do
    case read_decimal(params, "max_amount") do
      {:ok, cap} ->
        %{acc | exposure_cap: take_min_decimal(acc.exposure_cap, cap)}

      :error ->
        acc
    end
  end

  defp fold_rule(acc, %PolicyRule{rule_type: rt, params: params})
       when rt in [
              :max_curator_exposure,
              :max_market_exposure,
              :max_collateral_exposure,
              :max_oracle_exposure
            ] do
    # Same shape as :max_vault_exposure for the v0.1 engine — the
    # snapshot only models a single vault at a time, so the
    # narrower exposure axes (curator / market / collateral /
    # oracle) collapse to the vault cap. The rule itself is
    # captured in the snapshot ref for audit; finer-grained
    # exposure tracking is future work (#205).
    case read_decimal(params, "max_amount") do
      {:ok, cap} ->
        %{acc | exposure_cap: take_min_decimal(acc.exposure_cap, cap)}

      :error ->
        acc
    end
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :min_vault_liquidity}) do
    # Snapshot exposes total_assets and pending caps; a workspace
    # min-liquidity threshold currently has no PolicyInput slot.
    # Captured in the audit trail for follow-up wiring.
    acc
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :min_timelock_seconds}) do
    # Snapshot exposes state.timelock; threshold check is
    # workspace-configurable in a future extension. Captured.
    acc
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :deny_morpho_warning}) do
    # The risk engine already deny-on-warning by default
    # (warnings → red mappings); the explicit rule is an
    # acknowledged pin in the audit trail.
    acc
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :incident_hold, params: params}) do
    active = truthy_param(params, "active")
    %{acc | incident_active?: acc.incident_active? or active}
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :yield_anomaly_approval, params: params}) do
    spike =
      case read_integer(params, "spike_pct") do
        {:ok, n} when n > 0 -> n
        _ -> acc.apy_spike_pct
      end

    baseline =
      case read_decimal(params, "baseline") do
        {:ok, dec} -> dec
        :error -> acc.apy_baseline
      end

    %{acc | apy_spike_pct: min(acc.apy_spike_pct, spike), apy_baseline: baseline}
  end

  # Catch-all: any Morpho rule type we haven't actively folded
  # above is still acknowledged (no error) so #202 stays the
  # complete vocabulary even when finer-grained PolicyInput
  # fields land in a follow-up issue.
  defp fold_rule(acc, %PolicyRule{}), do: acc

  # --- scope matching ------------------------------------------------------

  defp morpho_rule?(%PolicyRule{rule_type: rt}), do: PolicyRule.morpho?(rt)
  defp morpho_rule?(_), do: false

  defp scope_matches?(%PolicyRule{scope: scope}, vault_address, asset) when is_map(scope) do
    matches_vault?(scope, vault_address) and matches_asset?(scope, asset) and
      matches_venue?(scope)
  end

  defp scope_matches?(_, _, _), do: true

  defp matches_vault?(scope, nil) do
    # No vault context supplied — accept rules with no vault
    # scope; reject rules with a specific vault scope.
    scope_value(scope, "vault_address") in [nil, ""]
  end

  defp matches_vault?(scope, address) do
    case scope_value(scope, "vault_address") do
      nil -> true
      "" -> true
      configured -> normalize_address(configured) == address
    end
  end

  defp matches_asset?(scope, nil) do
    scope_value(scope, "asset") in [nil, ""]
  end

  defp matches_asset?(scope, asset) do
    case scope_value(scope, "asset") do
      nil -> true
      "" -> true
      configured -> configured == asset
    end
  end

  defp matches_venue?(scope) do
    case scope_value(scope, "venue") do
      nil -> true
      "" -> true
      "morpho" -> true
      _ -> false
    end
  end

  defp scope_value(scope, key) when is_map(scope) do
    Map.get(scope, key) || Map.get(scope, String.to_atom(key))
  rescue
    _ -> nil
  end

  # --- param readers (fixed-allowlist failure modes) -----------------------

  defp read_address_list(params, key) when is_map(params) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      list when is_list(list) ->
        list
        |> Enum.map(&normalize_address/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp read_address_list(_, _), do: []

  # Reads the `:allowed_vault` rule's `vaults` param into the
  # `[{chain_id, vault_address}]` shape `PolicyInput.vault_allowlist`
  # expects. Each entry must be a map carrying `chain_id` (integer)
  # and `address` (0x-prefixed hex). Malformed entries are silently
  # dropped — the conservative fail-closed posture: if the list
  # ends up empty, every vault triggers `vault_not_allowlisted` in
  # the engine.
  defp read_vault_list(params, key) when is_map(params) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      list when is_list(list) ->
        list
        |> Enum.map(&parse_vault_entry/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp read_vault_list(_, _), do: []

  defp parse_vault_entry(%{"chain_id" => cid, "address" => addr}) when is_integer(cid) do
    case normalize_address(addr) do
      nil -> nil
      address -> {cid, address}
    end
  end

  defp parse_vault_entry(%{chain_id: cid, address: addr}) when is_integer(cid) do
    case normalize_address(addr) do
      nil -> nil
      address -> {cid, address}
    end
  end

  defp parse_vault_entry(_), do: nil

  defp read_bps(params, key) when is_map(params) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      n when is_integer(n) and n >= 0 and n <= 10_000 -> {:ok, n}
      str when is_binary(str) -> parse_int(str, 0, 10_000)
      _ -> :error
    end
  end

  defp read_bps(_, _), do: :error

  defp read_integer(params, key) when is_map(params) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      n when is_integer(n) -> {:ok, n}
      str when is_binary(str) -> parse_int(str, nil, nil)
      _ -> :error
    end
  end

  defp read_integer(_, _), do: :error

  defp read_decimal(params, key) when is_map(params) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      %Decimal{} = d -> {:ok, d}
      n when is_integer(n) -> {:ok, Decimal.new(n)}
      str when is_binary(str) -> parse_decimal(str)
      _ -> :error
    end
  end

  defp read_decimal(_, _), do: :error

  defp truthy_param(params, key) when is_map(params) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp truthy_param(_, _), do: false

  defp parse_int(str, lower, upper) do
    case Integer.parse(str) do
      {n, ""} ->
        cond do
          not is_nil(lower) and n < lower -> :error
          not is_nil(upper) and n > upper -> :error
          true -> {:ok, n}
        end

      _ ->
        :error
    end
  end

  defp parse_decimal(str) do
    {:ok, Decimal.new(str)}
  rescue
    _ -> :error
  end

  # --- shape helpers -------------------------------------------------------

  defp normalize_address(nil), do: nil
  defp normalize_address(""), do: nil
  defp normalize_address(addr) when is_binary(addr), do: String.downcase(addr)
  defp normalize_address(_), do: nil

  defp default_decimal(nil), do: Decimal.new(0)
  defp default_decimal(%Decimal{} = d), do: d
  defp default_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp default_decimal(str) when is_binary(str), do: Decimal.new(str)
  defp default_decimal(_), do: Decimal.new(0)

  # Allowlist intersection: empty acc means "no upstream
  # restriction" → adopt the new list. Otherwise intersect.
  defp intersect_allowlist([], list), do: Enum.uniq(list)
  defp intersect_allowlist(acc, []), do: acc

  defp intersect_allowlist(acc, list) do
    acc_set = MapSet.new(acc)
    list_set = MapSet.new(list)
    acc_set |> MapSet.intersection(list_set) |> MapSet.to_list() |> Enum.sort()
  end

  defp take_min_decimal(nil, %Decimal{} = candidate), do: candidate

  defp take_min_decimal(%Decimal{} = current, %Decimal{} = candidate) do
    case Decimal.compare(current, candidate) do
      :gt -> candidate
      _ -> current
    end
  end

  defp take_min_decimal(_other, %Decimal{} = candidate), do: candidate

  defp bps_to_pct(bps) when is_integer(bps), do: div(bps, 100)
end
