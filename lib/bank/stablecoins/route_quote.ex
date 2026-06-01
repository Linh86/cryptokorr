defmodule Bank.Stablecoins.RouteQuote do
  @moduledoc """
  Normalized route quote returned by a provider.

  Contains the full route with one or more legs, fee breakdown,
  timing estimates, risk flags, and provider metadata.
  """

  alias Bank.Stablecoins.{QuoteRequest, RouteLeg}

  @type t :: %__MODULE__{
          provider: String.t(),
          request: QuoteRequest.t(),
          route_kind: :swap | :bridge | :swap_plus_bridge,
          legs: [RouteLeg.t()],
          input_amount: Decimal.t(),
          output_amount: Decimal.t(),
          fees: fees(),
          eta_seconds: non_neg_integer() | nil,
          risk_flags: [String.t()],
          explanation: String.t() | nil,
          quoted_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          provider_metadata: map()
        }

  @type fees :: %{
          gas_fee: Decimal.t() | nil,
          protocol_fee: Decimal.t() | nil,
          bridge_fee: Decimal.t() | nil,
          cryptokorr_fee: Decimal.t() | nil,
          total_fee: Decimal.t() | nil
        }

  @enforce_keys [
    :provider,
    :request,
    :route_kind,
    :legs,
    :input_amount,
    :output_amount,
    :quoted_at
  ]

  defstruct [
    :provider,
    :request,
    :route_kind,
    :legs,
    :input_amount,
    :output_amount,
    :quoted_at,
    :expires_at,
    :explanation,
    fees: %{
      gas_fee: nil,
      protocol_fee: nil,
      bridge_fee: nil,
      cryptokorr_fee: nil,
      total_fee: nil
    },
    eta_seconds: nil,
    risk_flags: [],
    provider_metadata: %{}
  ]
end
