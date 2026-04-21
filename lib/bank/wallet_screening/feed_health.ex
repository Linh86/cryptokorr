defmodule Bank.WalletScreening.FeedHealth do
  @moduledoc """
  Tracks freshness and health state for each wallet-screening source.

  Every successful or failed ingestion run updates the source's health
  state so operators can inspect which feeds are fresh, stale, or
  failing. The state is held in a named ETS table that survives
  process restarts within the same node (the table is owned by the
  application supervisor via a dedicated GenServer).

  ## Stale policy

  Each source has a staleness threshold based on its control tier:

    * **Sanctions** (`ofac`, `opensanctions`) — `severity: :high`,
      stale after 24 hours. Stale sanctions data is an operational
      emergency: the runtime should widen caution on execution.
    * **Scam feeds** (`scamsniffer`, `etherscamdb`, `btc_abuse`) —
      `severity: :warning`, stale after 48 hours. Stale scam data
      degrades challenge coverage but is not a legal risk.
    * **Context / score-only** (`graphsense`, `internal_scoring`) —
      `severity: :info`, stale after 7 days. Context and scoring
      data is enrichment; staleness is informational only.

  ## Public surface

      record_success(source, result)   # after successful ingestion
      record_failure(source, reason)   # after failed ingestion
      get(source)                      # single source health state
      all()                            # all sources health snapshot
      stale_sources()                  # only sources past their threshold
      stale_sources(severity)          # only sources at the given severity
  """

  use GenServer

  @table :wallet_screening_feed_health

  @source_config %{
    "ofac" => %{stale_after_hours: 24, severity: :high, tier: :hard_block},
    "opensanctions" => %{stale_after_hours: 24, severity: :high, tier: :hard_block},
    "scamsniffer" => %{stale_after_hours: 48, severity: :warning, tier: :challenge},
    "etherscamdb" => %{stale_after_hours: 48, severity: :warning, tier: :challenge},
    "btc_abuse" => %{stale_after_hours: 48, severity: :warning, tier: :challenge},
    "graphsense" => %{stale_after_hours: 168, severity: :info, tier: :context},
    "internal_scoring" => %{stale_after_hours: 168, severity: :info, tier: :score_only}
  }

  @type source_health :: %{
          source: String.t(),
          status: :fresh | :stale | :failed | :unknown,
          severity: :high | :warning | :info,
          tier: atom(),
          last_success_at: DateTime.t() | nil,
          last_failure_at: DateTime.t() | nil,
          last_failure_reason: term() | nil,
          last_ingested: non_neg_integer(),
          last_skipped: non_neg_integer(),
          stale_after_hours: non_neg_integer()
        }

  # --- Client API --------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a successful ingestion run."
  @spec record_success(String.t(), map(), keyword()) :: :ok
  def record_success(source, result, opts \\ []) when is_binary(source) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    config = source_config(source)

    state = %{
      source: source,
      status: :fresh,
      severity: config.severity,
      tier: config.tier,
      last_success_at: now,
      last_failure_at: get_field(source, :last_failure_at),
      last_failure_reason: get_field(source, :last_failure_reason),
      last_ingested: Map.get(result, :ingested, 0),
      last_skipped: Map.get(result, :skipped, 0),
      stale_after_hours: config.stale_after_hours
    }

    :ets.insert(@table, {source, state})
    :ok
  end

  @doc "Record a failed ingestion run."
  @spec record_failure(String.t(), term(), keyword()) :: :ok
  def record_failure(source, reason, opts \\ []) when is_binary(source) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    config = source_config(source)

    state = %{
      source: source,
      status: :failed,
      severity: config.severity,
      tier: config.tier,
      last_success_at: get_field(source, :last_success_at),
      last_failure_at: now,
      last_failure_reason: inspect(reason),
      last_ingested: get_field(source, :last_ingested) || 0,
      last_skipped: get_field(source, :last_skipped) || 0,
      stale_after_hours: config.stale_after_hours
    }

    :ets.insert(@table, {source, state})
    :ok
  end

  @doc "Get the health state for a single source."
  @spec get(String.t(), keyword()) :: source_health()
  def get(source, opts \\ []) when is_binary(source) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case :ets.lookup(@table, source) do
      [{^source, state}] -> apply_staleness(state, now)
      [] -> unknown_state(source)
    end
  end

  @doc "Get the health state for all known sources."
  @spec all(keyword()) :: [source_health()]
  def all(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    known =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_key, state} -> apply_staleness(state, now) end)

    known_sources = MapSet.new(known, & &1.source)

    missing =
      @source_config
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(known_sources, &1))
      |> Enum.map(&unknown_state/1)

    Enum.sort_by(known ++ missing, &severity_rank(&1.severity))
  end

  @doc "Get sources that are currently stale or failed."
  @spec stale_sources(keyword()) :: [source_health()]
  def stale_sources(opts \\ []) do
    all(opts)
    |> Enum.filter(&(&1.status in [:stale, :failed, :unknown]))
  end

  @doc "Get stale sources filtered by severity."
  @spec stale_sources_by_severity(atom(), keyword()) :: [source_health()]
  def stale_sources_by_severity(severity, opts \\ []) when severity in [:high, :warning, :info] do
    stale_sources(opts)
    |> Enum.filter(&(&1.severity == severity))
  end

  @doc "Reset all health state (test helper)."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  # --- GenServer ----------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # --- Internals ----------------------------------------------------------

  defp source_config(source) do
    Map.get(@source_config, source, %{
      stale_after_hours: 168,
      severity: :info,
      tier: :unknown
    })
  end

  defp get_field(source, field) do
    case :ets.lookup(@table, source) do
      [{^source, state}] -> Map.get(state, field)
      [] -> nil
    end
  end

  defp apply_staleness(%{status: :failed} = state, _now), do: state

  defp apply_staleness(%{last_success_at: nil} = state, _now),
    do: %{state | status: :unknown}

  defp apply_staleness(%{last_success_at: last, stale_after_hours: hours} = state, now) do
    threshold = DateTime.add(last, hours * 3600, :second)

    if DateTime.compare(now, threshold) == :gt do
      %{state | status: :stale}
    else
      %{state | status: :fresh}
    end
  end

  defp unknown_state(source) do
    config = source_config(source)

    %{
      source: source,
      status: :unknown,
      severity: config.severity,
      tier: config.tier,
      last_success_at: nil,
      last_failure_at: nil,
      last_failure_reason: nil,
      last_ingested: 0,
      last_skipped: 0,
      stale_after_hours: config.stale_after_hours
    }
  end

  defp severity_rank(:high), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 2
end
