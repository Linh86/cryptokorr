defmodule Bank.Ops.AdapterHealthSnapshot do
  @moduledoc """
  Cheap, non-blocking cache of the most-recent
  `Bank.Ops.Health.adapter/0` probe result.

  ## Why this exists

  `Bank.Ops.Health.adapter/0` issues a synchronous HTTP request to
  the adapter's `/healthz` endpoint with a 2-second timeout. That is
  fine for the deep-readiness controller (`/v1/health/deep`) and the
  periodic telemetry poller, but it is unsafe to call from a
  LiveView mount or socket handler — a slow adapter will block the
  socket process, hold an Erlang scheduler, and starve other
  subscribers.

  This module owns a small ETS table that always carries the latest
  sanitized probe result. UI / LiveView callers hit `snapshot/0`,
  which is a single `:ets.lookup` and returns immediately without
  ever contacting the adapter. The refresh path
  (`Bank.Runtime.Workers.RefreshAdapterHealth`) does the blocking
  call out-of-band on the `:ops_scan` queue.

  ## Snapshot shape

      %{
        status: :ok | :degraded | :unknown,
        detail: nil | "ok" | "adapter_5xx" | "transport_error" | "not_configured" | "error",
        http_status: 200..599 | nil,
        checked_at: %DateTime{} | nil,
        source: :cache
      }

  `:unknown` is the bootstrap state — returned when no probe has
  landed yet. `:degraded` covers every non-OK probe outcome. Detail
  is a fixed atom-string enum, never the raw inspect of an
  exception or a URL — that prevents credentialed RPC URLs,
  authorization headers, or stack traces from leaking through the
  cache to operator UI surfaces.

  ## Failure containment

  A crashing health-check function does not crash the GenServer:
  `refresh/0` rescues exceptions and stores a degraded snapshot
  with `detail: "error"` plus a sanitized timestamp. A subsequent
  successful probe overwrites the snapshot.

  ## Test injection

  `start_link(health_fn: fun)` and `refresh(health_fn: fun)` accept
  a 0-arity function with the same return shape as
  `Bank.Ops.Health.adapter/0` (`%{status: :ok | :error, detail: ...}`).
  Tests use this to drive the OK / 5xx / transport / raise branches
  without hitting the network.
  """

  use GenServer

  require Logger

  @table :bank_adapter_health_snapshot
  @row_key :latest

  @typedoc "The detail enum carried by the snapshot. Fixed allowlist."
  @type detail :: nil | String.t()

  @type t :: %{
          status: :ok | :degraded | :unknown,
          detail: detail(),
          http_status: 200..599 | nil,
          checked_at: DateTime.t() | nil,
          source: :cache
        }

  # --- Client API --------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Read the latest cached snapshot. Never blocks; returns the
  bootstrap `:unknown` snapshot when no refresh has landed yet (or
  when the cache process / table is not running, e.g. in unit
  tests that don't start the supervision tree).
  """
  @spec snapshot() :: t()
  def snapshot do
    case ets_lookup() do
      {:ok, snap} -> snap
      :unavailable -> unknown_snapshot()
    end
  end

  @doc """
  Run a fresh adapter health probe through `health_fn` (default
  `&Bank.Ops.Health.adapter/0`), sanitize the result, store it in
  ETS, and return the new snapshot.

  Failures inside the probe (raised exceptions, exits) collapse to
  a degraded snapshot with `detail: "error"`. Network/HTTP failures
  classified by `Health.adapter/0` itself land as
  `"transport_error"` / `"adapter_5xx"`.

  Called from the periodic Oban worker
  `Bank.Runtime.Workers.RefreshAdapterHealth`. UI callers MUST NOT
  call this directly — use `snapshot/0`.
  """
  @spec refresh(keyword()) :: t()
  def refresh(opts \\ []) do
    health_fn = Keyword.get(opts, :health_fn, &Bank.Ops.Health.adapter/0)
    GenServer.call(__MODULE__, {:refresh, health_fn})
  catch
    :exit, {:noproc, _} ->
      # Cache process not running (test paths, very-early boot).
      # Run the sanitization inline so callers still get a value
      # back, but do not attempt to populate ETS — there is no
      # owner.
      sanitize_safe(opts |> Keyword.get(:health_fn, &Bank.Ops.Health.adapter/0)).()

    :exit, {:timeout, _} ->
      degraded_snapshot("error", DateTime.utc_now())
  end

  @doc """
  Reset the cached snapshot to the bootstrap `:unknown` state.
  Used by tests; not a runtime tool.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- GenServer ---------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: false
      ])

    write(unknown_snapshot())
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:refresh, health_fn}, _from, state) do
    snap = sanitize_safe(health_fn).()
    write(snap)
    {:reply, snap, state}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    write(unknown_snapshot())
    {:reply, :ok, state}
  end

  # --- Sanitization ------------------------------------------------------

  # Returns a 0-arity function that calls `health_fn`, captures the
  # result (or rescues any raise/exit), and produces a sanitized
  # snapshot. The capture-then-classify split lets `refresh/1`'s
  # `:noproc` fallback re-use the same pipeline without a running
  # cache.
  defp sanitize_safe(health_fn) when is_function(health_fn, 0) do
    fn ->
      now = DateTime.utc_now()

      try do
        sanitize(health_fn.(), now)
      rescue
        e ->
          # The exception's `message/0` is operator-controlled (it
          # comes from whatever the underlying probe raised — Req's
          # transport-error message can carry the full request URL,
          # including any token in the userinfo or query string).
          # Log only the exception MODULE; never the message,
          # `inspect(reason)`, the URL, or a stack frame. Operators
          # who need the raw error can rerun the probe directly via
          # `Bank.Ops.Health.adapter/0` from IEx, where the result
          # is not persisted to logs.
          log_probe_failure(:rescue, e.__struct__)
          degraded_snapshot("error", now)
      catch
        :exit, _ ->
          log_probe_failure(:exit, :exit)
          degraded_snapshot("error", now)

        kind, _ when kind in [:throw, :error] ->
          log_probe_failure(kind, kind)
          degraded_snapshot("error", now)
      end
    end
  end

  # Fixed log shape — module + reason kind only, no message/URL/value
  # ever interpolated. `kind_module` is either an atom (`:exit`,
  # `:throw`, `:error`) or an exception module (e.g. `RuntimeError`).
  # Inspecting an atom or module name is safe: there is no caller-
  # controlled data path.
  defp log_probe_failure(kind, kind_module) do
    Logger.warning(
      "AdapterHealthSnapshot: probe raised; storing degraded snapshot " <>
        "(kind=#{kind} module=#{inspect(kind_module)})"
    )
  end

  # OK with an HTTP status (Health.adapter/0 returns "http <n>" on
  # success). Extract the integer; refuse to leak the raw detail
  # string in case a future change widens it.
  defp sanitize(%{status: :ok, detail: detail}, now) do
    %{
      status: :ok,
      detail: "ok",
      http_status: parse_http_status(detail),
      checked_at: now,
      source: :cache
    }
  end

  # Error branches: classify but do not propagate the raw detail
  # string. `Health.adapter/0` builds it from `inspect(reason)`,
  # which can include URLs or stack-frame fragments — neither is
  # safe to render in operator UI surfaces.
  defp sanitize(%{status: :error, detail: detail}, now) do
    {kind, http_status} = classify_error_detail(detail)

    %{
      status: :degraded,
      detail: kind,
      http_status: http_status,
      checked_at: now,
      source: :cache
    }
  end

  defp sanitize(_other, now) do
    # Unrecognised shape — treat as a degraded/unknown probe.
    degraded_snapshot("error", now)
  end

  # `Health.adapter/0` builds detail strings via:
  #   "http #{status}"               (success)
  #   "adapter 5xx: #{status}"       (5xx)
  #   "adapter base_url not configured"
  #   inspect(reason)                (transport / unknown)
  defp classify_error_detail(detail) when is_binary(detail) do
    cond do
      String.starts_with?(detail, "adapter 5xx") ->
        {"adapter_5xx", parse_http_status(detail)}

      detail == "adapter base_url not configured" ->
        {"not_configured", nil}

      true ->
        {"transport_error", nil}
    end
  end

  defp classify_error_detail(_), do: {"transport_error", nil}

  # Parses any trailing 3-digit integer from a detail string. Bounds-
  # checked to the HTTP range; anything outside collapses to nil.
  defp parse_http_status(detail) when is_binary(detail) do
    case Regex.run(~r/(\d{3})\b/, detail) do
      [_, code] ->
        {n, _} = Integer.parse(code)
        if n in 100..599, do: n, else: nil

      _ ->
        nil
    end
  end

  defp parse_http_status(_), do: nil

  defp ets_lookup do
    case :ets.whereis(@table) do
      :undefined ->
        :unavailable

      _tid ->
        case :ets.lookup(@table, @row_key) do
          [{@row_key, snap}] -> {:ok, snap}
          [] -> :unavailable
        end
    end
  rescue
    ArgumentError -> :unavailable
  end

  defp write(snap) do
    :ets.insert(@table, {@row_key, snap})
  end

  defp unknown_snapshot do
    %{
      status: :unknown,
      detail: nil,
      http_status: nil,
      checked_at: nil,
      source: :cache
    }
  end

  defp degraded_snapshot(detail, now) do
    %{
      status: :degraded,
      detail: detail,
      http_status: nil,
      checked_at: now,
      source: :cache
    }
  end
end
