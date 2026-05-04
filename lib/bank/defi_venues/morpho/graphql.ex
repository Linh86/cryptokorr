defmodule Bank.DefiVenues.Morpho.GraphQL do
  @moduledoc """
  GraphQL queries for the Morpho Blue API (#198).

  Phase 1 ships only the read queries `morpho_risk_explanation`
  needs — `vaultByAddress` with a curated field set. The query
  string lives in this module so a future iteration can add
  schema-version metadata or alternative queries without forking
  the client.

  ## Field selection

  Following `docs/morpho-risk-explanation.md` and the issue body:

    * `address`, `name`, `symbol`
    * `chain { id, network }`
    * `asset { address, symbol, decimals }`
    * `state { apy, netApy, totalAssets, fee, timelock,
       allocation { ... } }`
    * `warnings { type, level }`
    * `pendingCaps { market { uniqueKey }, supplyCap, validAt }`
    * `allocators { address }`
    * `publicAllocatorConfig { fee, accruedFee }`
    * `historicalState { apy { x y } netApy { x y } }`
    * `listed` (replaces `whitelisted`, which the live API
      flagged as deprecated on 2026-04-29 — see
      `docs/morpho-risk-explanation.md` lines 94-95)

  The query string is intentionally pretty-printed: one field per
  line so a future field add / removal shows up as a one-line
  diff.
  """

  @vault_by_address """
  query VaultByAddress($chainId: Int!, $address: String!) {
    vaultByAddress(chainId: $chainId, address: $address) {
      address
      name
      symbol
      listed
      chain {
        id
        network
      }
      asset {
        address
        symbol
        decimals
      }
      state {
        apy
        netApy
        totalAssets
        fee
        timelock
        allocation {
          market {
            uniqueKey
            loanAsset {
              address
              symbol
              decimals
            }
            collateralAsset {
              address
              symbol
              decimals
            }
            oracleAddress
            irmAddress
            lltv
          }
          supplyCap
          supplyAssets
          supplyAssetsUsd
        }
      }
      warnings {
        type
        level
      }
      pendingCaps {
        market {
          uniqueKey
        }
        supplyCap
        validAt
      }
      allocators {
        address
      }
      publicAllocatorConfig {
        fee
        accruedFee
      }
      historicalState {
        apy {
          x
          y
        }
        netApy {
          x
          y
        }
      }
    }
  }
  """

  @doc """
  Build the GraphQL request body for a `vaultByAddress` query.

  Returns the JSON-serialisable map expected by the Morpho
  endpoint: `%{"query" => ..., "variables" => %{...}}`.
  """
  @spec vault_by_address_body(integer(), String.t()) :: map()
  def vault_by_address_body(chain_id, vault_address)
      when is_integer(chain_id) and is_binary(vault_address) do
    %{
      "query" => @vault_by_address,
      "variables" => %{
        "chainId" => chain_id,
        "address" => vault_address
      }
    }
  end

  @doc "Source schema version pin. Bump when the curated field set above changes."
  @spec source_schema_version() :: String.t()
  def source_schema_version, do: "morpho-blue-vault-by-address.v1"
end
