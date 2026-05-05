defmodule Bank.Stablecoins.ProviderHealth do
  @moduledoc """
  Tracks success/failure health state for stablecoin route providers.

  Follows the same ETS-backed GenServer pattern as
  `Bank.WalletScreening.FeedHealth`. Each provider's quote attempts
  are recorded so operators can see which providers are healthy,
  degraded, or failing.

  Node-local and volatile: restarts reset to `:unknown`. The ETS
  store is the read-side hot path for `evaluate_for_intent/1`; it
  is intentionally global (not workspace-keyed) so a single quote
  attempt sees the same health verdict regardless of which
  workspace's intent triggered it.

  ## Durable transition log (#422)

  When `record_success/2` or `record_failure/3` is called with a
  `:workspace_id` opt AND the call observes one of the
  notification-relevant transitions (`:degraded → :failing` or
  `:failing → :healthy/:degraded`), a `Bank.Stablecoins.ProviderHealthEvent`
  row is appended. The durable log is the audit-side companion
  to the ETS read store; callers (`Bank.Stablecoins.IntentRouting`)
  use the returned `:event` to scope a workspace notification.

  Persisting the event row is best-effort: a Repo failure
  warns + returns `event: nil` but never rolls back the ETS
  state update.

  ## Public surface

      record_success(provider_id, opts \\\\ [])
      record_failure(provider_id, reason, opts \\\\ [])
      get(provider_id)
      all()
      reset()

  Both `record_*` functions return `{:ok, transition_info()}` —
  `from_state`, `to_state`, `state`, and the persisted
  `:event` (or `nil` when no `:workspace_id` opt was passed,
  no transition crossed a notification threshold, or the event
  insert failed).
  """

  use GenServer

  alias Bank.Repo
  alias Bank.Stablecoins.ProviderHealthEvent

  require Logger

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

  @type transition_info :: %{
          required(:from_state) => atom(),
          required(:to_state) => atom(),
          required(:state) => provider_state(),
          required(:event) => ProviderHealthEvent.t() | nil
        }

  @typedoc """
  Options accepted by `record_success/2` and `record_failure/3`.

    * `:workspace_id` — UUID. When present and the call observes
      a notification-relevant transition, a
      `Bank.Stablecoins.ProviderHealthEvent` row is inserted and
      returned in the result.
    * `:route_session_id` — UUID. Required if `:workspace_id`
      is supplied; identifies one routing attempt for dedupe.
  """
  @type record_opts :: [
          workspace_id: String.t(),
          route_session_id: String.t()
        ]

  # --- Client API --------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record_success(String.t(), record_opts()) :: {:ok, transition_info()}
  def record_success(provider_id, opts \\ []) when is_binary(provider_id) do
    now = DateTime.utc_now()
    current = get(provider_id)

    state =
      %{
        current
        | success_count: current.success_count + 1,
          last_success_at: now
      }
      |> compute_status()

    :ets.insert(@table, {provider_id, state})

    transition_result(provider_id, current.status, state, opts, now)
  end

  @spec record_failure(String.t(), term(), record_opts()) :: {:ok, transition_info()}
  def record_failure(provider_id, reason, opts \\ []) when is_binary(provider_id) do
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

    transition_result(provider_id, current.status, state, opts, now)
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

  @doc """
  Clear node-local provider health state.

  This is intentionally operational/test plumbing only; provider
  health is volatile by design, so resetting the ETS table does not
  affect any durable audit trail.
  """
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _table -> :ets.delete_all_objects(@table)
    end

    :ok
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

  defp transition_result(provider_id, from_state, state, opts, now) do
    workspace_id = Keyword.get(opts, :workspace_id)
    route_session_id = Keyword.get(opts, :route_session_id)

    event =
      if notify_relevant?(from_state, state.status) and is_binary(workspace_id) and
           is_binary(route_session_id) do
        persist_event(%{
          workspace_id: workspace_id,
          provider: provider_id,
          from_state: from_state,
          to_state: state.status,
          route_session_id: route_session_id,
          evidence: build_evidence(state),
          observed_at: now
        })
      end

    {:ok,
     %{
       from_state: from_state,
       to_state: state.status,
       state: state,
       event: event
     }}
  end

  # The notification surface is intentionally narrower than the
  # full transition matrix. A `:unknown → :healthy` flip on the
  # very first observation is not operationally interesting; an
  # `:healthy → :degraded` slip is silenced today (the operator
  # action lives at `:failing`). Adjusting these is a follow-up.
  defp notify_relevant?(:degraded, :failing), do: true
  defp notify_relevant?(:failing, :degraded), do: true
  defp notify_relevant?(:failing, :healthy), do: true
  defp notify_relevant?(_, _), do: false

  # Evidence is composed from controlled counters only — never
  # the raw `last_failure_reason` (operator/adapter free-text)
  # nor any provider-supplied URL. The `notifications` schema's
  # `:unsafe_text` gate would reject a leak in title/body, but
  # this column is queryable by future surfaces, so we simply
  # don't write the unsafe shape into the JSONB at all.
  defp build_evidence(state) do
    %{
      "success_count" => state.success_count,
      "failure_count" => state.failure_count,
      "rate_limited_count" => state.rate_limited_count,
      "no_route_count" => state.no_route_count
    }
  end

  defp persist_event(attrs) do
    case %ProviderHealthEvent{}
         |> ProviderHealthEvent.changeset(attrs)
         |> Repo.insert() do
      {:ok, %ProviderHealthEvent{} = event} ->
        event

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning(
          "Bank.Stablecoins.ProviderHealth: provider_health_event insert failed " <>
            "(provider=#{attrs.provider} workspace=#{attrs.workspace_id} errors=#{inspect(changeset.errors)})"
        )

        nil
    end
  rescue
    e ->
      Logger.warning(
        "Bank.Stablecoins.ProviderHealth: provider_health_event insert crashed: " <>
          Exception.message(e)
      )

      nil
  end

  defp provider_id_for(mod) when is_atom(mod) do
    if function_exported?(mod, :provider_id, 0) do
      mod.provider_id()
    else
      mod |> Module.split() |> List.last() |> String.downcase()
    end
  end
end
