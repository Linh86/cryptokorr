defmodule Bank.Stablecoins.RouteSelector do
  @moduledoc """
  Orchestrates provider quoting and selects the best route.

  Given a validated `%QuoteRequest{}`, fans out to applicable
  providers, collects quotes (tolerating partial failures), and
  returns the best quote according to deterministic selection
  criteria.

  ## Selection criteria (in order)

    1. Highest `output_amount`
    2. Lowest `fees.total_fee` (tie-break)
    3. Lowest `eta_seconds` (tie-break; nil treated as infinity)
    4. Stable provider priority order (deterministic last resort)

  ## Provider routing

    * `:swap` on EVM chains → 0x + 1inch (best of two)
    * `:swap` on Solana → Jupiter
    * `:bridge` → Circle CCTP
    * `:swap_plus_bridge` → composite: swap source USDT→USDC + CCTP bridge

  ## Failure handling

    * `:unsupported_route` errors are silently filtered
    * Other errors (`:provider_unavailable`, `:rate_limited`, etc.)
      are collected — if any provider succeeds the best quote wins
    * If all applicable providers fail, returns
      `{:error, {:no_quotes, errors}}` with per-provider detail

  ## Configuration

  Provider modules are injected via `providers` option for
  testability. Production defaults are read from application config:

      config :bank, Bank.Stablecoins.RouteSelector,
        swap_evm: [Bank.Stablecoins.Providers.ZeroX, Bank.Stablecoins.Providers.OneInch],
        swap_solana: [Bank.Stablecoins.Providers.Jupiter],
        bridge: [Bank.Stablecoins.Providers.CircleCCTP]
  """

  alias Bank.Stablecoins.{QuoteRequest, RouteQuote}

  @type select_result ::
          {:ok, RouteQuote.t(), select_metadata()}
          | {:error, :unsupported_route}
          | {:error, {:no_quotes, [provider_error()]}}
          | {:error, {:composite_route_failed, composite_error()}}

  @type select_metadata :: %{
          considered: non_neg_integer(),
          errors: [provider_error()],
          all_quotes: [RouteQuote.t()]
        }

  @type provider_error :: %{
          provider: module(),
          error: term()
        }

  @type composite_error :: %{
          failed_leg: :swap | :bridge,
          reason: term()
        }

  @type collected_quote :: %{
          provider_index: non_neg_integer(),
          quote: RouteQuote.t()
        }

  @evm_chains ~w(ethereum base arbitrum optimism polygon)

  @default_priority ~w(zerox oneinch jupiter circle_cctp)

  @doc """
  Select the best route for a validated quote request.

  Options:
    * `:providers` — override provider module list (for testing)
  """
  @spec select(QuoteRequest.t(), keyword()) :: select_result()
  def select(req, opts \\ [])

  def select(%QuoteRequest{route_kind: :swap_plus_bridge} = req, opts) do
    select_composite(req, opts)
  end

  def select(%QuoteRequest{} = req, opts) do
    providers = providers_for(req, opts)

    case providers do
      [] ->
        {:error, :unsupported_route}

      modules ->
        {quotes, errors} = collect_quotes(modules, req)

        case pick_best(quotes) do
          nil ->
            {:error, {:no_quotes, errors}}

          best ->
            {:ok, best,
             %{
               considered: length(quotes),
               errors: errors,
               all_quotes: Enum.map(quotes, & &1.quote)
             }}
        end
    end
  end

  # -- Provider resolution --------------------------------------------------

  defp providers_for(req, opts) do
    case Keyword.fetch(opts, :providers) do
      {:ok, list} when is_list(list) ->
        list

      _ ->
        config_providers(req)
    end
  end

  defp config_providers(%QuoteRequest{route_kind: :swap, source_chain: chain})
       when chain in @evm_chains do
    config(:swap_evm, default_swap_evm())
  end

  defp config_providers(%QuoteRequest{route_kind: :swap, source_chain: "solana"}) do
    config(:swap_solana, default_swap_solana())
  end

  defp config_providers(%QuoteRequest{route_kind: :bridge}) do
    config(:bridge, default_bridge())
  end

  defp config_providers(_), do: []

  defp config(key, default) do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp default_swap_evm do
    [Bank.Stablecoins.Providers.ZeroX, Bank.Stablecoins.Providers.OneInch]
  end

  defp default_swap_solana do
    [Bank.Stablecoins.Providers.Jupiter]
  end

  defp default_bridge do
    [Bank.Stablecoins.Providers.CircleCCTP]
  end

  # -- Quote collection -----------------------------------------------------

  defp collect_quotes(modules, req) do
    results =
      modules
      |> Enum.with_index()
      |> Enum.map(fn {mod, index} -> {mod, index, mod.quote(req)} end)

    quotes =
      results
      |> Enum.filter(fn {_mod, _index, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {_mod, index, {:ok, quote}} ->
        %{provider_index: index, quote: quote}
      end)

    errors =
      results
      |> Enum.reject(fn {_mod, _index, result} ->
        match?({:ok, _}, result) or match?({:error, :unsupported_route}, result)
      end)
      |> Enum.map(fn {mod, _index, {:error, reason}} ->
        %{provider: mod, error: reason}
      end)

    {quotes, errors}
  end

  # -- Selection ------------------------------------------------------------

  defp pick_best([]), do: nil
  defp pick_best([single]), do: single.quote

  defp pick_best(quotes) do
    quotes
    |> Enum.sort(&compare_quotes/2)
    |> List.first()
    |> Map.fetch!(:quote)
  end

  defp compare_quotes(a, b) do
    case Decimal.compare(a.quote.output_amount, b.quote.output_amount) do
      :gt -> true
      :lt -> false
      :eq -> break_tie(a, b)
    end
  end

  defp break_tie(a, b) do
    case compare_fees(a, b) do
      :lt -> true
      :gt -> false
      :eq -> break_tie_eta(a, b)
    end
  end

  defp compare_fees(a, b) do
    fee_a = a.quote.fees[:total_fee] || Decimal.new(0)
    fee_b = b.quote.fees[:total_fee] || Decimal.new(0)
    Decimal.compare(fee_a, fee_b)
  end

  defp break_tie_eta(a, b) do
    eta_a = a.quote.eta_seconds || 999_999
    eta_b = b.quote.eta_seconds || 999_999

    cond do
      eta_a < eta_b -> true
      eta_a > eta_b -> false
      true -> break_tie_provider(a, b)
    end
  end

  defp break_tie_provider(a, b) do
    a_priority = priority_index(a.quote.provider)
    b_priority = priority_index(b.quote.provider)

    case a_priority - b_priority do
      diff when diff < 0 -> true
      diff when diff > 0 -> false
      _ -> a.provider_index <= b.provider_index
    end
  end

  defp priority_index(provider_id),
    do: Enum.find_index(@default_priority, &(&1 == provider_id)) || 999

  # -- Composite swap+bridge routing ----------------------------------------

  defp select_composite(req, opts) do
    with :ok <- validate_composite(req),
         {:swap, {:ok, swap_quote, swap_meta}} <-
           {:swap, select_swap_leg(req, opts)},
         {:bridge, {:ok, bridge_quote, bridge_meta}} <-
           {:bridge, select_bridge_leg(req, swap_quote, opts)} do
      compose_route(req, swap_quote, swap_meta, bridge_quote, bridge_meta)
    else
      {:error, _} = err ->
        err

      {:swap, {:error, reason}} ->
        {:error, {:composite_route_failed, %{failed_leg: :swap, reason: reason}}}

      {:bridge, {:error, reason}} ->
        {:error, {:composite_route_failed, %{failed_leg: :bridge, reason: reason}}}
    end
  end

  defp validate_composite(%QuoteRequest{source_asset: "USDT", dest_asset: "USDC"}) do
    :ok
  end

  defp validate_composite(_), do: {:error, :unsupported_route}

  defp select_swap_leg(req, opts) do
    swap_params = %{
      source_chain: req.source_chain,
      source_asset: req.source_asset,
      dest_chain: req.source_chain,
      dest_asset: "USDC",
      amount: req.amount,
      slippage_bps: req.slippage_bps,
      metadata: req.metadata
    }

    with {:ok, swap_req} <- QuoteRequest.build(swap_params) do
      swap_opts =
        case Keyword.fetch(opts, :swap_providers) do
          {:ok, list} -> [providers: list]
          :error -> []
        end

      select(swap_req, swap_opts)
    end
  end

  defp select_bridge_leg(req, swap_quote, opts) do
    bridge_params = %{
      source_chain: req.source_chain,
      source_asset: "USDC",
      dest_chain: req.dest_chain,
      dest_asset: "USDC",
      amount: swap_quote.output_amount,
      metadata: req.metadata
    }

    with {:ok, bridge_req} <- QuoteRequest.build(bridge_params),
         :ok <- validate_bridge_tokens(bridge_req) do
      bridge_opts =
        case Keyword.fetch(opts, :bridge_providers) do
          {:ok, list} -> [providers: list]
          :error -> []
        end

      select(bridge_req, bridge_opts)
    end
  end

  defp validate_bridge_tokens(bridge_req) do
    source = bridge_req.source_token
    dest = bridge_req.dest_token

    if source[:canonical] == true and source[:status] == :active and
         dest[:canonical] == true and dest[:status] == :active do
      :ok
    else
      {:error, :unsupported_route}
    end
  end

  defp compose_route(req, swap_quote, swap_meta, bridge_quote, bridge_meta) do
    now = DateTime.utc_now()
    [swap_leg] = swap_quote.legs
    [bridge_leg] = bridge_quote.legs

    legs = [
      swap_leg,
      %{bridge_leg | step: 2}
    ]

    total_fee = sum_decimals(swap_quote.fees[:total_fee], bridge_quote.fees[:total_fee])
    eta = sum_nillable(swap_quote.eta_seconds, bridge_quote.eta_seconds)

    composite_quote = %RouteQuote{
      provider: "composite",
      request: req,
      route_kind: :swap_plus_bridge,
      legs: legs,
      input_amount: req.amount,
      output_amount: bridge_quote.output_amount,
      quoted_at: now,
      expires_at: swap_quote.expires_at,
      fees: %{
        gas_fee: nil,
        protocol_fee: nil,
        bridge_fee: bridge_quote.fees[:bridge_fee],
        cryptobank_fee: nil,
        total_fee: total_fee
      },
      eta_seconds: eta,
      risk_flags: Enum.uniq(swap_quote.risk_flags ++ bridge_quote.risk_flags),
      explanation:
        "#{req.source_asset}->USDC swap on #{req.source_chain}, then USDC bridge to #{req.dest_chain}",
      provider_metadata: %{
        "swap_leg" => %{
          "provider" => swap_quote.provider,
          "provider_metadata" => swap_quote.provider_metadata
        },
        "bridge_leg" => %{
          "provider" => bridge_quote.provider,
          "provider_metadata" => bridge_quote.provider_metadata
        }
      }
    }

    meta = %{
      considered: 1,
      errors: swap_meta.errors ++ bridge_meta.errors,
      all_quotes: [composite_quote],
      swap_meta: swap_meta,
      bridge_meta: bridge_meta
    }

    {:ok, composite_quote, meta}
  end

  defp sum_decimals(nil, nil), do: Decimal.new(0)
  defp sum_decimals(nil, b), do: b
  defp sum_decimals(a, nil), do: a
  defp sum_decimals(a, b), do: Decimal.add(a, b)

  defp sum_nillable(nil, nil), do: nil
  defp sum_nillable(nil, b), do: b
  defp sum_nillable(a, nil), do: a
  defp sum_nillable(a, b), do: a + b
end
