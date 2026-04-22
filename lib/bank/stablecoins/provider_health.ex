defmodule Bank.Stablecoins.ProviderHealth do
  @moduledoc """
  Tracks success/failure health state for stablecoin route providers.

  Follows the same ETS-backed GenServer pattern as
  `Bank.WalletScreening.FeedHealth`. Each provider's quote attempts
  are recorded so operators can see which providers are healthy,
  degraded, or failing.

  Node-local and volatile: restarts reset to `:unknown`.

  ## Public surface

      record_success(provider_id)
      record_failure(provider_id, reason)
      get(provider_id)
      all()
  """

  use GenServer

  @table :stablecoin_provider_health

  @type provider_state :: %{
          provider: String.t(),
          status: :healthy | :degraded | :failing | :unknown,
          success_count: non_neg_integer(),
          failure_count: non_neg_integer(),
          rate_limited_count: non_neg_integer(),
          no_route_count: non_neg_integer(),
          last_success_at: DateTime.t() | nil,
          last_failure_at: DateTime.t() | nil,
          last_failure_reason: term() | nil
        }

  # --- Client API --------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record_success(String.t()) :: :ok
  def record_success(provider_id) when is_binary(provider_id) do
    now = DateTime.utc_now()
    current = get(provider_id)

    state = %{
      current
      | status: :healthy,
        success_count: current.success_count + 1,
        last_success_at: now
    }

    :ets.insert(@table, {provider_id, state})
    :ok
  end

  @spec record_failure(String.t(), term()) :: :ok
  def record_failure(provider_id, reason) when is_binary(provider_id) do
    now = DateTime.utc_now()
    current = get(provider_id)

    state =
      current
      |> Map.merge(%{
        failure_count: current.failure_count + 1,
        last_failure_at: now,
        last_failure_reason: reason
      })
      |> increment_reason_counter(reason)
      |> compute_status()

    :ets.insert(@table, {provider_id, state})
    :ok
  end

  @spec get(String.t()) :: provider_state()
  def get(provider_id) when is_binary(provider_id) do
    case :ets.lookup(@table, provider_id) do
      [{^provider_id, state}] -> state
      [] -> new_state(provider_id)
    end
  end

  @spec all() :: [provider_state()]
  def all do
    :ets.tab2list(@table) |> Enum.map(fn {_k, v} -> v end)
  end

  # --- Observation from RouteSelector results ---

  @spec observe_selector_result(term()) :: :ok
  def observe_selector_result({:ok, route_quote, meta}) do
    record_success(route_quote.provider)

    Enum.each(meta[:errors] || [], fn %{provider: mod, error: reason} ->
      record_failure(provider_id_for(mod), reason)
    end)

    :ok
  end

  def observe_selector_result({:error, {:no_quotes, errors}}) do
    Enum.each(errors, fn %{provider: mod, error: reason} ->
      record_failure(provider_id_for(mod), reason)
    end)

    :ok
  end

  def observe_selector_result(_), do: :ok

  # --- GenServer callbacks ------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # --- Internal -----------------------------------------------------------

  defp new_state(provider_id) do
    %{
      provider: provider_id,
      status: :unknown,
      success_count: 0,
      failure_count: 0,
      rate_limited_count: 0,
      no_route_count: 0,
      last_success_at: nil,
      last_failure_at: nil,
      last_failure_reason: nil
    }
  end

  defp increment_reason_counter(state, :rate_limited) do
    Map.update!(state, :rate_limited_count, &(&1 + 1))
  end

  defp increment_reason_counter(state, :no_route_found) do
    Map.update!(state, :no_route_count, &(&1 + 1))
  end

  defp increment_reason_counter(state, _), do: state

  defp compute_status(state) do
    total = state.success_count + state.failure_count

    cond do
      total == 0 -> %{state | status: :unknown}
      state.failure_count == 0 -> %{state | status: :healthy}
      state.success_count / total >= 0.8 -> %{state | status: :degraded}
      true -> %{state | status: :failing}
    end
  end

  defp provider_id_for(mod) when is_atom(mod) do
    if function_exported?(mod, :provider_id, 0) do
      mod.provider_id()
    else
      mod |> Module.split() |> List.last() |> String.downcase()
    end
  end
end
