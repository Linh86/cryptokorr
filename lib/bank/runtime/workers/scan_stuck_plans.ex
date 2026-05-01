defmodule Bank.Runtime.Workers.ScanStuckPlans do
  @moduledoc """
  Periodic stuck-plan detector (#230-b).

  Runs on the Oban cron every 2 minutes (configured in
  `config/config.exs`). Each tick calls
  `Bank.Ops.Health.stuck_plan_details/1` to enumerate execution
  plans currently past their per-status threshold and emits one
  `ops.stuck_plan_detected` audit row per plan, deduped on a
  5-minute aligned window (see
  `Bank.Ops.Health.detection_window_start/1`).

  ## Detection only — no automatic abort

  This worker is observational. It NEVER calls `abort_plan/3`,
  the chain adapter, or the LiveView UI. The downstream effect
  is exclusively the audit row + telemetry signal — operators
  decide whether to abort, retry, or wait based on the
  notification + the runbook.

  ## Idempotency

  Two layers protect against duplicate audit rows:

    1. **Aligned dedupe window** — `window_start` is floored to
       a #{300}-second bucket, so two ticks inside the same
       bucket hash the same key.
    2. **Per-plan DB pre-check** —
       `Bank.Ops.Health.stuck_plan_event_exists?/2` before each
       `Audit.append_event/1` call.

  An override `args["window_start"]` is supported for tests
  (forces a deterministic window).

  ## Telemetry

  Per tick the worker emits `[:bank, :ops, :stuck_plan,
  :scan_completed]` with measurements
  `%{scanned: integer, emitted: integer, skipped: integer}`.
  Per emitted row a separate
  `[:bank, :ops, :stuck_plan, :detected]` event with
  `%{count: 1}` and metadata `%{status: status_atom}` so a
  metric backend can sum across the cluster.

  ## Failure semantics

  Per-plan failures log a warning and continue; the worker's
  return value summarises the run. Default Oban retry kicks in
  on transient DB errors.
  """

  use Oban.Worker,
    queue: :ops_scan,
    max_attempts: 3,
    unique: [period: {90, :seconds}, fields: [:worker, :args]]

  require Logger

  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Ops.Health

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # `now` and `window_start` are independent on purpose:
    #   * `now` is the real wall clock the threshold check evaluates
    #     against, so a plan stuck at `12:33:30` with a 10-min
    #     threshold is detected at `12:34` (cutoff `12:24`) and is
    #     not delayed until the next bucket boundary.
    #   * `window_start` is the 5-min aligned bucket used purely as
    #     the audit-row dedupe key — same value across two ticks in
    #     the same bucket so a re-fire does not double-emit.
    # Tests can override either with the corresponding "now" /
    # "window_start" args (ISO 8601).
    now = resolve_now(args)
    window_start = resolve_window_start(args, now)
    window_start_iso = DateTime.to_iso8601(window_start)

    details = Health.stuck_plan_details(now: now)

    {emitted, skipped, errors} =
      Enum.reduce(details, {0, 0, 0}, fn detail, {emitted, skipped, errors} ->
        cond do
          Health.stuck_plan_event_exists?(detail.id, window_start_iso) ->
            {emitted, skipped + 1, errors}

          true ->
            attrs = Events.ops_stuck_plan_detected(detail, window_start: window_start)

            case Audit.append_event(attrs) do
              {:ok, _event} ->
                :telemetry.execute(
                  [:bank, :ops, :stuck_plan, :detected],
                  %{count: 1},
                  %{status: detail.execution_status}
                )

                {emitted + 1, skipped, errors}

              {:error, reason} ->
                Logger.warning(
                  "ScanStuckPlans: failed to emit ops.stuck_plan_detected for plan=#{detail.id}: " <>
                    inspect(reason)
                )

                {emitted, skipped, errors + 1}
            end
        end
      end)

    :telemetry.execute(
      [:bank, :ops, :stuck_plan, :scan_completed],
      %{scanned: length(details), emitted: emitted, skipped: skipped, errors: errors},
      %{}
    )

    Logger.debug(fn ->
      "ScanStuckPlans: window=#{window_start_iso} " <>
        "scanned=#{length(details)} emitted=#{emitted} skipped=#{skipped} errors=#{errors}"
    end)

    :ok
  end

  defp resolve_now(args) do
    case Map.get(args, "now") do
      iso when is_binary(iso) -> parse_iso!(iso, "now")
      _ -> DateTime.utc_now()
    end
  end

  defp resolve_window_start(args, now) do
    case Map.get(args, "window_start") do
      iso when is_binary(iso) -> parse_iso!(iso, "window_start")
      _ -> Health.detection_window_start(now)
    end
  end

  defp parse_iso!(iso, field) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        dt

      _ ->
        raise ArgumentError,
              "ScanStuckPlans: invalid #{field} (expected ISO 8601): " <> inspect(iso)
    end
  end
end
