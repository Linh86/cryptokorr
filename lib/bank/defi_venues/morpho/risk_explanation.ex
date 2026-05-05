defmodule Bank.DefiVenues.Morpho.RiskExplanation do
  @moduledoc """
  CryptoBank-owned risk explanation for a proposed Morpho vault
  action (#201).

  Pure deterministic function on
  `(snapshot, policy_input, now) :: explanation_map`. The
  engine emits the structured shape from
  `docs/morpho-risk-explanation.md`:

      %{
        "kind" => "morpho_vault_risk",
        "venue" => "morpho",
        "chain_id" => integer,
        "vault_address" => string,
        "vault_name" => string | nil,
        "loan_asset" => string | nil,
        "risk_tier" => "low" | "moderate" | "elevated" | "severe",
        "decision" => "auto_exec" | "approval_required" | "hold" | "block",
        "summary" => string,
        "primary_reasons" => [reason_map],
        "checks" => [check_map],
        "market_allocations" => [allocation_map],
        "source_refs" => [source_ref_map]
      }

  ## Side-effect contract

    * No DB writes.
    * No HTTP calls.
    * No log output.
    * No raw-response leakage — every string in the output is
      composed from controlled vocabulary (Morpho enum values,
      thresholds, decimal arithmetic results) or from the
      already-redacted `source.source_warnings` list (#198).

  ## Aggregation

  Per the design doc:

    * any reason of severity `block` ⇒ decision `block`
    * any reason of severity `hold`  ⇒ decision `hold`
      (overrides anything below)
    * any reason of severity `approval` ⇒ decision
      `approval_required`
    * MVP Morpho deposits are at least `approval_required` —
      never `auto_exec` even when no other reason fires.

  Risk-tier mapping mirrors the doc:

    * any block reason             → `severe`
    * any hold reason              → `elevated`
    * any approval reason          → at least `moderate`
    * any warn reason              → at least `moderate`
    * else                         → `low`

  Reason ordering inside the output is deterministic: dimensions
  are evaluated in fixed order and concat into the lists in that
  order. `:erlang.unique_integer/1` is never used.
  """

  alias Bank.DefiVenues.Morpho.PersistedVaultSnapshot
  alias Bank.DefiVenues.Morpho.PolicyInput
  alias Bank.DefiVenues.Morpho.Snapshots
  alias Bank.DefiVenues.Morpho.VaultSnapshot

  @kind "morpho_vault_risk"
  @venue "morpho"

  @typedoc "Severity vocabulary used in `primary_reasons`."
  @type severity :: :info | :warn | :approval | :hold | :block

  @typedoc "Status vocabulary used in `checks`."
  @type check_status :: :pass | :warn | :fail | :missing

  @typedoc "Engine input: a persisted snapshot OR an in-memory struct."
  @type snapshot_input ::
          PersistedVaultSnapshot.t()
          | VaultSnapshot.t()
          | nil

  @doc """
  Build the risk explanation. Always returns a map; never
  raises. A `nil` snapshot still produces a structured `hold`
  with a `snapshot_missing` reason — the issue's "missing
  critical data produces hold" acceptance bullet.
  """
  @spec explain(snapshot_input(), PolicyInput.t(), DateTime.t()) :: map()
  def explain(snapshot, %PolicyInput{} = policy, %DateTime{} = now) do
    case snapshot do
      nil ->
        no_snapshot_explanation(policy)

      _ ->
        do_explain(snapshot, policy, now)
    end
  end

  # --- Internal --------------------------------------------------------

  defp no_snapshot_explanation(_policy) do
    base()
    |> Map.merge(%{
      "chain_id" => nil,
      "vault_address" => nil,
      "vault_name" => nil,
      "loan_asset" => nil,
      "risk_tier" => "elevated",
      "decision" => "hold",
      "summary" =>
        "No vault snapshot available — holding the action until a fresh snapshot lands.",
      "primary_reasons" => [
        reason_to_map(
          reason("snapshot_missing", :hold, "No persisted Morpho vault snapshot available.")
        )
      ],
      "checks" => [],
      "market_allocations" => [],
      "source_refs" => []
    })
  end

  defp do_explain(snapshot, %PolicyInput{} = policy, now) do
    chain_id = snap_field(snapshot, :chain_id)
    vault_address = lower(snap_field(snapshot, :vault_address))
    vault_name = snap_field(snapshot, :name)
    loan_asset = snap_field(snapshot, :deposit_asset) |> deposit_field("symbol")

    freshness = snapshot_freshness(snapshot, now)
    allocations = ensure_list(snap_field(snapshot, :allocations))
    warnings = ensure_list(snap_field(snapshot, :warnings))
    pending_caps = ensure_list(snap_field(snapshot, :pending_caps))
    state = snap_field(snapshot, :state) || %{}
    listed = snap_field(snapshot, :listed)

    # Each `run_*` returns `{checks, reasons}` — a list of
    # check entries (always added to the output) and a list of
    # severity-bearing reasons (drive the aggregate decision).
    {checks, reasons} =
      []
      |> run(:protocol, fn -> protocol_check() end)
      |> run(:vault_listed, fn -> vault_listed_check(listed) end)
      |> run(:vault_allowlist, fn ->
        vault_allowlist_check(chain_id, vault_address, policy)
      end)
      |> run(:asset_match, fn -> asset_match_check(loan_asset, policy) end)
      |> run(:warnings, fn -> warnings_check(warnings) end)
      |> run(:freshness, fn -> freshness_check(freshness) end)
      |> run(:lltv, fn -> lltv_check(allocations, policy) end)
      |> run(:oracle, fn -> oracle_check(allocations, policy) end)
      |> run(:collateral, fn -> collateral_check(allocations, policy) end)
      |> run(:pending_caps, fn -> pending_caps_check(pending_caps) end)
      |> run(:exposure, fn -> exposure_check(policy) end)
      |> run(:apy, fn -> apy_check(state, policy) end)
      |> run(:incident, fn -> incident_check(policy) end)
      |> finalize()

    decision = aggregate_decision(reasons)
    risk_tier = aggregate_risk_tier(reasons)
    summary = build_summary(decision, risk_tier, reasons)

    base()
    |> Map.merge(%{
      "chain_id" => chain_id,
      "vault_address" => vault_address,
      "vault_name" => vault_name,
      "loan_asset" => loan_asset,
      "risk_tier" => to_string(risk_tier),
      "decision" => to_string(decision),
      "summary" => summary,
      "primary_reasons" => Enum.map(reasons, &reason_to_map/1),
      "checks" => checks |> Enum.reverse() |> Enum.map(&check_to_map/1),
      "market_allocations" => Enum.map(allocations, &allocation_view/1),
      "source_refs" => source_refs(snapshot, freshness)
    })
  end

  defp base do
    %{"kind" => @kind, "venue" => @venue}
  end

  # --- Dimensions ------------------------------------------------------

  # 1. Protocol risk. Morpho is a known protocol; MVP integration
  # path is always at least approval. Emits a `pass` check and an
  # `:approval` reason that the aggregator picks up (so a
  # never-fired-anything-else snapshot still ends in
  # `approval_required` per the MVP rule).
  defp protocol_check do
    {[
       check("protocol_known", :pass, "Morpho is a recognised DeFi protocol", "internal")
     ],
     [
       reason(
         "mvp_morpho_deposit",
         :approval,
         "First-version Morpho deposit always requires operator approval."
       )
     ]}
  end

  defp vault_listed_check(true),
    do: {[check("vault_listed", :pass, "Vault is listed by Morpho API", "morpho_api")], []}

  defp vault_listed_check(false),
    do:
      {[check("vault_listed", :fail, "Vault is NOT listed by Morpho API", "morpho_api")],
       [reason("vault_not_listed", :block, "Vault is not listed by the Morpho API.")]}

  defp vault_listed_check(_),
    do:
      {[check("vault_listed", :missing, "Vault `listed` flag is missing", "morpho_api")],
       [reason("vault_listed_missing", :hold, "Vault `listed` flag is missing — cannot judge.")]}

  defp vault_allowlist_check(_chain, _addr, %PolicyInput{vault_allowlist: []}) do
    {[
       check(
         "vault_allowlist",
         :fail,
         "No internal vault allowlist configured",
         "internal"
       )
     ],
     [
       reason(
         "vault_not_allowlisted",
         :block,
         "Internal vault allowlist is empty; no Morpho vault is approved."
       )
     ]}
  end

  defp vault_allowlist_check(chain_id, vault_address, %PolicyInput{vault_allowlist: list}) do
    needle = {chain_id, lower(vault_address)}
    normalized = Enum.map(list, fn {c, a} -> {c, lower(a)} end)

    if needle in normalized do
      {[check("vault_allowlist", :pass, "Vault is internally allowlisted", "internal")], []}
    else
      {[check("vault_allowlist", :fail, "Vault is NOT internally allowlisted", "internal")],
       [
         reason(
           "vault_not_allowlisted",
           :block,
           "Vault address is not on the workspace's Morpho allowlist."
         )
       ]}
    end
  end

  defp asset_match_check(nil, %PolicyInput{expected_loan_asset: nil}),
    do: {[check("asset_match", :pass, "No expected asset to compare", "internal")], []}

  defp asset_match_check(actual, %PolicyInput{expected_loan_asset: nil}) do
    {[
       check(
         "asset_match",
         :pass,
         "No expected loan asset configured; vault deposit asset is #{actual}",
         "morpho_api"
       )
     ], []}
  end

  defp asset_match_check(nil, %PolicyInput{expected_loan_asset: expected}) do
    {[check("asset_match", :missing, "Vault deposit asset missing", "morpho_api")],
     [
       reason(
         "asset_mismatch",
         :block,
         "Vault deposit asset is missing; expected #{expected}."
       )
     ]}
  end

  defp asset_match_check(actual, %PolicyInput{expected_loan_asset: expected}) do
    if String.upcase(actual) == String.upcase(expected) do
      {[check("asset_match", :pass, "Vault accepts #{actual}", "morpho_api")], []}
    else
      {[
         check(
           "asset_match",
           :fail,
           "Vault accepts #{actual}; intent claims #{expected}",
           "morpho_api"
         )
       ],
       [
         reason(
           "asset_mismatch",
           :block,
           "Vault deposit asset (#{actual}) does not match expected loan asset (#{expected})."
         )
       ]}
    end
  end

  defp warnings_check([]),
    do: {[check("morpho_warnings", :pass, "No vault warnings", "morpho_api")], []}

  defp warnings_check(warnings) do
    {checks, reasons} =
      Enum.reduce(warnings, {[], []}, fn w, {cs, rs} ->
        type = read_warning_field(w, "raw_type") || read_warning_field(w, "type") || "unknown"
        level = read_warning_field(w, "raw_level") || read_warning_field(w, "level")

        {check, reason} = classify_warning(type, level)
        {[check | cs], if(reason, do: [reason | rs], else: rs)}
      end)

    {Enum.reverse(checks), Enum.reverse(reasons)}
  end

  defp classify_warning(type, level) do
    severity =
      case level && String.upcase(to_string(level)) do
        "RED" -> :block
        "ORANGE" -> :approval
        "YELLOW" -> :approval
        "GREEN" -> :info
        _ -> :warn
      end

    label = "Morpho warning: #{type}#{level && " (#{level})"}"

    {check_status, reason_severity} =
      case severity do
        :block -> {:fail, :block}
        :approval -> {:warn, :approval}
        :info -> {:pass, nil}
        :warn -> {:warn, :warn}
      end

    check = check("morpho_warning_#{snake(type)}", check_status, label, "morpho_api")

    reason =
      if reason_severity do
        reason("morpho_warning_#{snake(type)}", reason_severity, label <> ".")
      end

    {check, reason}
  end

  # Freshness drives critical-data hold semantics: the
  # allocation and warnings slices are *operationally critical*
  # (they shape oracle / LLTV / cap math). Stale identity / APY
  # produce a `warn` check instead of a hold.
  defp freshness_check(freshness) do
    {checks, reasons} =
      Enum.reduce(
        [
          {:identity, "freshness_identity", false},
          {:allocation, "freshness_allocation", true},
          {:warnings, "freshness_warnings", true},
          {:apy, "freshness_apy", false}
        ],
        {[], []},
        fn {field, code, critical?}, {cs, rs} ->
          {check, reason} = freshness_one(field, code, critical?, freshness[field])
          {[check | cs], if(reason, do: [reason | rs], else: rs)}
        end
      )

    {Enum.reverse(checks), Enum.reverse(reasons)}
  end

  defp freshness_one(_field, code, _critical?, :fresh) do
    {check(code, :pass, "Snapshot field is fresh", "morpho_api"), nil}
  end

  defp freshness_one(_field, code, false, :stale) do
    {check(code, :warn, "Snapshot field is stale (still usable)", "morpho_api"), nil}
  end

  defp freshness_one(_field, code, true, :stale) do
    {check(code, :warn, "Snapshot field is stale (still usable)", "morpho_api"),
     reason(code, :warn, "Snapshot freshness window exceeded; re-fetch recommended.")}
  end

  defp freshness_one(_field, code, false, :expired) do
    {check(code, :warn, "Snapshot field is expired", "morpho_api"), nil}
  end

  defp freshness_one(_field, code, true, :expired) do
    {check(code, :fail, "Snapshot field is expired", "morpho_api"),
     reason(
       code,
       :hold,
       "Snapshot critical-data field is expired; refusing decision until refreshed."
     )}
  end

  defp freshness_one(_field, code, _critical?, _other) do
    {check(code, :missing, "Snapshot freshness unknown", "morpho_api"), nil}
  end

  defp lltv_check([], _policy),
    do: {[check("max_market_lltv", :pass, "No allocations to evaluate", "morpho_api")], []}

  defp lltv_check(allocations, %PolicyInput{} = policy) do
    max_lltv =
      allocations
      |> Enum.map(&allocation_lltv/1)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        list -> Enum.max(list)
      end

    case max_lltv do
      nil ->
        {[check("max_market_lltv", :missing, "No allocation has an LLTV", "morpho_api")], []}

      lltv_pct ->
        cond do
          lltv_pct >= policy.block_market_lltv_pct ->
            {[
               check(
                 "max_market_lltv",
                 :fail,
                 "Highest underlying LLTV is #{lltv_pct}%",
                 "morpho_api"
               )
             ],
             [
               reason(
                 "max_lltv_exceeded",
                 :block,
                 "Highest underlying LLTV (#{lltv_pct}%) is at or above the block threshold (#{policy.block_market_lltv_pct}%)."
               )
             ]}

          lltv_pct >= policy.approval_market_lltv_pct ->
            {[
               check(
                 "max_market_lltv",
                 :warn,
                 "Highest underlying LLTV is #{lltv_pct}%",
                 "morpho_api"
               )
             ],
             [
               reason(
                 "high_lltv",
                 :approval,
                 "Highest underlying LLTV (#{lltv_pct}%) is at or above the approval threshold (#{policy.approval_market_lltv_pct}%)."
               )
             ]}

          true ->
            {[
               check(
                 "max_market_lltv",
                 :pass,
                 "Highest underlying LLTV is #{lltv_pct}%",
                 "morpho_api"
               )
             ], []}
        end
    end
  end

  defp oracle_check([], _policy),
    do: {[check("oracle_allowlist", :pass, "No allocations to evaluate", "morpho_api")], []}

  defp oracle_check(_allocations, %PolicyInput{oracle_allowlist: []}) do
    {[check("oracle_allowlist", :fail, "No internal oracle allowlist configured", "internal")],
     [
       reason(
         "unknown_oracle",
         :approval,
         "Internal oracle allowlist is empty; treating every allocation oracle as unknown."
       )
     ]}
  end

  defp oracle_check(allocations, %PolicyInput{} = policy) do
    allowlist = Enum.map(policy.oracle_allowlist, &lower/1)

    unknowns =
      allocations
      |> Enum.map(&read_allocation_field(&1, "oracle"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(fn addr -> lower(addr) in allowlist end)

    high_lltv? =
      allocations
      |> Enum.any?(fn a ->
        lltv = allocation_lltv(a)
        lltv != nil and lltv >= policy.approval_market_lltv_pct
      end)

    cond do
      unknowns == [] ->
        {[check("oracle_allowlist", :pass, "All oracle addresses are allowlisted", "internal")],
         []}

      high_lltv? ->
        {[
           check(
             "oracle_allowlist",
             :fail,
             "Unknown oracle(s) on a high-LLTV allocation",
             "internal"
           )
         ],
         [
           reason(
             "unknown_oracle_high_lltv",
             :block,
             "Unknown oracle on an allocation with LLTV ≥ approval threshold."
           )
         ]}

      true ->
        {[check("oracle_allowlist", :warn, "Unknown oracle(s) on allocations", "internal")],
         [
           reason(
             "unknown_oracle",
             :approval,
             "One or more allocation oracles are not allowlisted."
           )
         ]}
    end
  end

  defp collateral_check([], _policy), do: {[], []}

  defp collateral_check(_allocations, %PolicyInput{collateral_allowlist: []}) do
    {[check("collateral_allowlist", :warn, "No internal collateral allowlist", "internal")],
     [reason("unknown_collateral", :approval, "Internal collateral allowlist is empty.")]}
  end

  defp collateral_check(allocations, %PolicyInput{} = policy) do
    allowlist = Enum.map(policy.collateral_allowlist, &lower/1)

    unknowns =
      allocations
      |> Enum.map(&read_allocation_field(&1, "collateral_asset"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(fn addr -> lower(addr) in allowlist end)

    if unknowns == [] do
      {[
         check("collateral_allowlist", :pass, "All collateral assets are allowlisted", "internal")
       ], []}
    else
      {[check("collateral_allowlist", :warn, "Unknown collateral asset(s)", "internal")],
       [
         reason(
           "unknown_collateral",
           :approval,
           "One or more allocation collateral assets are not allowlisted."
         )
       ]}
    end
  end

  defp pending_caps_check([]),
    do: {[check("pending_caps", :pass, "No pending cap changes", "morpho_api")], []}

  defp pending_caps_check(_pending) do
    {[check("pending_caps", :warn, "Pending cap changes present", "morpho_api")],
     [
       reason(
         "pending_cap_increase",
         :approval,
         "Vault has pending allocation-cap changes; verify before depositing."
       )
     ]}
  end

  defp exposure_check(%PolicyInput{exposure_cap: nil}) do
    {[check("exposure_cap", :missing, "No exposure cap configured", "internal")],
     [
       reason(
         "exposure_cap_missing",
         :hold,
         "No internal exposure cap configured for this vault."
       )
     ]}
  end

  defp exposure_check(%PolicyInput{} = policy) do
    proposed = policy.proposed_amount || Decimal.new(0)
    current = policy.current_exposure || Decimal.new(0)
    cap = policy.exposure_cap

    after_deposit = Decimal.add(current, proposed)

    if Decimal.compare(cap, Decimal.new(0)) == :gt do
      pct =
        Decimal.div(after_deposit, cap)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.round(2)

      pct_int = Decimal.to_float(pct) |> trunc()

      cond do
        pct_int >= policy.block_exposure_pct ->
          {[
             check(
               "exposure_cap",
               :fail,
               "Post-deposit exposure is #{pct_int}% of cap",
               "internal"
             )
           ],
           [
             reason(
               "cap_breach",
               :block,
               "Post-deposit exposure (#{pct_int}%) at or above block threshold (#{policy.block_exposure_pct}%)."
             )
           ]}

        pct_int >= policy.approval_exposure_pct ->
          {[
             check(
               "exposure_cap",
               :warn,
               "Post-deposit exposure is #{pct_int}% of cap",
               "internal"
             )
           ],
           [
             reason(
               "exposure_near_cap",
               :approval,
               "Post-deposit exposure (#{pct_int}%) at or above approval threshold (#{policy.approval_exposure_pct}%)."
             )
           ]}

        pct_int >= policy.warning_exposure_pct ->
          {[
             check(
               "exposure_cap",
               :warn,
               "Post-deposit exposure is #{pct_int}% of cap",
               "internal"
             )
           ],
           [
             reason(
               "exposure_elevated",
               :warn,
               "Post-deposit exposure (#{pct_int}%) at or above warning threshold (#{policy.warning_exposure_pct}%)."
             )
           ]}

        true ->
          {[
             check(
               "exposure_cap",
               :pass,
               "Post-deposit exposure is #{pct_int}% of cap",
               "internal"
             )
           ], []}
      end
    else
      {[check("exposure_cap", :missing, "Configured cap is zero or negative", "internal")],
       [
         reason(
           "exposure_cap_missing",
           :hold,
           "Configured cap is zero or negative — cannot evaluate."
         )
       ]}
    end
  end

  defp apy_check(_state, %PolicyInput{apy_baseline: nil}), do: {[], []}

  defp apy_check(state, %PolicyInput{apy_baseline: baseline} = policy) do
    case state |> Map.get("net_apy") || Map.get(state, :net_apy) do
      nil ->
        {[check("apy_anomaly", :missing, "Vault net APY is not reported", "morpho_api")], []}

      apy_value ->
        case Decimal.cast(apy_value) do
          {:ok, apy} ->
            ratio =
              if Decimal.compare(baseline, Decimal.new(0)) == :gt,
                do: Decimal.div(apy, baseline),
                else: nil

            if ratio do
              spike_threshold =
                Decimal.add(
                  Decimal.new(1),
                  Decimal.div(Decimal.new(policy.apy_spike_pct), Decimal.new(100))
                )

              if Decimal.compare(ratio, spike_threshold) != :lt do
                {[
                   check(
                     "apy_anomaly",
                     :warn,
                     "Net APY (#{apy}) above baseline spike threshold",
                     "morpho_api"
                   )
                 ],
                 [
                   reason(
                     "apy_spike",
                     :approval,
                     "Net APY exceeds baseline by ≥ #{policy.apy_spike_pct}%; APY anomalies never reduce risk."
                   )
                 ]}
              else
                {[
                   check(
                     "apy_anomaly",
                     :pass,
                     "Net APY (#{apy}) within baseline range",
                     "morpho_api"
                   )
                 ], []}
              end
            else
              {[], []}
            end

          :error ->
            {[check("apy_anomaly", :missing, "Vault net APY is not parseable", "morpho_api")], []}
        end
    end
  end

  defp incident_check(%PolicyInput{incident_active?: false}),
    do: {[check("incident", :pass, "No active incident", "internal")], []}

  defp incident_check(%PolicyInput{incident_active?: true}) do
    {[check("incident", :fail, "Active incident — refusing", "internal")],
     [reason("incident_active", :hold, "Workspace has an active incident; holding the action.")]}
  end

  # --- Aggregation -----------------------------------------------------

  @severity_rank %{
    info: 0,
    warn: 1,
    approval: 2,
    hold: 3,
    block: 4
  }

  defp aggregate_decision(reasons) do
    severities = Enum.map(reasons, & &1.severity)

    cond do
      :block in severities -> :block
      :hold in severities -> :hold
      :approval in severities -> :approval_required
      true -> :approval_required
    end
  end

  defp aggregate_risk_tier(reasons) do
    rank =
      reasons
      |> Enum.map(&Map.get(@severity_rank, &1.severity, 0))
      |> Enum.max(fn -> 0 end)

    cond do
      rank >= @severity_rank[:block] -> :severe
      rank >= @severity_rank[:hold] -> :elevated
      rank >= @severity_rank[:approval] -> :moderate
      rank >= @severity_rank[:warn] -> :moderate
      true -> :low
    end
  end

  defp build_summary(:block, _tier, _reasons),
    do: "Action blocked by Morpho risk policy."

  defp build_summary(:hold, _tier, _reasons),
    do: "Action held — critical Morpho data missing or stale."

  defp build_summary(:approval_required, tier, _reasons) do
    "Action requires operator approval (Morpho risk tier: #{tier})."
  end

  defp build_summary(_, _tier, _reasons),
    do: "Action evaluated against Morpho risk policy."

  # --- Helpers ---------------------------------------------------------

  defp run({checks_acc, reasons_acc}, _name, fun) do
    {new_checks, new_reasons} = fun.()
    {new_checks ++ checks_acc, reasons_acc ++ new_reasons}
  end

  defp run([], _name, fun) do
    {new_checks, new_reasons} = fun.()
    {new_checks, new_reasons}
  end

  defp finalize({checks, reasons}), do: {checks, reasons}

  defp check(code, status, label, source) do
    %{code: code, status: status, label: label, source: source}
  end

  defp check_to_map(%{} = c) do
    %{
      "code" => c.code,
      "status" => Atom.to_string(c.status),
      "label" => c.label,
      "source" => c.source
    }
  end

  defp reason(code, severity, message) do
    %{code: code, severity: severity, message: message}
  end

  defp reason_to_map(%{} = r) do
    %{
      "code" => r.code,
      "severity" => Atom.to_string(r.severity),
      "message" => r.message
    }
  end

  defp snap_field(%PersistedVaultSnapshot{} = s, field), do: Map.get(s, field)
  defp snap_field(%VaultSnapshot{} = s, field), do: Map.get(s, field)
  defp snap_field(_, _), do: nil

  defp snapshot_freshness(%PersistedVaultSnapshot{} = s, now),
    do: Snapshots.freshness_summary(s, now)

  defp snapshot_freshness(%VaultSnapshot{source: %{fetched_at: %DateTime{} = at}}, now) do
    # In-memory struct path: derive a coarse freshness summary
    # using the same default TTLs (24h / 5m / 5m / 1h) that the
    # persisted row carries. Useful for tests that explain
    # without going through the DB.
    Snapshots.freshness_summary(
      %PersistedVaultSnapshot{
        fetched_at: DateTime.truncate(at, :microsecond),
        freshness_seconds_identity: 86_400,
        freshness_seconds_allocation: 300,
        freshness_seconds_warnings: 300,
        freshness_seconds_apy: 3600
      },
      now
    )
  end

  defp snapshot_freshness(_, _), do: %{}

  defp deposit_field(nil, _key), do: nil
  defp deposit_field(%{} = m, key), do: Map.get(m, key) || Map.get(m, String.to_atom(key))
  defp deposit_field(_, _), do: nil

  defp ensure_list(nil), do: []
  defp ensure_list(list) when is_list(list), do: list
  defp ensure_list(_), do: []

  defp lower(nil), do: nil
  defp lower(s) when is_binary(s), do: String.downcase(s)
  defp lower(_), do: nil

  defp snake(s) when is_binary(s) do
    s |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
  end

  defp snake(_), do: "unknown"

  # Allocation field accessors that tolerate both atom-keyed
  # in-memory maps (from the struct) and string-keyed maps
  # (from the DB read after `Repo.get`).
  defp read_allocation_field(%{} = a, key) when is_binary(key) do
    Map.get(a, key) || Map.get(a, String.to_atom(key))
  end

  defp read_allocation_field(_, _), do: nil

  defp read_warning_field(%{} = w, key) when is_binary(key) do
    Map.get(w, key) || Map.get(w, String.to_atom(key))
  end

  defp read_warning_field(_, _), do: nil

  # LLTV in Morpho's API is a 1e18-scaled integer. Convert to a
  # percentage integer for human-readable comparison.
  defp allocation_lltv(%{} = a) do
    case read_allocation_field(a, "lltv") do
      nil ->
        nil

      lltv when is_integer(lltv) ->
        # 1e18-scaled. Convert to percentage.
        div(lltv * 100, 1_000_000_000_000_000_000)

      lltv when is_binary(lltv) ->
        case Integer.parse(lltv) do
          {n, ""} -> div(n * 100, 1_000_000_000_000_000_000)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp allocation_lltv(_), do: nil

  defp allocation_view(%{} = a) do
    %{
      "market_id" => read_allocation_field(a, "market_unique_key"),
      "loan_asset" => read_allocation_field(a, "loan_asset"),
      "collateral_asset" => read_allocation_field(a, "collateral_asset"),
      "lltv_pct" => allocation_lltv(a),
      "oracle_address" => read_allocation_field(a, "oracle"),
      "irm_address" => read_allocation_field(a, "irm"),
      "supply_cap" => read_allocation_field(a, "supply_cap"),
      "supplied_assets" => read_allocation_field(a, "supplied_assets"),
      "supplied_assets_usd" => read_allocation_field(a, "supplied_assets_usd")
    }
  end

  defp source_refs(snapshot, freshness) do
    fetched_at = snap_fetched_at(snapshot)

    [
      %{
        "source" => "morpho_api",
        "fetched_at" => fetched_at && DateTime.to_iso8601(fetched_at),
        "freshness" => Map.new(freshness, fn {k, v} -> {Atom.to_string(k), Atom.to_string(v)} end)
      }
    ]
  end

  defp snap_fetched_at(%PersistedVaultSnapshot{fetched_at: %DateTime{} = at}), do: at
  defp snap_fetched_at(%VaultSnapshot{source: %{fetched_at: %DateTime{} = at}}), do: at
  defp snap_fetched_at(_), do: nil
end
