defmodule Bank.Stablecoins.Providers.Jupiter do
  @moduledoc """
  Jupiter adapter for same-chain Solana USDC/USDT swaps.

  Implements `Bank.Stablecoins.Provider`, calling the Jupiter Quote
  API v6 for same-chain swap quotes on Solana and normalizing
  responses into `%RouteQuote{}`.

  Supported chain: solana only.
  Supported pairs: USDC <-> USDT (same chain only).

  The adapter calls `/v6/quote` to obtain pricing and the route plan.
  The full quote response is preserved in `provider_metadata` so the
  execution layer can pass it to Jupiter's `/v6/swap` endpoint later
  to build a serialized Solana transaction.

  ## Configuration

      config :bank, Bank.Stablecoins.Providers.Jupiter,
        base_url: "https://quote-api.jup.ag",
        api_key: nil, # optional; Jupiter public API works without auth
        req_options: []

  Tests override `:req_options` with
  `[plug: {Req.Test, Bank.Stablecoins.Providers.Jupiter}]`.
  """

  @behaviour Bank.Stablecoins.Provider

  require Logger

  alias Bank.Stablecoins.{QuoteRequest, RouteLeg, RouteQuote}

  @quote_ttl_seconds 30

  @impl true
  def provider_id, do: "jupiter"

  @impl true
  def quote(%QuoteRequest{route_kind: :swap} = req) do
    with :ok <- validate_chain(req.source_chain),
         {:ok, body} <- fetch_quote(req) do
      normalize(req, body)
    end
  end

  def quote(%QuoteRequest{}), do: {:error, :unsupported_route}

  # -- Chain gate -----------------------------------------------------------

  defp validate_chain("solana"), do: :ok
  defp validate_chain(_), do: {:error, :unsupported_route}

  # -- HTTP -----------------------------------------------------------------

  defp fetch_quote(req) do
    config = Application.get_env(:bank, __MODULE__, [])
    sell_amount = to_base_units(req.amount, req.source_token.decimals)
    slippage = req.slippage_bps || 50

    params = [
      inputMint: req.source_token.address,
      outputMint: req.dest_token.address,
      amount: sell_amount,
      slippageBps: slippage,
      swapMode: "ExactIn"
    ]

    request_quote(params, config)
  end

  defp request_quote(params, config) do
    base_url = Keyword.get(config, :base_url, "https://quote-api.jup.ag")
    api_key = Keyword.get(config, :api_key)
    extra = Keyword.get(config, :req_options, [])

    headers =
      [{"accept", "application/json"}]
      |> maybe_append_auth(api_key)

    req_opts =
      [
        base_url: base_url,
        url: "/v6/quote",
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

  defp maybe_append_auth(headers, nil), do: headers
  defp maybe_append_auth(headers, ""), do: headers
  defp maybe_append_auth(headers, key), do: [{"authorization", "Bearer " <> key} | headers]

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
    if no_route?(body) do
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

  defp no_route?(%{"error" => err}) when is_binary(err) do
    downcased = String.downcase(err)

    String.contains?(downcased, "could not find route") or
      String.contains?(downcased, "no route found") or
      String.contains?(downcased, "insufficient liquidity")
  end

  defp no_route?(%{"errorCode" => code}) when is_binary(code) do
    code == "ROUTE_NOT_FOUND"
  end

  defp no_route?(_), do: false

  # -- Normalization --------------------------------------------------------

  defp normalize(req, body) do
    with {:ok, in_amount} <- parse_base_units(body, "inAmount", req.source_token.decimals),
         {:ok, out_amount} <- parse_base_units(body, "outAmount", req.dest_token.decimals) do
      total_fee = Decimal.sub(in_amount, out_amount)
      protocol_fee = parse_platform_fee(body, req.source_token.decimals)
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
        input_amount: in_amount,
        output_amount: out_amount,
        protocol: primary_dex(body),
        metadata: leg_metadata(body)
      }

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: :swap,
         legs: [leg],
         input_amount: in_amount,
         output_amount: out_amount,
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
         explanation:
           "#{req.source_asset}->#{req.dest_asset} swap via Jupiter on solana",
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

  defp parse_platform_fee(body, decimals) do
    case get_in(body, ["platformFee", "amount"]) do
      nil -> nil
      raw ->
        case from_base_units(raw, decimals) do
          {:ok, d} -> d
          _ -> nil
        end
    end
  end

  defp primary_dex(body) do
    case get_in(body, ["routePlan"]) do
      [%{"swapInfo" => %{"label" => label}} | _] -> label
      _ -> "Jupiter"
    end
  end

  defp leg_metadata(body) do
    %{}
    |> put_if("priceImpactPct", Map.get(body, "priceImpactPct"))
    |> put_if("contextSlot", Map.get(body, "contextSlot"))
    |> put_if("otherAmountThreshold", Map.get(body, "otherAmountThreshold"))
  end

  defp provider_metadata(body) do
    %{}
    |> put_if("quoteResponse", body)
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, val), do: Map.put(map, key, val)
end
