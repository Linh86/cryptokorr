defmodule Bank.RateLimit do
  @moduledoc """
  Per-key fixed-window rate limit for `/v1` (#221, first slice).

  Two ETS tables, owned by this GenServer:

    * `:bank_rate_limit_buckets` — `{ {api_key_id, window_start_unix},
      counter }`. Atomically incremented on each `check/3` via
      `:ets.update_counter/4` so multiple Phoenix processes can hit
      the same key without serialising through this GenServer on the
      hot path.
    * `:bank_rate_limit_audit_dedupe` — `{ {api_key_id,
      window_start_unix}, true }`. The plug calls `claim_audit/2` to
      ensure at most ONE `api_key.rate_limited` audit row is emitted
      per (key, window). A bursty bot hammering the limit cannot
      flood audit storage.

  Process-local state. Single-node v0.1 deployments only — multi-node
  rollout will need a distributed cache (Hammer / Cachex / Redis).
  Documented as a deferral here so the next slice has a clear starting
  point. Crash recovery is "buckets reset to zero" by design: a
  rate-limit GenServer crash is the same threat model as a deploy,
  and a counter that survives a deploy would itself need a separate
  observability story.

  ## Public API

      check(key_id, max_requests, window_seconds) ::
        :ok | {:error, :rate_limited, retry_after_seconds}

      claim_audit(key_id, window_start_unix) :: boolean

      reset() :: :ok    # tests only

  ## Window semantics

  Fixed-window: each minute (or whatever `window_seconds` is) the
  counter resets implicitly because the bucket key changes. Trade-off
  is a 2× burst at the boundary (e.g. 60 requests in second 59 + 60
  requests in second 60), which is acceptable for a v0.1 cap aimed
  at runaway-agent containment, not at fine-grained smoothing.

  ## Cleanup

  A periodic `:cleanup` message every 5 minutes evicts buckets whose
  `window_start` is older than two hours. Conservative ceiling that
  covers the largest window an operator would reasonably configure
  while keeping the table bounded under continuous use.
  """

  use GenServer

  @bucket_table :bank_rate_limit_buckets
  @audit_dedupe_table :bank_rate_limit_audit_dedupe
  @cleanup_interval_ms 5 * 60 * 1_000
  @bucket_retention_seconds 2 * 60 * 60

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Atomically increment the bucket for `(api_key_id, current_window)`
  and decide whether to admit the request.

  Returns:

    * `:ok` — request fits within the bucket; counter is now
      `<= max_requests`.
    * `{:error, :rate_limited, retry_after_seconds}` — bucket is
      full; the caller MUST refuse the request. `retry_after_seconds`
      is the number of seconds until the current window rolls over
      (always at least `1`).

  The increment runs through `:ets.update_counter/4` so concurrent
  callers contend at the row level, not the GenServer level — the
  GenServer is only on the cleanup path.
  """
  @spec check(String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited, pos_integer()}
  def check(api_key_id, max_requests, window_seconds)
      when is_binary(api_key_id) and is_integer(max_requests) and max_requests > 0 and
             is_integer(window_seconds) and window_seconds > 0 do
    now = System.system_time(:second)
    window_start = div(now, window_seconds) * window_seconds
    bucket = {api_key_id, window_start}

    new_count =
      :ets.update_counter(@bucket_table, bucket, 1, {bucket, 0})

    if new_count > max_requests do
      retry_after = max(window_start + window_seconds - now, 1)
      {:error, :rate_limited, retry_after}
    else
      :ok
    end
  end

  @doc """
  Claim the right to emit ONE `api_key.rate_limited` audit row for
  `(api_key_id, window_start_unix)`.

  Returns `true` if this caller is the first to claim — emit the
  event. Returns `false` if another caller already claimed — skip.
  """
  @spec claim_audit(String.t(), integer()) :: boolean()
  def claim_audit(api_key_id, window_start_unix)
      when is_binary(api_key_id) and is_integer(window_start_unix) do
    :ets.insert_new(@audit_dedupe_table, {{api_key_id, window_start_unix}, true})
  end

  @doc "Test helper — clears both tables. Do not call from production code."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@bucket_table)
    :ets.delete_all_objects(@audit_dedupe_table)
    :ok
  end

  # --- callbacks -----------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@bucket_table, [
      :public,
      :named_table,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    :ets.new(@audit_dedupe_table, [
      :public,
      :named_table,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = System.system_time(:second) - @bucket_retention_seconds

    # Match spec: {{:_, "$1"}, :_} where "$1" is window_start.
    :ets.select_delete(@bucket_table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])

    :ets.select_delete(@audit_dedupe_table, [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
