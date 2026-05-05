defmodule Bank.DefiVenues.Morpho.PolicyInput do
  @moduledoc """
  Plain-data inputs the Morpho risk explanation engine consumes
  alongside a `Bank.DefiVenues.Morpho.PersistedVaultSnapshot` (#199).

  This struct is intentionally a passive value — callers
  (decision pipeline #203, audit/replay #208) populate it from
  workspace policy + an exposure read at decision time. The
  risk-explanation engine is a pure function on
  `(snapshot, policy_input, now)`; it never mutates state.

  ## Fields

  Internal allowlists and thresholds. Defaults are conservative:

    * `:vault_allowlist`        — list of `{chain_id, vault_address}`
      tuples the workspace has approved. Empty list ≡
      "no internal allowlist" → every vault triggers a
      `vault_not_allowlisted` block reason. The engine
      lower-cases the address before comparing.
    * `:oracle_allowlist`       — list of approved oracle addresses
      (lower-cased). Empty list ≡ "no allowlist" → every
      allocation oracle triggers an `unknown_oracle`
      approval reason.
    * `:collateral_allowlist`   — list of approved collateral
      asset addresses (lower-cased). Empty list ≡ same
      semantics as oracle.
    * `:expected_loan_asset`    — symbol the agent intent claims
      the deposit is in (e.g. `"USDC"`). The engine compares
      this against the snapshot's `deposit_asset.symbol`. A
      mismatch is a hard `asset_mismatch` block.

  Exposure inputs (per-vault per-workspace caps):

    * `:current_exposure`       — `Decimal` representing the
      workspace's current confirmed exposure to this vault.
      Default `Decimal.new("0")`.
    * `:proposed_amount`        — `Decimal` the agent wants to
      deposit. Default `Decimal.new("0")`.
    * `:exposure_cap`           — `Decimal` of the configured
      per-vault per-workspace cap. `nil` ≡ "no cap" → the
      exposure check produces a single `exposure_cap_missing`
      *hold* reason because we cannot judge.

  LLTV thresholds (basis points; `0..1` decimals stored as
  raw integers — Morpho expresses LLTV as a 1e18-scaled
  integer; the engine compares against this):

    * `:approval_market_lltv_pct`  — default `80` (i.e. 80%).
      Allocations with LLTV ≥ this percentage produce an
      `high_lltv` approval reason. Combined with
      `unknown_oracle` they upgrade to a hard block.
    * `:block_market_lltv_pct`     — default `90`. Allocations
      with LLTV ≥ this produce a `max_lltv_exceeded` block.

  Cap-utilisation thresholds (percentages):

    * `:warning_exposure_pct`      — default `50`
    * `:approval_exposure_pct`     — default `80`
    * `:block_exposure_pct`        — default `100`

  APY anomaly:

    * `:apy_baseline`              — `Decimal`, optional.
      When `nil` the APY check is skipped.
    * `:apy_spike_pct`             — default `50` (a net APY
      ≥ baseline * (1 + 50/100) triggers `apy_spike`).

  Incident gate:

    * `:incident_active?`          — boolean. `true` produces
      a `hold` reason that the decision pipeline can pin to
      a workspace-level incident.

  ## Defaults

  `default/0` returns a struct with conservative defaults:
  empty allowlists (the engine flags everything), no
  exposure cap (forces a hold), no APY baseline (skips the
  APY check). Tests override only the fields they need.
  """

  @type t :: %__MODULE__{
          vault_allowlist: [{integer(), String.t()}],
          oracle_allowlist: [String.t()],
          collateral_allowlist: [String.t()],
          expected_loan_asset: String.t() | nil,
          current_exposure: Decimal.t(),
          proposed_amount: Decimal.t(),
          exposure_cap: Decimal.t() | nil,
          approval_market_lltv_pct: integer(),
          block_market_lltv_pct: integer(),
          warning_exposure_pct: integer(),
          approval_exposure_pct: integer(),
          block_exposure_pct: integer(),
          apy_baseline: Decimal.t() | nil,
          apy_spike_pct: integer(),
          incident_active?: boolean()
        }

  defstruct vault_allowlist: [],
            oracle_allowlist: [],
            collateral_allowlist: [],
            expected_loan_asset: nil,
            current_exposure: nil,
            proposed_amount: nil,
            exposure_cap: nil,
            approval_market_lltv_pct: 80,
            block_market_lltv_pct: 90,
            warning_exposure_pct: 50,
            approval_exposure_pct: 80,
            block_exposure_pct: 100,
            apy_baseline: nil,
            apy_spike_pct: 50,
            incident_active?: false

  @doc """
  Returns a default `%PolicyInput{}` with safe zero-amounts.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      current_exposure: Decimal.new(0),
      proposed_amount: Decimal.new(0)
    }
  end
end
