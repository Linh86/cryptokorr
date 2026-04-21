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
          cryptobank_fee: Decimal.t() | nil,
          total_fee: Decimal.t() | nil
        }

  @enforce_keys [:provider, :request, :route_kind, :legs, :input_amount, :output_amount, :quoted_at]

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
      cryptobank_fee: nil,
      total_fee: nil
    },
    eta_seconds: nil,
    risk_flags: [],
    provider_metadata: %{}
  ]
end

defmodule Bank.Stablecoins.RouteLeg do
  @moduledoc """
  A single leg of a multi-step route.

  Swap routes have one leg. Bridge routes have one leg.
  Swap+bridge routes have two or more legs.
  """

  @type t :: %__MODULE__{
          step: non_neg_integer(),
          kind: :swap | :bridge,
          source_chain: String.t(),
          source_asset: String.t(),
          source_address: String.t(),
          dest_chain: String.t(),
          dest_asset: String.t(),
          dest_address: String.t(),
          input_amount: Decimal.t(),
          output_amount: Decimal.t(),
          protocol: String.t() | nil,
          pool_address: String.t() | nil,
          eta_seconds: non_neg_integer() | nil,
          metadata: map()
        }

  @enforce_keys [:step, :kind, :source_chain, :source_asset, :dest_chain, :dest_asset, :input_amount, :output_amount]

  defstruct [
    :step,
    :kind,
    :source_chain,
    :source_asset,
    :source_address,
    :dest_chain,
    :dest_asset,
    :dest_address,
    :input_amount,
    :output_amount,
    :protocol,
    :pool_address,
    :eta_seconds,
    metadata: %{}
  ]
end
