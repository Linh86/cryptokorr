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

  alias Bank.Decisions.ExecutionPlan
  alias Bank.Repo

  @stuck_plan_threshold_minutes 15
  @adapter_health_path "/healthz"
  @adapter_health_timeout_ms 2_000

  @non_terminal [:prepared, :signing, :broadcasting, :pending_confirmation]

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
end
