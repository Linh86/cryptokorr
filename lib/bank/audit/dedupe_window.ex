defmodule Bank.Audit.DedupeWindow do
  @moduledoc """
  Generic ETS-backed audit-emission dedupe (#222).

  Some audit events are spam-prone: a misconfigured client can
  trigger thousands of identical denial / rate-limit / similar
  events per minute. This module provides the same first-writer-
  wins primitive used by `Bank.RateLimit`'s internal dedupe but
  generalised — the dedupe key can be any term, so each call site
  can choose its own grouping (per-key, per-prefix-and-reason,
  per-tenant, etc.).

  ## Usage

      if Bank.Audit.DedupeWindow.claim({:denied, prefix, reason}, 60) do
        Bank.Audit.append_event(...)
      end

  Returns `true` for the FIRST caller in a given `(key, window)`
  slot; `false` for everyone else until the next window.

  ## Window semantics

  Fixed-window: `window_start = div(now_unix, window_seconds) *
  window_seconds`. The dedupe row keys by that bucket, so two
  callers in second 59 and second 60 of the same minute land in
  the SAME bucket — the second is deduped. A caller exactly at
  the next minute boundary gets a fresh slot.

  ## Cleanup

  A periodic `:cleanup` message every 5 minutes evicts entries
  whose `window_start` is older than two hours. The retention
  ceiling matches `Bank.RateLimit`'s and is generous enough to
  cover any window an operator would reasonably configure.

  ## Why not reuse Bank.RateLimit's table

  `Bank.RateLimit` owns a private dedupe table tied to the rate-
  limit plug's emission path. Reusing it for unrelated audit
  events would couple two bounded contexts. This module is a
  small, dedicated primitive future events can adopt without
  reaching into `Bank.RateLimit`.
  """

  use GenServer

  @table :bank_audit_dedupe_window
  @cleanup_interval_ms 5 * 60 * 1_000
  @retention_seconds 2 * 60 * 60

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Claim the right to emit an audit event for the (`key`, current
  window) slot.

  Returns `true` if this caller is the first claim in the window
  — emit the event. Returns `false` if another caller already
  claimed — skip emission.

  `key` can be any term. Recommended grouping for multi-dimensional
  events: a tuple like `{:denied, prefix_or_id, reason}` so the
  same prefix+reason pair collapses to one event per window while
  different reasons emit independently.
  """
  @spec claim(term(), pos_integer()) :: boolean()
  def claim(key, window_seconds) when is_integer(window_seconds) and window_seconds > 0 do
    now = System.system_time(:second)
    window_start = div(now, window_seconds) * window_seconds
    :ets.insert_new(@table, {{key, window_start}, true})
  end

  @doc "Test helper — clears the dedupe table. Do not call from production code."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  # --- callbacks -----------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [
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
    cutoff = System.system_time(:second) - @retention_seconds

    :ets.select_delete(@table, [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
