defmodule Bank.Stablecoins.Providers.OneInch do
  @moduledoc """
  1inch adapter for same-chain EVM USDC/USDT swaps.

  Implements `Bank.Stablecoins.Provider`, calling the 1inch Swap API
  v6.1 for same-chain quotes on supported EVM chains and normalizing
  responses into `%RouteQuote{}`.

  Supported chains: ethereum, base, arbitrum, optimism, polygon.
  Supported pairs: USDC <-> USDT (same chain only).

  ## Configuration

      config :bank, Bank.Stablecoins.Providers.OneInch,
        base_url: "https://api.1inch.com",
        api_key: "...",
        from_address: "0x...", # optional fallback; request metadata wins
        req_options: []

  Tests override `:req_options` with
  `[plug: {Req.Test, Bank.Stablecoins.Providers.OneInch}]`.
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
  def provider_id, do: "oneinch"

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
    config = Application.get_env(:bank, __MODULE__, [])

    with {:ok, api_key} <- api_key(config),
         {:ok, from} <- from_address(req, config) do
      chain_id = Map.fetch!(@chain_ids, req.source_chain)
      sell_amount = to_base_units(req.amount, req.source_token.decimals)

      params =
        [
          src: req.source_token.address,
          dst: req.dest_token.address,
          amount: sell_amount,
          from: from,
          disableEstimate: true
        ]
        |> maybe_append_slippage(req.slippage_bps)

      request_swap(chain_id, params, api_key, config)
    end
  end

  defp request_swap(chain_id, params, api_key, config) do
    base_url = Keyword.get(config, :base_url, "https://api.1inch.com")
    extra = Keyword.get(config, :req_options, [])

    headers = [
      {"accept", "application/json"},
      {"authorization", "Bearer " <> api_key}
    ]

    req_opts =
      [
        base_url: base_url,
        url: "/swap/v6.1/#{chain_id}/swap",
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

  defp api_key(config) do
    case Keyword.get(config, :api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, {:provider_error, %{reason: "missing_api_key"}}}
    end
  end

  defp from_address(%QuoteRequest{metadata: metadata}, config) do
    case metadata_from(metadata) || Keyword.get(config, :from_address) do
      address when is_binary(address) and address != "" ->
        {:ok, address}

      _ ->
        {:error, {:provider_error, %{reason: "missing_from_address"}}}
    end
  end

  defp metadata_from(metadata) when is_map(metadata) do
    Map.get(metadata, :taker_address) || Map.get(metadata, "taker_address")
  end

  defp metadata_from(_), do: nil

  defp maybe_append_slippage(params, nil), do: params

  defp maybe_append_slippage(params, bps) do
    Keyword.put(params, :slippage, bps_to_percent(bps))
  end

  defp bps_to_percent(bps) when is_integer(bps) do
    Decimal.div(Decimal.new(bps), Decimal.new(100))
    |> Decimal.to_string(:normal)
  end

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

  defp no_liquidity?(%{"description" => desc}) when is_binary(desc) do
    downcased = String.downcase(desc)

    String.contains?(downcased, "insufficient liquidity") or
      String.contains?(downcased, "cannot estimate")
  end

  defp no_liquidity?(%{"error" => err}) when is_binary(err) do
    downcased = String.downcase(err)

    String.contains?(downcased, "insufficient liquidity")
  end

  defp no_liquidity?(_), do: false

  # -- Normalization --------------------------------------------------------

  defp normalize(req, body) do
    with {:ok, dst_amount} <- parse_dst_amount(body, req.dest_token.decimals) do
      total_fee = Decimal.sub(req.amount, dst_amount)
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
        input_amount: req.amount,
        output_amount: dst_amount,
        protocol: primary_protocol(body),
        metadata: leg_metadata(body)
      }

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: :swap,
         legs: [leg],
         input_amount: req.amount,
         output_amount: dst_amount,
         quoted_at: now,
         expires_at: DateTime.add(now, @quote_ttl_seconds, :second),
         fees: %{
           gas_fee: nil,
           protocol_fee: nil,
           bridge_fee: nil,
           cryptobank_fee: nil,
           total_fee: total_fee
         },
         eta_seconds: nil,
         risk_flags: [],
         explanation:
           "#{req.source_asset}->#{req.dest_asset} swap via 1inch on #{req.source_chain}",
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

  defp parse_dst_amount(body, decimals) do
    case Map.get(body, "dstAmount") do
      nil -> :error
      raw -> from_base_units(raw, decimals)
    end
  end

  # -- Protocol / metadata extraction ---------------------------------------

  defp primary_protocol(body) do
    case get_in(body, ["protocols"]) do
      [%{"hops" => [%{"protocols" => [%{"name" => name} | _]} | _]} | _] ->
        name

      [[[%{"name" => name} | _] | _] | _] ->
        name

      _ ->
        "1inch"
    end
  end

  defp leg_metadata(body) do
    %{}
    |> put_if("gas", get_in(body, ["tx", "gas"]))
    |> put_if("gasPrice", get_in(body, ["tx", "gasPrice"]))
  end

  defp provider_metadata(body) do
    %{}
    |> put_if("tx", Map.get(body, "tx"))
    |> put_if("protocols", Map.get(body, "protocols"))
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, val), do: Map.put(map, key, val)
end
