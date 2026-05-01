defmodule Bank.Ops.Health do
  @moduledoc """
  Operational health signals the deep readiness probe and the periodic
  telemetry poller both consume.

  Intentionally cheap to call — every function here either runs a
  bounded DB query or a small HTTP `HEAD`/`GET /healthz` against the
  adapter. Nothing here should block for longer than a few seconds.

  ## Checks

    * `database/0` — Postgres connectivity.
    * `adapter/0` — adapter reachability. Soft fail: if the adapter
      declines to expose a health endpoint, we still consider it "ok"
      as long as TCP succeeded.
    * `stuck_plans/1` — execution plans still in non-terminal status
      past the configurable threshold.
    * `callback_failures/1` — count of warning-level callback errors
      in the last N minutes (best-effort via a counter).

  The intent is that a human on call can `curl /v1/health/deep` and
  see a single JSON that answers every "is something obviously wrong"
  question at once.
  """

  require Logger

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Repo

  @stuck_plan_threshold_minutes 15
  @adapter_health_path "/healthz"
  @adapter_health_timeout_ms 2_000

  @non_terminal [:prepared, :signing, :broadcasting, :pending_confirmation]

  # Per-status thresholds for `stuck_plan_details/1` and the
  # `ScanStuckPlans` worker (#230-b). Defaults chosen against the
  # observed adapter SLA: `:prepared` should leave the worker queue
  # within seconds; `:pending_confirmation` is bundler-bound and
  # legitimately waits 30+ seconds even on a healthy mainnet. The
  # values are tunable per-environment via
  # `config :bank, Bank.Ops.Health, stuck_plan_thresholds: [...]`.
  @default_stuck_plan_thresholds %{
    prepared: 600,
    signing: 300,
    broadcasting: 600,
    pending_confirmation: 1_800
  }

  # Detection writes one `ops.stuck_plan_detected` audit row per
  # plan per *aligned* window. With a 2-minute cron tick we widen
  # the dedupe bucket to 5 minutes so a single legitimately-stuck
  # plan generates one alert every 5 min, not every tick.
  @detection_window_seconds 300

  @scan_batch_default 50

  @doc """
  Runs every check and returns a map suitable for JSON rendering.

  The top-level `:status` is `:ok` if every check is `:ok`, otherwise
  `:degraded`.
  """
  @spec snapshot(keyword()) :: %{status: :ok | :degraded, checks: map()}
  def snapshot(opts \\ []) do
    checks = %{
      database: database(),
      adapter: adapter(),
      stuck_plans: stuck_plans(opts)
    }

    status =
      if Enum.all?(checks, fn {_, v} -> v.status == :ok end), do: :ok, else: :degraded

    %{status: status, checks: checks}
  end

  @doc "Ping Postgres with a `SELECT 1`."
  @spec database() :: %{status: :ok | :error, detail: String.t() | nil}
  def database do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> %{status: :ok, detail: nil}
      {:error, reason} -> %{status: :error, detail: inspect(reason)}
    end
  rescue
    e -> %{status: :error, detail: Exception.message(e)}
  end

  @doc """
  Ping the adapter's health endpoint.

  The adapter isn't required to implement `/healthz` — if it returns
  404 we still count it as reachable (we got an HTTP response). Only
  transport errors or 5xx degrade the status.
  """
  @spec adapter() :: %{status: :ok | :error, detail: String.t() | nil}
  def adapter do
    config = Application.get_env(:bank, Bank.AdapterClient, [])
    base_url = Keyword.get(config, :base_url)
    extra = Keyword.get(config, :req_options, [])

    if is_nil(base_url) do
      %{status: :error, detail: "adapter base_url not configured"}
    else
      req_opts =
        [
          base_url: base_url,
          url: @adapter_health_path,
          method: :get,
          receive_timeout: @adapter_health_timeout_ms,
          retry: false
        ]
        |> Keyword.merge(extra)

      case Req.request(req_opts) do
        {:ok, %Req.Response{status: status}} when status < 500 ->
          %{status: :ok, detail: "http #{status}"}

        {:ok, %Req.Response{status: status}} ->
          %{status: :error, detail: "adapter 5xx: #{status}"}

        {:error, reason} ->
          %{status: :error, detail: inspect(reason)}
      end
    end
  end

  @doc """
  Count execution plans stuck in a non-terminal status past the
  threshold. A plan is "stuck" if its `execution_status` is in
  `#{inspect(@non_terminal)}` and it hasn't moved in `threshold_minutes`.
  """
  @spec stuck_plans(keyword()) :: %{
          status: :ok | :error,
          count: non_neg_integer(),
          threshold_minutes: pos_integer()
        }
  def stuck_plans(opts \\ []) do
    threshold = Keyword.get(opts, :threshold_minutes, @stuck_plan_threshold_minutes)
    cutoff = DateTime.utc_now() |> DateTime.add(-threshold * 60, :second)

    count =
      Repo.aggregate(
        from(p in ExecutionPlan,
          where: p.execution_status in ^@non_terminal and p.updated_at < ^cutoff
        ),
        :count,
        :id
      )

    status = if count == 0, do: :ok, else: :error
    %{status: status, count: count, threshold_minutes: threshold}
  end

  @doc """
  Emit a telemetry event per check. Wired into the
  `:telemetry_poller` so the metrics module picks up gauge values
  without each caller knowing about them.

  Event: `[:bank, :ops, :health]` with measurement
  `%{stuck_plans: count, adapter_up: 1|0, database_up: 1|0}`.
  """
  @spec emit_telemetry() :: :ok
  def emit_telemetry do
    db = database()
    adapter = adapter()
    stuck = stuck_plans()

    :telemetry.execute(
      [:bank, :ops, :health],
      %{
        stuck_plans: stuck.count,
        adapter_up: bool_to_int(adapter.status == :ok),
        database_up: bool_to_int(db.status == :ok)
      },
      %{}
    )

    :ok
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  # --- Stuck-plan detection (#230-b) ---------------------------------------

  @doc """
  Per-plan stuck detail rows for the `ScanStuckPlans` worker (#230-b).

  Unlike `stuck_plans/1` (which returns a single aggregate count
  for `/v1/health/deep`), this returns one row per stuck plan
  with the per-status threshold the row breached.

  ## opts

    * `:thresholds` — overrides the per-status threshold map.
      Default comes from
      `Application.get_env(:bank, Bank.Ops.Health, [])[:stuck_plan_thresholds]`,
      falling back to `#{inspect(@default_stuck_plan_thresholds)}`.
    * `:limit` — caps the result set; default
      `#{@scan_batch_default}` so a degraded run does not flood
      the audit pipeline.
    * `:now` — clock override for tests.
  """
  @spec stuck_plan_details(keyword()) :: [
          %{
            id: String.t(),
            workspace_id: String.t() | nil,
            execution_status: atom(),
            updated_at: DateTime.t(),
            stuck_for_seconds: non_neg_integer(),
            threshold_seconds: pos_integer()
          }
        ]
  def stuck_plan_details(opts \\ []) do
    thresholds = resolve_thresholds(opts)
    limit = Keyword.get(opts, :limit, @scan_batch_default)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    # Run one query per status so the per-status cutoff is applied
    # at the DB level. The status set is small (4 entries) so the
    # constant fan-out is cheap; alternatives that pack thresholds
    # into a single query require a CASE/WHEN ladder over the enum.
    rows =
      thresholds
      |> Enum.flat_map(fn {status, threshold_seconds} ->
        cutoff = DateTime.add(now, -threshold_seconds, :second)

        # Deterministic ordering: oldest stuck rows first, with id as
        # tiebreaker so two rows with identical `updated_at` cannot
        # be silently dropped by `LIMIT` based on Postgres row order.
        # The per-status `LIMIT ^limit` runs after the `ORDER BY` so
        # the cap selects the worst-stuck rows of that status, not an
        # arbitrary slice. The outer `Enum.take(limit)` (post-merge
        # across all statuses) preserves the same ordering.
        from(p in ExecutionPlan,
          where:
            p.execution_status == ^status and
              p.updated_at < ^cutoff and
              p.active == true,
          select: %{
            id: p.id,
            workspace_id: p.workspace_id,
            execution_status: p.execution_status,
            updated_at: p.updated_at
          },
          order_by: [asc: p.updated_at, asc: p.id],
          limit: ^limit
        )
        |> Repo.all()
        |> Enum.map(fn row ->
          stuck_for = DateTime.diff(now, row.updated_at, :second)

          row
          |> Map.put(:threshold_seconds, threshold_seconds)
          |> Map.put(:stuck_for_seconds, stuck_for)
        end)
      end)

    rows
    |> Enum.sort_by(&{&1.updated_at, &1.id}, fn
      {a_ts, a_id}, {b_ts, b_id} ->
        case DateTime.compare(a_ts, b_ts) do
          :lt -> true
          :gt -> false
          :eq -> a_id <= b_id
        end
    end)
    |> Enum.take(limit)
  end

  @doc """
  Tick-aligned dedupe key for `ops.stuck_plan_detected` audit
  emission. Two ticks within the same `#{@detection_window_seconds}`-second
  bucket produce the same window-start, so a per-plan
  `(plan.id, window_start_iso)` lookup short-circuits the second
  emission.
  """
  @spec detection_window_start(DateTime.t()) :: DateTime.t()
  def detection_window_start(now \\ DateTime.utc_now()) do
    epoch = DateTime.to_unix(now, :second)
    aligned = div(epoch, @detection_window_seconds) * @detection_window_seconds
    DateTime.from_unix!(aligned, :second)
  end

  @doc """
  True iff an `ops.stuck_plan_detected` audit row already exists
  for the given plan id within the same detection window.
  Mirrors `Bank.APIKeys.used_event_exists?/2`.
  """
  @spec stuck_plan_event_exists?(String.t(), String.t()) :: boolean()
  def stuck_plan_event_exists?(plan_id, window_start_iso)
      when is_binary(plan_id) and is_binary(window_start_iso) do
    Repo.exists?(
      from e in AuditEvent,
        where:
          e.event_type == "ops.stuck_plan_detected" and
            e.subject_type == "execution_plan" and
            e.subject_id == ^plan_id and
            fragment("?->>'window_start' = ?", e.after_ref, ^window_start_iso)
    )
  end

  defp resolve_thresholds(opts) do
    case Keyword.get(opts, :thresholds) do
      nil ->
        configured =
          :bank
          |> Application.get_env(Bank.Ops.Health, [])
          |> Keyword.get(:stuck_plan_thresholds)

        case configured do
          nil -> @default_stuck_plan_thresholds
          kw when is_list(kw) -> Map.new(kw)
          %{} = map -> map
        end

      kw when is_list(kw) ->
        Map.new(kw)

      %{} = map ->
        map
    end
  end
end
