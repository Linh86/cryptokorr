defmodule Bank.Runtime.Workers.ScanStuckPlans do
  @moduledoc """
  Periodic stuck-plan detector (#230-b).

  Runs on the Oban cron every 2 minutes (configured in
  `config/config.exs`). Each tick calls
  `Bank.Ops.Health.stuck_plan_details/1` to enumerate execution
  plans currently past their per-status threshold and emits:

    1. one `ops.stuck_plan_detected` audit row per plan, deduped
       on a 5-minute aligned window (see
       `Bank.Ops.Health.detection_window_start/1`),
    2. one `Bank.Ops.Alerts` operational alert
       (`kind: :stuck_plan`) per plan that has a `workspace_id`,
       deduped per `(workspace_id, plan_id, window_start)` via
       the alerts module's notification dedupe key (#256), and
    3. one `Bank.Ops.Alerts.resolve/1` recovery notification per
       plan that previously had an open `ops.stuck_plan` alert
       but is no longer stuck this tick (#256 acceptance: "clear
       resolved state or recovery note").

  ## Detection only — no automatic abort

  This worker is observational. It NEVER calls `abort_plan/3`,
  the chain adapter, or the LiveView UI. The downstream effect
  is exclusively the audit row + alert notification + telemetry
  signal — operators decide whether to abort, retry, or wait
  based on the notification + the runbook.

  ## Idempotency

  Two layers protect against duplicate audit rows:

    1. **Aligned dedupe window** — `window_start` is floored to
       a #{300}-second bucket, so two ticks inside the same
       bucket hash the same key.
    2. **Per-plan DB pre-check** —
       `Bank.Ops.Health.stuck_plan_event_exists?/2` before each
       `Audit.append_event/1` call.

  Alert-side dedupe is handled by `Bank.Ops.Alerts.emit/1`'s
  `(workspace_id, dedupe_key)` unique index — repeated emit calls
  in the same window collapse to one notification row. Recovery
  emits use the original alert's `window_start` so two ticks
  observing the same plan recover collapse to one
  `.resolved` notification per stuck event.

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
  on transient DB errors. An alert-emit failure is logged but
  does NOT prevent the audit row or other plans from being
  processed.
  """

  use Oban.Worker,
    queue: :ops_scan,
    max_attempts: 3,
    unique: [period: {90, :seconds}, fields: [:worker, :args]]

  import Ecto.Query

  require Logger

  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Notifications.Notification
  alias Bank.Ops.Alerts
  alias Bank.Ops.Health
  alias Bank.Repo

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

    emit_stuck_plan_alerts(details, window_start_iso)
    emit_stuck_plan_recoveries(details, window_start_iso)

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

  # Fire one operational alert per stuck plan with a workspace_id.
  # Plans whose `workspace_id` is `nil` (legacy unscoped rows) are
  # skipped — `Bank.Ops.Alerts` is workspace-scoped by contract.
  defp emit_stuck_plan_alerts(details, window_start_iso) do
    Enum.each(details, fn detail ->
      case detail.workspace_id do
        ws when is_binary(ws) ->
          attrs = %{
            workspace_id: ws,
            kind: :stuck_plan,
            subject: detail.id,
            subject_type: "execution_plan",
            subject_id: detail.id,
            severity: :warning,
            dedupe_window: window_start_iso,
            details: %{
              status: detail.execution_status,
              stuck_for_seconds: detail.stuck_for_seconds,
              threshold_seconds: detail.threshold_seconds
            }
          }

          case Alerts.emit(attrs) do
            {:ok, _outcome, _n} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "ScanStuckPlans: alert emit failed for plan=#{detail.id}: " <>
                  inspect(reason)
              )
          end

        _ ->
          :ok
      end
    end)
  end

  # For every non-archived `ops.stuck_plan` notification whose
  # `subject_id` (plan id) is NOT in the current stuck-set, emit a
  # paired `.resolved` notification keyed on the original alert's
  # `window_start` so two ticks observing the same recovery
  # collapse to one resolved row.
  defp emit_stuck_plan_recoveries(details, scan_window_iso) do
    current_ids = MapSet.new(details, & &1.id)

    open_alerts = list_open_stuck_plan_notifications()

    Enum.each(open_alerts, fn n ->
      plan_id = n.subject_id

      cond do
        is_nil(plan_id) ->
          :ok

        is_nil(n.workspace_id) ->
          :ok

        MapSet.member?(current_ids, plan_id) ->
          :ok

        true ->
          original_window =
            parse_window_from_dedupe_key(n.dedupe_key) || scan_window_iso

          attrs = %{
            workspace_id: n.workspace_id,
            kind: :stuck_plan,
            subject: plan_id,
            subject_type: "execution_plan",
            subject_id: plan_id,
            dedupe_window: original_window
          }

          case Alerts.resolve(attrs) do
            {:ok, _outcome, _n} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "ScanStuckPlans: alert resolve failed for plan=#{plan_id}: " <>
                  inspect(reason)
              )
          end
      end
    end)
  end

  defp list_open_stuck_plan_notifications do
    Repo.all(
      from(n in Notification,
        where: n.event_type == "ops.stuck_plan" and n.status != :archived
      )
    )
  end

  # Dedupe-key shape from `Bank.Ops.Alerts`: joined by ":". The
  # plan id is a UUID with no colons, so a 3-part split recovers
  # the trailing ISO 8601 window verbatim (which itself contains
  # colons but is the last segment).
  defp parse_window_from_dedupe_key(key) when is_binary(key) do
    case String.split(key, ":", parts: 3) do
      ["ops.stuck_plan", _plan_id, window_iso] when window_iso != "" -> window_iso
      _ -> nil
    end
  end

  defp parse_window_from_dedupe_key(_), do: nil

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
