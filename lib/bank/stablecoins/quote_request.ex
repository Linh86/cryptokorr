defmodule Bank.Stablecoins.QuoteRequest do
  @moduledoc """
  Validated quote request for stablecoin routing.

  Covers same-chain swaps (USDC <-> USDT), cross-chain bridges
  (USDC -> USDC), and combined swap+bridge routes. Token metadata
  is resolved from `Bank.Stablecoins.Registry` at build time.

  ## Route kinds

    * `:swap` — same chain, different asset
    * `:bridge` — different chain, same asset
    * `:swap_plus_bridge` — different chain, different asset
  """

  alias Bank.Stablecoins.Registry

  @type t :: %__MODULE__{
          source_chain: String.t(),
          source_asset: String.t(),
          source_token: Registry.token(),
          dest_chain: String.t(),
          dest_asset: String.t(),
          dest_token: Registry.token(),
          amount: Decimal.t(),
          slippage_bps: non_neg_integer() | nil,
          route_kind: :swap | :bridge | :swap_plus_bridge,
          metadata: map()
        }

  @enforce_keys [
    :source_chain,
    :source_asset,
    :source_token,
    :dest_chain,
    :dest_asset,
    :dest_token,
    :amount,
    :route_kind
  ]

  defstruct [
    :source_chain,
    :source_asset,
    :source_token,
    :dest_chain,
    :dest_asset,
    :dest_token,
    :amount,
    :route_kind,
    slippage_bps: nil,
    metadata: %{}
  ]

  @type build_error ::
          :unsupported_source_chain
          | :unsupported_source_asset
          | :unsupported_dest_chain
          | :unsupported_dest_asset
          | :invalid_amount
          | :same_token
          | :source_token_blocked
          | :dest_token_blocked

  @doc """
  Build and validate a quote request.

  Resolves token metadata from the registry, validates the route
  kind, and returns `{:ok, %QuoteRequest{}}` or
  `{:error, reason}`.
  """
  @spec build(map()) :: {:ok, t()} | {:error, build_error()}
  def build(params) when is_map(params) do
    with {:ok, source_chain} <- require_string(params, :source_chain),
         {:ok, source_asset} <- require_string(params, :source_asset),
         {:ok, dest_chain} <- require_string(params, :dest_chain),
         {:ok, dest_asset} <- require_string(params, :dest_asset),
         {:ok, amount} <- parse_amount(params),
         {:ok, source_token} <- resolve_source(source_chain, source_asset),
         {:ok, dest_token} <- resolve_dest(dest_chain, dest_asset),
         :ok <- validate_not_same(source_chain, source_asset, dest_chain, dest_asset),
         :ok <- validate_status(source_token, :source_token_blocked),
         :ok <- validate_status(dest_token, :dest_token_blocked) do
      route_kind = derive_route_kind(source_chain, source_asset, dest_chain, dest_asset)
      slippage = Map.get(params, :slippage_bps) || Map.get(params, "slippage_bps")

      {:ok,
       %__MODULE__{
         source_chain: source_chain,
         source_asset: source_asset,
         source_token: source_token,
         dest_chain: dest_chain,
         dest_asset: dest_asset,
         dest_token: dest_token,
         amount: amount,
         slippage_bps: slippage,
         route_kind: route_kind,
         metadata: Map.get(params, :metadata, %{})
       }}
    end
  end

  defp require_string(params, key) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    case value do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, :"missing_#{key}"}
    end
  end

  defp parse_amount(params) do
    raw = Map.get(params, :amount) || Map.get(params, "amount")

    case raw do
      %Decimal{} = d ->
        if Decimal.compare(d, Decimal.new(0)) == :gt, do: {:ok, d}, else: {:error, :invalid_amount}

      s when is_binary(s) ->
        case Decimal.parse(s) do
          {d, ""} ->
            if Decimal.compare(d, Decimal.new(0)) == :gt, do: {:ok, d}, else: {:error, :invalid_amount}

          _ ->
            {:error, :invalid_amount}
        end

      n when is_integer(n) and n > 0 ->
        {:ok, Decimal.new(n)}

      n when is_float(n) and n > 0 ->
        {:ok, Decimal.from_float(n)}

      _ ->
        {:error, :invalid_amount}
    end
  end

  defp resolve_source(chain, asset) do
    case Registry.resolve(chain, asset) do
      {:ok, token} -> {:ok, token}
      {:error, :unsupported_chain} -> {:error, :unsupported_source_chain}
      {:error, :unsupported_asset} -> {:error, :unsupported_source_asset}
      {:error, _} -> {:error, :unsupported_source_asset}
    end
  end

  defp resolve_dest(chain, asset) do
    case Registry.resolve(chain, asset) do
      {:ok, token} -> {:ok, token}
      {:error, :unsupported_chain} -> {:error, :unsupported_dest_chain}
      {:error, :unsupported_asset} -> {:error, :unsupported_dest_asset}
      {:error, _} -> {:error, :unsupported_dest_asset}
    end
  end

  defp validate_not_same(chain, asset, chain, asset), do: {:error, :same_token}
  defp validate_not_same(_, _, _, _), do: :ok

  defp validate_status(%{status: :blocked}, error_atom), do: {:error, error_atom}
  defp validate_status(_, _), do: :ok

  defp derive_route_kind(chain, _src, chain, _dst), do: :swap
  defp derive_route_kind(_src_chain, asset, _dst_chain, asset), do: :bridge
  defp derive_route_kind(_, _, _, _), do: :swap_plus_bridge
end
