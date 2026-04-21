defmodule Bank.Stablecoins.Registry do
  @moduledoc """
  Deterministic stablecoin token registry for MVP chains and assets.

  One strict source of truth for token identity across supported EVM
  chains and Solana. No network calls, no provider-derived metadata,
  no generic token list.

  ## Supported chains

  EVM: `ethereum`, `base`, `arbitrum`, `optimism`, `polygon`
  Non-EVM: `solana`

  ## Supported assets

  `USDC`, `USDT`

  ## Public API

      chains()                          # list supported chain ids
      assets()                          # list supported asset symbols
      resolve(chain, asset)             # canonical token by chain+asset
      resolve_by_address(chain, addr)   # token by contract address / mint
      supported_chain?(chain)           # guard
      supported_asset?(asset)           # guard

  ## Token shape

  Each entry is a map with:

      %{
        chain: "base",
        asset: "USDC",
        address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        decimals: 6,
        name: "USD Coin",
        standard: :erc20,            # or :spl_token for Solana
        status: :active,             # :active | :approval_only | :blocked
        issuer: "Circle",
        canonical: true,
        variant: :native,
        notes: "Circle native USDC"
      }

  ## Address normalisation

  EVM address lookups are case-insensitive (lowercased before
  comparison). Solana mint lookups are exact string matches (base58
  is case-sensitive).

  ## Canonicality

  Circle-native USDC entries are marked `canonical: true`. Tether's
  currently published supported-protocol guidance does not list the
  Base, Arbitrum, OP Mainnet, or Polygon PoS USDT representations used
  by routing providers, so those entries are deliberately
  `canonical: false` and `status: :approval_only` until provider- and
  policy-specific routing support pins them more tightly.
  """

  @type token :: %{
          chain: String.t(),
          asset: String.t(),
          address: String.t(),
          decimals: non_neg_integer(),
          name: String.t(),
          standard: :erc20 | :spl_token,
          status: :active | :approval_only | :blocked,
          issuer: String.t(),
          canonical: boolean(),
          variant: :native | :bridged,
          notes: String.t()
        }

  @type error :: {:error, :unsupported_chain | :unsupported_asset | :unknown_token}

  # --- Token data ---------------------------------------------------------

  @tokens [
    # Ethereum
    %{
      chain: "ethereum",
      asset: "USDC",
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      decimals: 6,
      name: "USD Coin",
      standard: :erc20,
      status: :active,
      issuer: "Circle",
      canonical: true,
      variant: :native,
      notes: "Circle native USDC"
    },
    %{
      chain: "ethereum",
      asset: "USDT",
      address: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
      decimals: 6,
      name: "Tether USD",
      standard: :erc20,
      status: :active,
      issuer: "Tether",
      canonical: true,
      variant: :native,
      notes: "Tether USDt on Ethereum"
    },

    # Base
    %{
      chain: "base",
      asset: "USDC",
      address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      decimals: 6,
      name: "USD Coin",
      standard: :erc20,
      status: :active,
      issuer: "Circle",
      canonical: true,
      variant: :native,
      notes: "Circle native USDC"
    },
    %{
      chain: "base",
      asset: "USDT",
      address: "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2",
      decimals: 6,
      name: "Tether USD",
      standard: :erc20,
      status: :approval_only,
      issuer: "Tether",
      canonical: false,
      variant: :bridged,
      notes:
        "Bridged USDT representation on Base; require policy approval until provider-specific route support is pinned"
    },

    # Arbitrum
    %{
      chain: "arbitrum",
      asset: "USDC",
      address: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
      decimals: 6,
      name: "USD Coin",
      standard: :erc20,
      status: :active,
      issuer: "Circle",
      canonical: true,
      variant: :native,
      notes: "Circle native USDC"
    },
    %{
      chain: "arbitrum",
      asset: "USDT",
      address: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9",
      decimals: 6,
      name: "Tether USD",
      standard: :erc20,
      status: :approval_only,
      issuer: "Tether",
      canonical: false,
      variant: :bridged,
      notes:
        "Bridged USDT representation on Arbitrum; require policy approval until provider-specific route support is pinned"
    },

    # Optimism
    %{
      chain: "optimism",
      asset: "USDC",
      address: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
      decimals: 6,
      name: "USD Coin",
      standard: :erc20,
      status: :active,
      issuer: "Circle",
      canonical: true,
      variant: :native,
      notes: "Circle native USDC"
    },
    %{
      chain: "optimism",
      asset: "USDT",
      address: "0x94b008aA00579c1307B0EF2c499aD98a8ce58e58",
      decimals: 6,
      name: "Tether USD",
      standard: :erc20,
      status: :approval_only,
      issuer: "Tether",
      canonical: false,
      variant: :bridged,
      notes:
        "Bridged USDT representation on OP Mainnet; require policy approval until provider-specific route support is pinned"
    },

    # Polygon PoS
    %{
      chain: "polygon",
      asset: "USDC",
      address: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359",
      decimals: 6,
      name: "USD Coin",
      standard: :erc20,
      status: :active,
      issuer: "Circle",
      canonical: true,
      variant: :native,
      notes: "Circle native USDC"
    },
    %{
      chain: "polygon",
      asset: "USDT",
      address: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F",
      decimals: 6,
      name: "Tether USD",
      standard: :erc20,
      status: :approval_only,
      issuer: "Tether",
      canonical: false,
      variant: :bridged,
      notes:
        "Bridged USDT representation on Polygon PoS; require policy approval until provider-specific route support is pinned"
    },

    # Solana
    %{
      chain: "solana",
      asset: "USDC",
      address: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
      decimals: 6,
      name: "USD Coin",
      standard: :spl_token,
      status: :active,
      issuer: "Circle",
      canonical: true,
      variant: :native,
      notes: "Circle native USDC"
    },
    %{
      chain: "solana",
      asset: "USDT",
      address: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",
      decimals: 6,
      name: "Tether USD",
      standard: :spl_token,
      status: :active,
      issuer: "Tether",
      canonical: true,
      variant: :native,
      notes: "Tether USDt on Solana"
    }
  ]

  @evm_chains ~w(ethereum base arbitrum optimism polygon)

  @supported_chains @tokens |> Enum.map(& &1.chain) |> Enum.uniq() |> Enum.sort()
  @supported_assets @tokens |> Enum.map(& &1.asset) |> Enum.uniq() |> Enum.sort()

  @by_chain_asset Map.new(@tokens, fn t -> {{t.chain, t.asset}, t} end)

  @by_chain_address Map.new(@tokens, fn t ->
                      key =
                        if t.chain in @evm_chains,
                          do: {t.chain, String.downcase(t.address)},
                          else: {t.chain, t.address}

                      {key, t}
                    end)

  # --- Public API ---------------------------------------------------------

  @doc "List all supported chain identifiers."
  @spec chains() :: [String.t()]
  def chains, do: @supported_chains

  @doc "List all supported asset symbols."
  @spec assets() :: [String.t()]
  def assets, do: @supported_assets

  @doc "Check if a chain is supported."
  @spec supported_chain?(String.t()) :: boolean()
  def supported_chain?(chain), do: chain in @supported_chains

  @doc "Check if an asset is supported."
  @spec supported_asset?(String.t()) :: boolean()
  def supported_asset?(asset), do: asset in @supported_assets

  @doc """
  Resolve the canonical token for a `{chain, asset}` pair.

  Returns `{:ok, token}` or `{:error, reason}`.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, token()} | error()
  def resolve(chain, asset) do
    cond do
      not supported_chain?(chain) ->
        {:error, :unsupported_chain}

      not supported_asset?(asset) ->
        {:error, :unsupported_asset}

      true ->
        case Map.get(@by_chain_asset, {chain, asset}) do
          nil -> {:error, :unknown_token}
          token -> {:ok, token}
        end
    end
  end

  @doc """
  Resolve a token by its contract address (EVM) or mint address (Solana).

  EVM lookups are case-insensitive. Solana lookups are exact.
  Returns `{:ok, token}` or `{:error, reason}`.
  """
  @spec resolve_by_address(String.t(), String.t()) :: {:ok, token()} | error()
  def resolve_by_address(chain, address) when is_binary(chain) and is_binary(address) do
    cond do
      not supported_chain?(chain) ->
        {:error, :unsupported_chain}

      true ->
        normalised = if evm_chain?(chain), do: String.downcase(address), else: address

        case Map.get(@by_chain_address, {chain, normalised}) do
          nil -> {:error, :unknown_token}
          token -> {:ok, token}
        end
    end
  end

  @doc "List all tokens in the registry."
  @spec all() :: [token()]
  def all, do: @tokens

  @doc "List all tokens for a specific chain."
  @spec for_chain(String.t()) :: [token()]
  def for_chain(chain), do: Enum.filter(@tokens, &(&1.chain == chain))

  @doc "List all tokens for a specific asset across all chains."
  @spec for_asset(String.t()) :: [token()]
  def for_asset(asset), do: Enum.filter(@tokens, &(&1.asset == asset))

  defp evm_chain?(chain), do: chain in @evm_chains
end
