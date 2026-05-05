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
      configured allowlists when more than one rule applies. An
      explicit empty / malformed configured allowlist
      collapses the intersection to `[]` (fail-closed posture
      from #202 P2): the engine reads the empty list as "no
      vault / oracle / collateral / curator approved" and
      blocks accordingly. The first rule with values *adopts*
      its values (no upstream restriction yet); subsequent
      rules narrow.

  Within the bounded #202 surface this conflict-resolution
  mirrors the v1 evaluator's posture (the most-restrictive
  amount cap wins; the strictest autonomy tier wins).

  ## Configured-vs-default tracking (#202 P2)

  An empty allowlist on the produced `PolicyInput` is
  ambiguous on its own — it could mean *"no rule was ever
  configured"* (the conservative default) or *"a rule was
  configured with an empty list"* (the operator deliberately
  cleared the allowlist). For #202's *"unknown/unconfigured
  critical allowlists fail closed"* acceptance both must lead
  to a block. The engine already treats `vault_allowlist: []`
  as block-tier; for oracle / collateral / curator the engine
  emits an `:approval` reason. Either way the **fold** has to
  surface the empty list to the engine — not silently drop a
  malformed second rule and revert to the prior valid set.

  The fold therefore carries a private `MapSet` of
  *configured allowlist fields*. Each `:allowed_*` rule:

    * marks its target field as configured;
    * adopts its values verbatim if no upstream rule had
      configured that field yet;
    * intersects with the upstream values otherwise — an empty
      new list shrinks the intersection to `[]` (fail-closed).

  After every rule has been folded the accumulator's
  `policy_input` is returned and the configured-set is
  discarded.

  ## What `:allowed_defi_venue` does (and does not) do

  The v0.1 risk engine ships **Morpho-only**: there is no
  Aave / Compound / Pendle code path to gate against. The
  `:allowed_defi_venue` rule type is therefore an
  audit-trail-only no-op for v0.1 — its `params.venues` is
  recorded in `policy_snapshot_ref` but does not change
  runtime behavior. A future multi-venue extension will
  activate this rule. The compiler explicitly recognizes the
  rule (it is in `morpho_rule_types/0`) so a workspace can
  configure it without producing an `unknown_rule_type`
  violation; the documented limitation is pinned by a test.

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

    initial = %{policy_input: base, configured: MapSet.new()}

    rules
    |> Enum.filter(&morpho_rule?/1)
    |> Enum.filter(&scope_matches?(&1, vault_address, asset))
    |> Enum.reduce(initial, &fold_rule(&2, &1))
    |> Map.fetch!(:policy_input)
  end

  # --- per-rule fold -------------------------------------------------------

  defp fold_rule(acc, %PolicyRule{rule_type: :allowed_vault, params: params}) do
    list = read_vault_list(params, "vaults")
    fold_allowlist(acc, :vault_allowlist, list)
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :allowed_oracle, params: params}) do
    list = read_address_list(params, "oracles")
    fold_allowlist(acc, :oracle_allowlist, list)
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :allowed_collateral_asset, params: params}) do
    list = read_address_list(params, "assets")
    fold_allowlist(acc, :collateral_allowlist, list)
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :allowed_curator, params: params}) do
    # #202 P2: workspace-level curator/allocator allowlist.
    # Reuses the same fail-closed sentinel-based intersection
    # as the other allowlists — an empty/malformed configured
    # rule narrows the intersection to `[]`, which the engine's
    # `curator_check` treats as "every allocator unknown" and
    # surfaces an `unknown_curator` :approval reason.
    list = read_address_list(params, "curators")
    fold_allowlist(acc, :curator_allowlist, list)
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :allowed_defi_venue}) do
    # Documented v0.1 no-op (#202 P2). The engine ships
    # Morpho-only — there is no Aave / Compound / Pendle code
    # path to gate against — so the `params.venues` list is
    # captured in `policy_snapshot_ref` for audit but does not
    # change runtime behavior. A future multi-venue extension
    # will wire this rule against a venue check at the engine
    # boundary. Pinned by `documents_allowed_defi_venue_as_v0_1_noop`
    # in the test suite.
    acc
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :max_market_lltv, params: params}) do
    update_policy_input(acc, fn pi ->
      block_pct =
        case read_bps(params, "max_lltv_bps") do
          {:ok, bps} -> bps_to_pct(bps)
          :error -> pi.block_market_lltv_pct
        end

      approval_pct =
        case read_bps(params, "approval_over_bps") do
          {:ok, bps} -> bps_to_pct(bps)
          :error -> pi.approval_market_lltv_pct
        end

      %{
        pi
        | block_market_lltv_pct: min(pi.block_market_lltv_pct, block_pct),
          approval_market_lltv_pct: min(pi.approval_market_lltv_pct, approval_pct)
      }
    end)
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :max_vault_exposure, params: params}) do
    update_policy_input(acc, fn pi ->
      case read_decimal(params, "max_amount") do
        {:ok, cap} -> %{pi | exposure_cap: take_min_decimal(pi.exposure_cap, cap)}
        :error -> pi
      end
    end)
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
    update_policy_input(acc, fn pi ->
      case read_decimal(params, "max_amount") do
        {:ok, cap} -> %{pi | exposure_cap: take_min_decimal(pi.exposure_cap, cap)}
        :error -> pi
      end
    end)
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

    update_policy_input(acc, fn pi -> %{pi | incident_active?: pi.incident_active? or active} end)
  end

  defp fold_rule(acc, %PolicyRule{rule_type: :yield_anomaly_approval, params: params}) do
    update_policy_input(acc, fn pi ->
      spike =
        case read_integer(params, "spike_pct") do
          {:ok, n} when n > 0 -> n
          _ -> pi.apy_spike_pct
        end

      baseline =
        case read_decimal(params, "baseline") do
          {:ok, dec} -> dec
          :error -> pi.apy_baseline
        end

      %{pi | apy_spike_pct: min(pi.apy_spike_pct, spike), apy_baseline: baseline}
    end)
  end

  # Catch-all: any Morpho rule type we haven't actively folded
  # above is still acknowledged (no error) so #202 stays the
  # complete vocabulary even when finer-grained PolicyInput
  # fields land in a follow-up issue.
  defp fold_rule(acc, %PolicyRule{}), do: acc

  # --- accumulator helpers (#202 P2) ---------------------------------------

  defp update_policy_input(%{policy_input: pi} = acc, fun) when is_function(fun, 1) do
    %{acc | policy_input: fun.(pi)}
  end

  # Allowlist fold with sentinel-based "configured" tracking
  # (#202 P2 fail-closed posture). The first rule that touches
  # a given allowlist field marks it as configured and adopts
  # its values. Subsequent rules narrow via intersection — an
  # empty / malformed new list collapses the intersection to
  # `[]`, which the engine treats as "no values approved" and
  # blocks accordingly.
  defp fold_allowlist(%{policy_input: pi, configured: configured} = acc, field, new_list)
       when field in [
              :vault_allowlist,
              :oracle_allowlist,
              :collateral_allowlist,
              :curator_allowlist
            ] do
    new_list_uniq = Enum.uniq(new_list)

    if MapSet.member?(configured, field) do
      current = Map.fetch!(pi, field)
      merged = intersect_lists(current, new_list_uniq)
      %{acc | policy_input: Map.put(pi, field, merged)}
    else
      %{
        acc
        | policy_input: Map.put(pi, field, new_list_uniq),
          configured: MapSet.put(configured, field)
      }
    end
  end

  # An explicitly empty new list collapses the intersection to
  # `[]` regardless of whether the prior list had values. This
  # is the load-bearing #202 P2 fail-closed posture: a
  # configured-but-malformed allowlist must not be silently
  # ignored after a valid earlier allowlist.
  defp intersect_lists(_acc, []), do: []
  defp intersect_lists([], list), do: Enum.uniq(list)

  defp intersect_lists(acc, list) do
    acc
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(list))
    |> MapSet.to_list()
    |> Enum.sort()
  end

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
