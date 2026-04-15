defmodule Bank.Quotes.Preview do
  @moduledoc """
  A structured quote + simulation preview produced by a provider.

  The preview is the value-typed intermediate used by the decision
  pipeline before it decides whether to materialise a
  `%Bank.Decisions.SimulationReport{}`. The two are deliberately
  distinct: the preview is cheap to produce and to discard (memory
  only); the simulation report is the persisted audit-quality copy.

  ## Fields

    * `balance_impact` — map keyed by asset with a signed decimal
      amount (outflow is negative).
    * `estimated_gas` — integer gas units (or `nil` if the chain
      doesn't use a gas abstraction).
    * `estimated_fee` — decimal fee amount in the fee asset (usually
      ETH on Base).
    * `fee_asset` — string asset label for `estimated_fee`.
    * `expected_output` — decimal (swap-only). `nil` for transfers.
    * `slippage_bps` — integer bps the quote is priced against
      (swap-only).
    * `route` — map describing the quoted route; shape is provider-
      defined but always JSON-serialisable.
    * `failure_conditions` — list of strings describing the conditions
      under which the preview would invalidate (e.g. `"balance drops
      below 10 USDC"`).
    * `provider` — short provider identifier (e.g. `"stub"`, `"tenderly"`).
    * `provider_trace_ref` — opaque provider-side trace id for debug.
    * `generated_at` — when the preview was produced.
    * `freshness_ttl_seconds` — seconds the preview can be trusted
      before it needs to be regenerated.
  """

  @type t :: %__MODULE__{
          balance_impact: %{String.t() => Decimal.t()},
          estimated_gas: non_neg_integer() | nil,
          estimated_fee: Decimal.t() | nil,
          fee_asset: String.t() | nil,
          expected_output: Decimal.t() | nil,
          slippage_bps: non_neg_integer() | nil,
          route: map() | nil,
          failure_conditions: [String.t()],
          provider: String.t(),
          provider_trace_ref: String.t() | nil,
          generated_at: DateTime.t(),
          freshness_ttl_seconds: pos_integer()
        }

  defstruct balance_impact: %{},
            estimated_gas: nil,
            estimated_fee: nil,
            fee_asset: nil,
            expected_output: nil,
            slippage_bps: nil,
            route: nil,
            failure_conditions: [],
            provider: "unknown",
            provider_trace_ref: nil,
            generated_at: nil,
            freshness_ttl_seconds: 30
end
