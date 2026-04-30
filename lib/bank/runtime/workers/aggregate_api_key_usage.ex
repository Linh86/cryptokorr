defmodule Bank.Runtime.Workers.AggregateAPIKeyUsage do
  @moduledoc """
  Daily aggregate of API-key usage (#218d).

  `BankWeb.Plugs.VerifyAPIKey` rolls each key's `last_used_at`
  forward at most once per throttle window
  (`Bank.APIKeys.touch_last_used/2`). This worker reads that
  column once a day, finds keys touched within the prior 24-hour
  window, and emits one `api_key.used` audit event per such key.

  ## Why not per-request

  Per-request audit emission would be thousands of rows per
  workspace per day and the integrity pipeline (#161) is not a
  metrics surface. The audit row's purpose is to record "this
  credential was used in window W" so an operator can tell
  whether a key is still in active use before revoking it. Daily
  granularity is the right resolution for that question.

  ## Idempotency

  Three layers protect against duplicate audit rows:

  1. **Cron scheduling**: `Oban.Plugins.Cron` inserts at most one
     job per crontab firing (`30 0 * * *`).
  2. **Oban `unique:` constraint** on `(worker, args)` over the
     default `unique_states`
     (`available, scheduled, executing, retryable`) — prevents a
     second job for the same args while the first is still
     active.
  3. **Per-key DB pre-check** via `Bank.APIKeys.used_event_exists?/2`
     before each `Audit.append_event/1` call.

  ### Queue concurrency MUST stay at 1

  Layer 3 (the per-key pre-check) is NOT atomic at the SQL level —
  there is no unique constraint on
  `(audit_events.subject_id, after_ref->>window_start)` for
  `api_key.used`. If two workers ran the same window
  simultaneously, both could see "no existing event" and both
  insert. The `:api_key_usage` queue is configured with
  concurrency `1` in `config/config.exs` to serialize jobs and
  close that race. Bumping the queue concurrency without first
  adding a SQL-level unique constraint would silently regress
  idempotency.

  An explicit `args.window_start` / `args.window_end` override is
  supported for tests and for back-fill operator runs.

  ## Failure semantics

  The worker emits events one-per-key inside the loop. A
  per-key failure logs the error and continues; the per-day job
  reports the summary count. Oban's retry mechanism is left at
  default (3 attempts) so a transient DB outage gets one round
  of automatic retries.
  """

  use Oban.Worker,
    queue: :api_key_usage,
    max_attempts: 3,
    unique: [period: {1, :day}, fields: [:worker, :args]]

  require Logger

  alias Bank.APIKeys
  alias Bank.Audit
  alias Bank.Audit.Events

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    {window_start, window_end} = resolve_window(args)
    window_start_iso = DateTime.to_iso8601(window_start)

    keys = APIKeys.list_keys_used_between(window_start, window_end)

    {emitted, skipped, errors} =
      Enum.reduce(keys, {0, 0, 0}, fn key, {emitted, skipped, errors} ->
        cond do
          APIKeys.used_event_exists?(key.id, window_start_iso) ->
            {emitted, skipped + 1, errors}

          true ->
            attrs =
              Events.api_key_used(key, %{
                window_start: window_start,
                window_end: window_end,
                last_used_at: key.last_used_at
              })

            case Audit.append_event(attrs) do
              {:ok, _event} ->
                {emitted + 1, skipped, errors}

              {:error, reason} ->
                Logger.warning(
                  "AggregateAPIKeyUsage: failed to emit api_key.used for prefix=#{key.prefix}: " <>
                    inspect(reason)
                )

                {emitted, skipped, errors + 1}
            end
        end
      end)

    Logger.info(
      "AggregateAPIKeyUsage: window=#{window_start_iso}..#{DateTime.to_iso8601(window_end)} " <>
        "scanned=#{length(keys)} emitted=#{emitted} skipped=#{skipped} errors=#{errors}"
    )

    :ok
  end

  # --- helpers ----------------------------------------------------------

  # The window is `[yesterday-00:00 UTC, today-00:00 UTC)`. Tests
  # override via `args["window_start"]` / `args["window_end"]` (ISO
  # 8601 strings). Operator-driven backfills also use the args
  # override so the same worker can rebuild a missed day.
  defp resolve_window(args) do
    case {Map.get(args, "window_start"), Map.get(args, "window_end")} do
      {start_iso, end_iso} when is_binary(start_iso) and is_binary(end_iso) ->
        with {:ok, start_dt, _} <- DateTime.from_iso8601(start_iso),
             {:ok, end_dt, _} <- DateTime.from_iso8601(end_iso) do
          {start_dt, end_dt}
        else
          _ ->
            raise ArgumentError,
                  "AggregateAPIKeyUsage: invalid window args (expected ISO 8601): " <>
                    "start=#{inspect(start_iso)} end=#{inspect(end_iso)}"
        end

      _ ->
        default_yesterday_window()
    end
  end

  defp default_yesterday_window do
    today_midnight =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")

    yesterday_midnight = DateTime.add(today_midnight, -1, :day)

    {yesterday_midnight, today_midnight}
  end
end
