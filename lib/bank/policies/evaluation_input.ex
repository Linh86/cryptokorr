defmodule Bank.Policies.EvaluationInput do
  @moduledoc """
  Candidate action under evaluation by the policy engine.

  The policy engine's canonical input is the `AgentIntent`, but a few
  swap-specific fields (`slippage_bps`, `router`) aren't first-class
  columns on `agent_intents` yet — v0.1 swap execution is whitelist-only
  and routes through the adapter. Rather than widen `AgentIntent` for
  values that have no home outside a swap candidate, this struct carries
  the superset the evaluator actually needs.

  Use `from_intent/2` at the integration seam to lift an intent into an
  evaluation input; tests that want to exercise swap-only rule types
  can build the struct directly.

  `now` is captured at evaluation time so the `time_window` and
  `rolling_spend_cap` evaluators read a single, consistent clock value
  rather than calling `DateTime.utc_now/0` multiple times.
  """

  alias Bank.Intents.AgentIntent

  @type t :: %__MODULE__{
          kind: atom() | nil,
          asset: String.t() | nil,
          chain: String.t() | nil,
          amount: Decimal.t() | nil,
          target_counterparty_id: Ecto.UUID.t() | nil,
          target_address_label_id: Ecto.UUID.t() | nil,
          target_raw_address: String.t() | nil,
          slippage_bps: non_neg_integer() | nil,
          router: String.t() | nil,
          intent_id: Ecto.UUID.t() | nil,
          submitted_at: DateTime.t() | nil,
          now: DateTime.t()
        }

  @enforce_keys [:kind, :asset, :chain, :amount]
  defstruct [
    :kind,
    :asset,
    :chain,
    :amount,
    :target_counterparty_id,
    :target_address_label_id,
    :target_raw_address,
    :slippage_bps,
    :router,
    :intent_id,
    :submitted_at,
    :now
  ]

  @doc """
  Build an `EvaluationInput` from an `AgentIntent`.

  `extras` may carry swap-only fields (`:slippage_bps`, `:router`) and
  an override `:now` for deterministic tests. Missing fields default
  to `nil` / the current wall clock.
  """
  @spec from_intent(AgentIntent.t(), map()) :: t()
  def from_intent(%AgentIntent{} = intent, extras \\ %{}) do
    %__MODULE__{
      kind: intent.kind,
      asset: intent.asset,
      chain: intent.chain,
      amount: intent.amount,
      target_counterparty_id: intent.target_counterparty_id,
      target_address_label_id: intent.target_address_label_id,
      target_raw_address: intent.target_raw_address,
      slippage_bps: Map.get(extras, :slippage_bps),
      router: Map.get(extras, :router),
      intent_id: intent.id,
      submitted_at: intent.submitted_at,
      now: Map.get(extras, :now) || DateTime.utc_now()
    }
  end
end
