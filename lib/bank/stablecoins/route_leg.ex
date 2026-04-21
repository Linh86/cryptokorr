defmodule Bank.Stablecoins.RouteLeg do
  @moduledoc """
  A single leg of a multi-step stablecoin route.

  Swap routes have one leg. Bridge routes have one leg. Swap+bridge
  routes have two or more legs.
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

  @enforce_keys [
    :step,
    :kind,
    :source_chain,
    :source_asset,
    :dest_chain,
    :dest_asset,
    :input_amount,
    :output_amount
  ]

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
