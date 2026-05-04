defmodule Bank.DefiVenues.Morpho.VaultSnapshot do
  @moduledoc """
  Normalised Morpho vault snapshot (#198).

  This is the structured shape `Bank.DefiVenues.Morpho.Client` returns
  after fetching `vaultByAddress` and projecting the GraphQL
  response into a stable, code-controlled struct. Downstream
  consumers (risk explanation, decision-pipeline integration) read
  this struct — they NEVER touch the raw GraphQL payload.

  ## Source metadata

  Every snapshot carries a `:source` envelope with:

    * `:fetched_at` — wall-clock UTC of the successful fetch
    * `:source_name` — fixed string `"morpho_api"` for now; the
      future on-chain source will use a different name
    * `:source_schema_version` — pinned by
      `Bank.DefiVenues.Morpho.GraphQL.source_schema_version/0` so a
      consumer can detect drift across deploys
    * `:payload_hash` — lowercase hex SHA-256 of the raw response
      body bytes (deterministic across pretty-print / minified
      JSON variants because we hash the bytes Req actually
      received, not a re-serialised form)
    * `:warnings` — preserved verbatim from the response's
      `warnings` array (raw `:type` + `:level`, never blindly
      mapped to a final severity here — that's the risk engine's
      job in #201)
    * `:field_warnings` — internal list of `{:deprecated_field,
      "..."}` / `{:missing_field, "..."}` markers the normaliser
      added when the response shape diverged from the expected
      schema. Consumers can show these in the operator UI to
      flag a degraded snapshot without crashing on a renamed
      field.

  ## Notes on numeric fields

  Morpho returns large integers (vault `totalAssets`, supply
  caps, supplied assets) as strings in JSON to avoid 53-bit
  precision loss. We preserve the raw string in this struct so a
  downstream consumer can decide whether to use `Decimal`,
  `Integer.parse/1`, or display it verbatim — the snapshot
  layer does NOT silently lose precision.
  """

  @type t :: %__MODULE__{
          # vault identity
          chain_id: integer(),
          chain_network: String.t() | nil,
          address: String.t(),
          name: String.t() | nil,
          symbol: String.t() | nil,
          listed: boolean() | nil,

          # deposit asset
          asset_address: String.t() | nil,
          asset_symbol: String.t() | nil,
          asset_decimals: integer() | nil,

          # vault state
          apy: float() | nil,
          net_apy: float() | nil,
          total_assets: String.t() | nil,
          fee: String.t() | nil,
          timelock: integer() | nil,

          # allocation
          allocations: [allocation()],
          warnings: [warning()],
          pending_caps: [pending_cap()],
          allocators: [String.t()],
          public_allocator_config: public_allocator_config() | nil,

          # source metadata envelope
          source: source()
        }

  @type allocation :: %{
          market_unique_key: String.t() | nil,
          loan_asset_address: String.t() | nil,
          loan_asset_symbol: String.t() | nil,
          loan_asset_decimals: integer() | nil,
          collateral_asset_address: String.t() | nil,
          collateral_asset_symbol: String.t() | nil,
          collateral_asset_decimals: integer() | nil,
          oracle_address: String.t() | nil,
          irm_address: String.t() | nil,
          lltv: String.t() | nil,
          supply_cap: String.t() | nil,
          supply_assets: String.t() | nil,
          supply_assets_usd: String.t() | nil
        }

  @type warning :: %{type: String.t() | nil, level: String.t() | nil}

  @type pending_cap :: %{
          market_unique_key: String.t() | nil,
          supply_cap: String.t() | nil,
          valid_at: String.t() | nil
        }

  @type public_allocator_config :: %{
          fee: String.t() | nil,
          accrued_fee: String.t() | nil
        }

  @type source :: %{
          fetched_at: DateTime.t(),
          source_name: String.t(),
          source_schema_version: String.t(),
          payload_hash: String.t(),
          warnings: [warning()],
          field_warnings: [field_warning()]
        }

  @type field_warning ::
          {:deprecated_field, String.t()}
          | {:missing_field, String.t()}
          | {:unknown_field, String.t()}

  defstruct [
    :chain_id,
    :chain_network,
    :address,
    :name,
    :symbol,
    :listed,
    :asset_address,
    :asset_symbol,
    :asset_decimals,
    :apy,
    :net_apy,
    :total_assets,
    :fee,
    :timelock,
    allocations: [],
    warnings: [],
    pending_caps: [],
    allocators: [],
    public_allocator_config: nil,
    source: nil
  ]
end
