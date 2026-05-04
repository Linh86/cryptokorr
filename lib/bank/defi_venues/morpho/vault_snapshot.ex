defmodule Bank.DefiVenues.Morpho.VaultSnapshot do
  @moduledoc """
  Normalized contract for a single Morpho vault snapshot fetched
  via the Morpho Blue GraphQL API (#198).

  This struct is the *internal* shape downstream Morpho work
  (#199 persistence, #201 risk explanation, #202 policy rules,
  #208 audit/replay) consumes. It deliberately preserves
  upstream raw enum values for `warnings` (`raw_type`,
  `raw_level`) so risk-explanation logic that runs later can map
  them without re-fetching.

  The struct is **read-only** — there is no changeset, no
  persistence, no Ecto schema. It is a pure transient value
  produced by `Bank.DefiVenues.Morpho.Client.fetch_vault_by_address/3`
  from a GraphQL response body.

  ## Source-metadata block

  Every snapshot carries a `source` map with:

    * `:fetched_at` — when the client fetched the response
    * `:source_name` — the literal `"morpho_blue_graphql"`
    * `:source_schema_version` — schema-version sentinel; bumped
      when the normalized shape changes in a backwards-
      incompatible way
    * `:source_warnings` — non-fatal upstream warnings preserved
      verbatim (e.g. the deprecation note that `whitelisted` is
      replaced by `listed`)
    * `:payload_hash` — `sha256(:erlang.term_to_binary(raw_body))`
      hex-encoded; stable across identical responses so callers
      can dedupe and detect upstream-shape drift

  Field-level normalization is intentionally conservative:
  numeric strings from the GraphQL API are preserved as
  strings; only enums (`network`, `direction`) and obviously
  numeric scalars (`decimals`, `lltv`) are coerced to native
  types. This keeps the snapshot deterministic on round-trip
  and avoids precision loss for token amounts.
  """

  @type allocation :: %{
          market_unique_key: String.t(),
          loan_asset: String.t() | nil,
          collateral_asset: String.t() | nil,
          oracle: String.t() | nil,
          irm: String.t() | nil,
          lltv: integer() | nil,
          supply_cap: String.t() | nil,
          supplied_assets: String.t() | nil,
          supplied_assets_usd: String.t() | nil
        }

  @type warning :: %{raw_type: String.t(), raw_level: String.t() | nil}

  @type pending_cap :: %{
          market_unique_key: String.t() | nil,
          cap: String.t() | nil,
          valid_at: String.t() | nil
        }

  @type allocator :: %{address: String.t() | nil}

  @type asset :: %{
          address: String.t() | nil,
          symbol: String.t() | nil,
          decimals: integer() | nil
        }

  @type state :: %{
          apy: String.t() | nil,
          net_apy: String.t() | nil,
          total_assets: String.t() | nil,
          fee: String.t() | nil,
          timelock: integer() | nil
        }

  @type source :: %{
          fetched_at: DateTime.t(),
          source_name: String.t(),
          source_schema_version: String.t(),
          source_warnings: [String.t()],
          payload_hash: String.t()
        }

  @type t :: %__MODULE__{
          vault_address: String.t(),
          name: String.t() | nil,
          symbol: String.t() | nil,
          chain_id: integer(),
          network: String.t() | nil,
          deposit_asset: asset(),
          listed: boolean() | nil,
          state: state(),
          allocations: [allocation()],
          warnings: [warning()],
          pending_caps: [pending_cap()],
          allocators: [allocator()],
          source: source()
        }

  @enforce_keys [:vault_address, :chain_id, :source]
  defstruct [
    :vault_address,
    :name,
    :symbol,
    :chain_id,
    :network,
    :listed,
    deposit_asset: %{address: nil, symbol: nil, decimals: nil},
    state: %{apy: nil, net_apy: nil, total_assets: nil, fee: nil, timelock: nil},
    allocations: [],
    warnings: [],
    pending_caps: [],
    allocators: [],
    source: nil
  ]
end
