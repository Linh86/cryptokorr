defmodule Bank.Quotes.ProviderHealth do
  @moduledoc """
  Node-local health tracker for `Bank.Quotes` providers (#176).

  Mirrors `Bank.Stablecoins.ProviderHealth`'s shape and lifecycle: an
  ETS-backed GenServer that holds per-provider success/failure counts,
  last-success/last-failure timestamps, and a derived status enum
  (`:unknown` | `:healthy` | `:degraded` | `:failing`). Volatile by
  design — restarts reset to `:unknown` and the durable audit trail
  lives in `simulation_reports` / `audit_events`, not here.

  The runtime calls `Bank.Quotes.preview/2` from two places — the
  simulate controller and `Bank.Decisions.evaluate_intent/2` — and
  every call now updates this tracker through the existing
  `emit_preview_telemetry/2` hook. An operator hitting
  `/v1/health/deep` (or reading `Bank.Quotes.ProviderHealth.all/0`
  from a LiveView) sees:

    * which provider id is currently active (`"stub"`, `"tenderly"`,
      `"disabled"`, …),
    * its last-known success/failure timestamps,
    * a category-only failure reason (atom from the fixed
      `@result_tag_allowlist`).

  ## Secret hygiene

  `last_failure_reason` carries an atom from a fixed allowlist that
  tracks the same vocabulary `Bank.Quotes.preview/2` already maps
  results onto for telemetry. Free-form strings, raw `inspect/1`
  output, upstream response bodies, request URLs, Authorization
  headers, and PEM material are NEVER stored. Calls to
  `record_failure/2` with a reason outside the allowlist collapse
  to `:error` — operators see the broad bucket without leaking
  upstream data.

  ## Public surface

      record_success(provider_id)
      record_failure(provider_id, reason_atom)
      get(provider_id)
      all()
      reset()
  """

  use GenServer

  @table :bank_quotes_provider_health

  # Mirrors the result vocabulary `Bank.Quotes.preview/2`'s
  # `emit_preview_telemetry/2` already produces. Any reason outside
  # this allowlist is downgraded to `:error` before reaching the ETS
  # table so a future regression in a provider module cannot smuggle
  # raw data into the readiness payload.
  @result_tag_allowlist ~w(
    provider_unavailable
    provider_disabled
    not_yet_implemented
    stale
    simulation_failed
    unsupported
    provider_exception
    error
  )a

  @type status :: :unknown | :healthy | :degraded | :failing

  @type provider_state :: %{
          provider: String.t(),
          status: status(),
          success_count: non_neg_integer(),
          failure_count: non_neg_integer(),
          last_success_at: DateTime.t() | nil,
          last_failure_at: DateTime.t() | nil,
          last_failure_reason: atom() | nil
        }

  # --- Client API --------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the canonical allowlist of `last_failure_reason` atoms. Used
  by tests to pin the redaction surface.
  """
  @spec result_tag_allowlist() :: [atom()]
  def result_tag_allowlist, do: @result_tag_allowlist

  @spec record_success(String.t()) :: :ok
  def record_success(provider_id) when is_binary(provider_id) do
    if table_alive?() do
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
    end

    :ok
  end

  @spec record_failure(String.t(), atom()) :: :ok
  def record_failure(provider_id, reason) when is_binary(provider_id) do
    if table_alive?() do
      now = DateTime.utc_now()
      current = get(provider_id)
      sanitized = sanitize_reason(reason)

      state =
        %{
          current
          | failure_count: current.failure_count + 1,
            last_failure_at: now,
            last_failure_reason: sanitized
        }
        |> compute_status()

      :ets.insert(@table, {provider_id, state})
    end

    :ok
  end

  @spec get(String.t()) :: provider_state()
  def get(provider_id) when is_binary(provider_id) do
    if table_alive?() do
      case :ets.lookup(@table, provider_id) do
        [{^provider_id, state}] -> state
        [] -> new_state(provider_id)
      end
    else
      new_state(provider_id)
    end
  end

  @spec all() :: [provider_state()]
  def all do
    if table_alive?() do
      :ets.tab2list(@table) |> Enum.map(fn {_k, v} -> v end)
    else
      []
    end
  end

  @doc """
  Clear node-local provider health state. Operational/test plumbing
  only — provider health is volatile by design.
  """
  @spec reset() :: :ok
  def reset do
    if table_alive?() do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  # --- GenServer callbacks ------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # --- Internal -----------------------------------------------------------

  defp table_alive? do
    :ets.whereis(@table) != :undefined
  end

  defp new_state(provider_id) do
    %{
      provider: provider_id,
      status: :unknown,
      success_count: 0,
      failure_count: 0,
      last_success_at: nil,
      last_failure_at: nil,
      last_failure_reason: nil
    }
  end

  defp sanitize_reason(reason) when is_atom(reason) do
    if reason in @result_tag_allowlist, do: reason, else: :error
  end

  defp sanitize_reason(_), do: :error

  defp compute_status(state) do
    total = state.success_count + state.failure_count

    cond do
      total == 0 -> %{state | status: :unknown}
      state.failure_count == 0 -> %{state | status: :healthy}
      state.success_count / total >= 0.8 -> %{state | status: :degraded}
      true -> %{state | status: :failing}
    end
  end
end
