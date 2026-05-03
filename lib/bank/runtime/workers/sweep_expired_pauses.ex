defmodule Bank.Runtime.Workers.SweepExpiredPauses do
  @moduledoc """
  Periodic auto-resume sweeper for scoped chain pauses with an
  `expires_at` set (#228 Phase 1.5).

  Runs on the Oban cron every minute (configured in
  `config/config.exs`). Each tick lists at most `@batch_limit`
  active pauses whose `expires_at <= now` and resumes each one
  through `Bank.Security.Pauses.expire/2`. The context layer
  re-locks the row inside a transaction, re-checks both invariants
  (still active and still expired), updates `resumed_at`, emits a
  `security.scope_expired` audit event with `actor: :runtime`,
  and broadcasts post-commit on `security:events` and
  `audit:stream`. The sweeper itself never writes to the DB
  directly; idempotency is owned by `Pauses.expire/2`.

  ## Detection-only worker, no chain effects

  This worker is a pure DB / context-layer auto-resume. It NEVER
  calls the chain adapter, the broadcast/signing path, or the
  TS adapter. The only side effects are the audit row and the
  PubSub fan-out — same surface as an operator-driven resume.

  ## Idempotency

  Two layers protect against duplicate audit rows or double-resume:

    1. **Lock-then-check inside `Pauses.expire/2`** — the active
       row is locked `FOR UPDATE`; if another sweeper run or an
       operator resume landed first, the function returns
       `{:ok, :already_resumed}` and emits no audit / no
       broadcast.
    2. **Anchored `resumed_at`** — set to the row's recorded
       `expires_at`, not the worker's wall clock, so a re-tick
       with a different `now` always agrees on the resumption
       instant.

  An override `args["now"]` (ISO 8601) is supported for tests so
  the matcher can drive the time-comparison branches deterministically
  without any `Process.sleep/1`.

  ## Telemetry

  Per tick the worker emits
  `[:bank, :security, :sweep_expired_pauses, :scan_completed]`
  with measurements `%{scanned: integer, expired: integer,
  already_resumed: integer, not_yet_expired: integer, errors:
  integer}` so a metric backend can sum across the cluster.
  Per-row `:scope_expired` telemetry is fired by
  `Bank.Security.Pauses` itself.

  ## Failure semantics

  Per-row failures log a warning and continue; the worker's
  return value summarises the run. Default Oban retry kicks in
  on transient DB errors.
  """

  use Oban.Worker,
    queue: :ops_scan,
    max_attempts: 3,
    unique: [period: {45, :seconds}, fields: [:worker, :args]]

  require Logger

  alias Bank.Security.Pauses

  @batch_limit 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now = resolve_now(args)
    expired_rows = Pauses.list_active_expired(now, limit: @batch_limit)

    {expired, already_resumed, not_yet_expired, errors} =
      Enum.reduce(expired_rows, {0, 0, 0, 0}, fn pause, acc ->
        {ok_expired, ok_already, ok_not_yet, errs} = acc

        case Pauses.expire(pause, now) do
          {:ok, :expired, _} ->
            {ok_expired + 1, ok_already, ok_not_yet, errs}

          {:ok, :already_resumed} ->
            {ok_expired, ok_already + 1, ok_not_yet, errs}

          {:ok, :not_yet_expired} ->
            {ok_expired, ok_already, ok_not_yet + 1, errs}

          {:error, reason} ->
            Logger.warning(
              "SweepExpiredPauses: failed to expire pause=#{pause.id}: #{inspect(reason)}"
            )

            {ok_expired, ok_already, ok_not_yet, errs + 1}
        end
      end)

    :telemetry.execute(
      [:bank, :security, :sweep_expired_pauses, :scan_completed],
      %{
        scanned: length(expired_rows),
        expired: expired,
        already_resumed: already_resumed,
        not_yet_expired: not_yet_expired,
        errors: errors
      },
      %{}
    )

    Logger.debug(fn ->
      "SweepExpiredPauses: scanned=#{length(expired_rows)} expired=#{expired} " <>
        "already_resumed=#{already_resumed} not_yet_expired=#{not_yet_expired} errors=#{errors}"
    end)

    :ok
  end

  defp resolve_now(args) do
    case Map.get(args, "now") do
      iso when is_binary(iso) -> parse_iso!(iso)
      _ -> DateTime.utc_now()
    end
  end

  defp parse_iso!(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        dt

      _ ->
        raise ArgumentError,
              "SweepExpiredPauses: invalid `now` (expected ISO 8601): " <> inspect(iso)
    end
  end
end
