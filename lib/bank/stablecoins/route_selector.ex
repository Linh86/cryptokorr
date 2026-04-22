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
    * `:swap_plus_bridge` → not yet supported (follow-up)

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

  @type select_metadata :: %{
          considered: non_neg_integer(),
          errors: [provider_error()],
          all_quotes: [RouteQuote.t()]
        }

  @type provider_error :: %{
          provider: module(),
          error: term()
        }

  @evm_chains ~w(ethereum base arbitrum optimism polygon)

  @default_priority ~w(zerox oneinch jupiter circle_cctp)

  @doc """
  Select the best route for a validated quote request.

  Options:
    * `:providers` — override provider module list (for testing)
  """
  @spec select(QuoteRequest.t(), keyword()) :: select_result()
  def select(%QuoteRequest{} = req, opts \\ []) do
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
               all_quotes: quotes
             }}
        end
    end
  end

  # -- Provider resolution --------------------------------------------------

  defp providers_for(req, opts) do
    case Keyword.get(opts, :providers) do
      list when is_list(list) and list != [] ->
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
    results = Enum.map(modules, fn mod -> {mod, mod.quote(req)} end)

    quotes =
      results
      |> Enum.filter(fn {_mod, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {_mod, {:ok, quote}} -> quote end)

    errors =
      results
      |> Enum.reject(fn {_mod, result} ->
        match?({:ok, _}, result) or match?({:error, :unsupported_route}, result)
      end)
      |> Enum.map(fn {mod, {:error, reason}} ->
        %{provider: mod, error: reason}
      end)

    {quotes, errors}
  end

  # -- Selection ------------------------------------------------------------

  defp pick_best([]), do: nil
  defp pick_best([single]), do: single

  defp pick_best(quotes) do
    quotes
    |> Enum.sort(&compare_quotes/2)
    |> List.first()
  end

  defp compare_quotes(a, b) do
    case Decimal.compare(a.output_amount, b.output_amount) do
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
    fee_a = a.fees[:total_fee] || Decimal.new(0)
    fee_b = b.fees[:total_fee] || Decimal.new(0)
    Decimal.compare(fee_a, fee_b)
  end

  defp break_tie_eta(a, b) do
    eta_a = a.eta_seconds || 999_999
    eta_b = b.eta_seconds || 999_999

    cond do
      eta_a < eta_b -> true
      eta_a > eta_b -> false
      true -> priority_index(a.provider) <= priority_index(b.provider)
    end
  end

  defp priority_index(provider_id) do
    case Enum.find_index(@default_priority, &(&1 == provider_id)) do
      nil -> 999
      idx -> idx
    end
  end
end
