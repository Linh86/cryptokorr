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
      below 10 USDC"`). Forward-looking — what *could* go wrong if
      the preview were re-evaluated later.
    * `failure_reason` — short structured string (or `nil`) tagging
      *why* the most recent provider call failed, when the provider
      surfaces a non-`:ok` outcome through the preview path. Distinct
      from the error tuples returned by `Bank.Quotes.preview/2`:
      `failure_reason` is the value the *next* downstream consumer
      (operator UI, decision report) sees attached to the preview row;
      the error tuple is the in-process control-flow shape the caller
      branches on. `nil` when the preview produced cleanly.
    * `risk_flags` — list of short fixed-allowlist strings the
      provider attaches when it noticed something the decision
      pipeline should weigh (e.g. `"wide_slippage_band"`,
      `"low_liquidity_pool"`, `"router_partial_fill"`). Always a list,
      possibly empty. Mirrors the
      `Bank.Stablecoins.RouteQuote.risk_flags` pattern (#173).
    * `source` — atom describing the *kind* of provider that produced
      this preview. `:stub` (deterministic in-process), `:live`
      (real provider via HTTP). Stable across releases — used by the
      decision pipeline when it needs to apply different
      autonomy/freshness rules per source kind without parsing the
      `provider` string. The `provider` field continues to carry the
      human-readable identifier (e.g. `"tenderly"`).
    * `provider` — short provider identifier (e.g. `"stub"`,
      `"tenderly"`).
    * `provider_trace_ref` — opaque provider-side trace id for
      debug. Never carries secret material — provider-side trace ids
      are non-sensitive by contract (#198).
    * `generated_at` — when the preview was produced.
    * `freshness_ttl_seconds` — seconds the preview can be trusted
      before it needs to be regenerated.

  ## What the preview never carries

  The preview struct is the *runtime intermediate*, not a wire format:

    * No raw provider URL, API key, or Authorization header — those
      stay inside the provider module's HTTP client.
    * No private-key or signing material — those never leave the
      adapter (`Bank.AdapterClient`).
    * No Ecto changeset, %Req.Response{}, or other inspect-heavy
      struct — `failure_reason` is a short tag, not a serialised
      stack trace.

  ## Source vs status

  `:source` lives on the runtime preview and answers "where did this
  preview come from?". The persisted
  `%Bank.Decisions.SimulationReport{status: :pending | :completed |
  :failed | :stale}` lives on the report row and answers "what
  happened to this simulation in the persistence layer?". Together
  they distinguish the four cases #173 calls out: `:stub`/`:live` from
  preview source, `:stale`/`:failed` from report status. The decision
  pipeline reads both when classifying a preview's trustworthiness.
  """

  @type source :: :stub | :live

  @type t :: %__MODULE__{
          balance_impact: %{String.t() => Decimal.t()},
          estimated_gas: non_neg_integer() | nil,
          estimated_fee: Decimal.t() | nil,
          fee_asset: String.t() | nil,
          expected_output: Decimal.t() | nil,
          slippage_bps: non_neg_integer() | nil,
          route: map() | nil,
          failure_conditions: [String.t()],
          failure_reason: String.t() | nil,
          risk_flags: [String.t()],
          source: source(),
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
            failure_reason: nil,
            risk_flags: [],
            source: :stub,
            provider: "unknown",
            provider_trace_ref: nil,
            generated_at: nil,
            freshness_ttl_seconds: 30
end
