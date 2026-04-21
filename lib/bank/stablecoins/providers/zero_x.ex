defmodule Bank.Stablecoins.Providers.ZeroX do
  @moduledoc """
  0x adapter for same-chain EVM USDC/USDT swaps.

  Implements `Bank.Stablecoins.Provider`, calling the 0x Swap API
  for same-chain quotes on supported EVM chains and normalizing
  responses into `%RouteQuote{}`.

  Supported chains: ethereum, base, arbitrum, optimism, polygon.
  Supported pairs: USDC <-> USDT (same chain only).

  ## Configuration

      config :bank, Bank.Stablecoins.Providers.ZeroX,
        base_url: "https://api.0x.org",
        api_key: "...",
        req_options: []

  Tests override `:req_options` with
  `[plug: {Req.Test, Bank.Stablecoins.Providers.ZeroX}]`.
  """

  @behaviour Bank.Stablecoins.Provider

  require Logger

  alias Bank.Stablecoins.{QuoteRequest, RouteLeg, RouteQuote}

  @chain_ids %{
    "ethereum" => 1,
    "base" => 8453,
    "arbitrum" => 42161,
    "optimism" => 10,
    "polygon" => 137
  }

  @quote_ttl_seconds 60

  @impl true
  def provider_id, do: "zerox"

  @impl true
  def quote(%QuoteRequest{route_kind: :swap} = req) do
    with :ok <- validate_chain(req.source_chain),
         {:ok, body} <- fetch_quote(req) do
      normalize(req, body)
    end
  end

  def quote(%QuoteRequest{}), do: {:error, :unsupported_route}

  # -- Chain gate -----------------------------------------------------------

  defp validate_chain(chain) do
    if Map.has_key?(@chain_ids, chain), do: :ok, else: {:error, :unsupported_route}
  end

  # -- HTTP -----------------------------------------------------------------

  defp fetch_quote(req) do
    sell_amount = to_base_units(req.amount, req.source_token.decimals)

    params = [
      chainId: Map.fetch!(@chain_ids, req.source_chain),
      sellToken: req.source_token.address,
      buyToken: req.dest_token.address,
      sellAmount: sell_amount
    ]

    config = Application.get_env(:bank, __MODULE__, [])
    base_url = Keyword.get(config, :base_url, "https://api.0x.org")
    api_key = Keyword.get(config, :api_key)
    extra = Keyword.get(config, :req_options, [])

    headers =
      [{"accept", "application/json"}]
      |> maybe_append_api_key(api_key)

    req_opts =
      [
        base_url: base_url,
        url: "/swap/permit2/quote",
        method: :get,
        headers: headers,
        params: params,
        receive_timeout: 10_000,
        retry: false
      ]
      |> Keyword.merge(extra)

    req_opts
    |> Req.request()
    |> classify_response()
  end

  defp maybe_append_api_key(headers, nil), do: headers
  defp maybe_append_api_key(headers, key), do: [{"0x-api-key", key} | headers]

  # -- Response classification ----------------------------------------------

  defp classify_response({:ok, %Req.Response{status: 200, body: body}}) when is_map(body) do
    {:ok, body}
  end

  defp classify_response({:ok, %Req.Response{status: 429}}) do
    {:error, :rate_limited}
  end

  defp classify_response({:ok, %Req.Response{status: status}}) when status >= 500 do
    {:error, :provider_unavailable}
  end

  defp classify_response({:ok, %Req.Response{status: status, body: body}})
       when status in 400..499 do
    if no_liquidity?(body) do
      {:error, :no_route_found}
    else
      {:error, {:provider_error, %{status: status, body: body}}}
    end
  end

  defp classify_response({:error, %Req.TransportError{}}) do
    {:error, :provider_unavailable}
  end

  defp classify_response({:error, _reason}) do
    {:error, :provider_unavailable}
  end

  defp no_liquidity?(%{"reason" => reason}) when is_binary(reason) do
    String.contains?(reason, "INSUFFICIENT_ASSET_LIQUIDITY")
  end

  defp no_liquidity?(%{"code" => code}) when is_integer(code), do: code == 100
  defp no_liquidity?(_), do: false

  # -- Normalization --------------------------------------------------------

  defp normalize(req, body) do
    with {:ok, buy_amount} <- parse_base_units(body, "buyAmount", req.dest_token.decimals),
         {:ok, sell_amount} <- parse_base_units(body, "sellAmount", req.source_token.decimals) do
      total_fee = Decimal.sub(sell_amount, buy_amount)
      protocol_fee = parse_protocol_fee(body, req.dest_token.decimals)
      now = DateTime.utc_now()

      leg = %RouteLeg{
        step: 1,
        kind: :swap,
        source_chain: req.source_chain,
        source_asset: req.source_asset,
        source_address: req.source_token.address,
        dest_chain: req.dest_chain,
        dest_asset: req.dest_asset,
        dest_address: req.dest_token.address,
        input_amount: sell_amount,
        output_amount: buy_amount,
        protocol: primary_source(body),
        metadata: leg_metadata(body)
      }

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: :swap,
         legs: [leg],
         input_amount: sell_amount,
         output_amount: buy_amount,
         quoted_at: now,
         expires_at: DateTime.add(now, @quote_ttl_seconds, :second),
         fees: %{
           gas_fee: nil,
           protocol_fee: protocol_fee,
           bridge_fee: nil,
           cryptobank_fee: nil,
           total_fee: total_fee
         },
         eta_seconds: nil,
         risk_flags: [],
         explanation: "#{req.source_asset}->#{req.dest_asset} swap via 0x on #{req.source_chain}",
         provider_metadata: provider_metadata(body)
       }}
    else
      _ -> {:error, {:provider_error, %{reason: "malformed_response", body: body}}}
    end
  end

  # -- Amount helpers -------------------------------------------------------

  defp to_base_units(amount, decimals) do
    amount
    |> Decimal.mult(Decimal.new(Integer.pow(10, decimals)))
    |> Decimal.round(0)
    |> Decimal.to_integer()
    |> Integer.to_string()
  end

  defp from_base_units(raw, decimals) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, Decimal.div(Decimal.new(n), Decimal.new(Integer.pow(10, decimals)))}
      _ -> :error
    end
  end

  defp from_base_units(raw, decimals) when is_integer(raw) do
    {:ok, Decimal.div(Decimal.new(raw), Decimal.new(Integer.pow(10, decimals)))}
  end

  defp from_base_units(_, _), do: :error

  defp parse_base_units(body, field, decimals) do
    case Map.get(body, field) do
      nil -> :error
      raw -> from_base_units(raw, decimals)
    end
  end

  # -- Fee / metadata extraction --------------------------------------------

  defp parse_protocol_fee(body, decimals) do
    case get_in(body, ["fees", "zeroExFee", "amount"]) do
      nil ->
        nil

      raw ->
        case from_base_units(raw, decimals) do
          {:ok, d} -> d
          _ -> nil
        end
    end
  end

  defp primary_source(body) do
    case get_in(body, ["route", "fills"]) do
      [%{"source" => source} | _] ->
        source

      _ ->
        case Map.get(body, "sources") do
          [%{"name" => name, "proportion" => p} | _] when p != "0" -> name
          _ -> "0x"
        end
    end
  end

  defp leg_metadata(body) do
    %{}
    |> put_if("estimatedGas", Map.get(body, "estimatedGas"))
    |> put_if("gasPrice", Map.get(body, "gasPrice"))
    |> put_if("allowanceTarget", Map.get(body, "allowanceTarget"))
  end

  defp provider_metadata(body) do
    %{}
    |> put_if("transaction", Map.get(body, "transaction"))
    |> put_if("permit2", Map.get(body, "permit2"))
    |> put_if("minBuyAmount", Map.get(body, "minBuyAmount"))
    |> put_if("totalNetworkFee", Map.get(body, "totalNetworkFee"))
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, val), do: Map.put(map, key, val)
end
