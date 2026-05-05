defmodule Bank.DefiVenues.Morpho.OnChainVaultFacts do
  @moduledoc """
  Read-only on-chain ERC-4626 fact snapshot for a Morpho vault
  (#200). The shape `Bank.DefiVenues.Morpho.OnChainFacts.read_facts/3`
  returns to risk-explanation logic that needs values it must NOT
  trust the off-chain GraphQL API for.

  ## Why on-chain facts

  The Morpho GraphQL API surfaces `vaultByAddress.asset.address`,
  `vaultByAddress.state.totalAssets`, and similar fields for
  analytics / UI. Decision-time risk gates (deposit asset
  mismatch, supply-cap headroom, withdraw exit-liquidity) MUST
  re-verify those facts against the chain before acting — the
  API can be stale, deprecated, or compromised. This struct
  carries the on-chain truth.

  ## Numeric encoding

  `total_assets`, `max_deposit`, `max_withdraw`, `preview_redeem`
  are returned as decimal strings (the integer value of the
  decoded uint256, base-10). Strings — not integers — to avoid
  53-bit precision loss when downstream consumers cross JSON.
  Addresses (`asset`) are 0x-prefixed lowercase 20-byte hex.

  ## Source metadata

    * `:fetched_at` — UTC timestamp of the last successful read
    * `:source_warnings` — list of `{:missing_field, field}` /
      `{:account_unavailable, reason}` markers when an optional
      field could not be read but the read overall succeeded.
      An optional `maxDeposit(account)` / `maxWithdraw(account)`
      that reverts (some vaults / paused states) is recorded
      here as `{:account_unavailable, ...}` rather than failing
      the whole read.
  """

  @type t :: %__MODULE__{
          chain_id: integer(),
          vault_address: String.t(),
          account: String.t() | nil,
          asset: String.t() | nil,
          total_assets: String.t() | nil,
          max_deposit: String.t() | nil,
          max_withdraw: String.t() | nil,
          preview_redeem: String.t() | nil,
          fetched_at: DateTime.t(),
          source_warnings: [source_warning()]
        }

  @type source_warning ::
          {:missing_field, atom()}
          | {:account_unavailable, atom()}

  @enforce_keys [:chain_id, :vault_address, :fetched_at]
  defstruct [
    :chain_id,
    :vault_address,
    :account,
    :asset,
    :total_assets,
    :max_deposit,
    :max_withdraw,
    :preview_redeem,
    :fetched_at,
    source_warnings: []
  ]
end
