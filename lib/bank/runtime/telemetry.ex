defmodule Bank.Runtime.Telemetry do
  @moduledoc """
  Typed wrappers around `:telemetry.execute/3` for the four MVP event
  families wired into `BankWeb.Telemetry`:

    * `[:bank, :autonomy, :decision]` — one event per `Bank.Autonomy.route/2`
    * `[:bank, :quotes, :preview]`   — one event per `Bank.Quotes.preview/2`
    * `[:bank, :execution, :lifecycle]` — one event per execution-plan transition
    * `[:bank, :security, :event]`    — one event per pause/resume/revoke

  Callers go through this module so tag shapes stay consistent. The
  emit helpers are best-effort and never raise — telemetry is an
  observability signal, not a correctness path.
  """

  @doc "Record a decision emission."
  @spec decision(map()) :: :ok
  def decision(%{outcome: outcome, risk_tier: risk_tier, reason_code: reason_code}) do
    safe_emit(
      [:bank, :autonomy, :decision],
      %{count: 1},
      %{outcome: outcome, risk_tier: risk_tier, reason_code: reason_code}
    )
  end

  def decision(_), do: :ok

  @doc "Record a quote/simulation outcome."
  @spec preview(atom(), atom()) :: :ok
  def preview(provider, result) when is_atom(result) do
    safe_emit(
      [:bank, :quotes, :preview],
      %{count: 1},
      %{provider: provider, result: result}
    )
  end

  @doc "Record an execution-plan transition."
  @spec execution(atom()) :: :ok
  def execution(status) when is_atom(status) do
    safe_emit([:bank, :execution, :lifecycle], %{count: 1}, %{status: status})
  end

  @doc "Record a security event."
  @spec security(atom(), atom()) :: :ok
  def security(event, scope) when is_atom(event) and is_atom(scope) do
    safe_emit([:bank, :security, :event], %{count: 1}, %{event: event, scope: scope})
  end

  @doc "Record a stablecoin route evaluation."
  @spec stablecoin_route(map()) :: :ok
  def stablecoin_route(%{decision: decision, route_kind: route_kind, provider: provider} = meta) do
    safe_emit(
      [:bank, :stablecoins, :route],
      %{count: 1, score: meta[:score] || 0.0},
      %{decision: decision, route_kind: route_kind, provider: provider}
    )
  end

  def stablecoin_route(_), do: :ok

  @typedoc """
  Adapter dispatch outcome enum (#255). Fixed allowlist so
  observability backends can group on a stable label instead of
  raw provider error strings.

    * `:accepted` — adapter returned 2xx with the expected shape.
    * `:invalid_response` — adapter returned 2xx with an
      unexpected body. Treat as a contract bug.
    * `:rejected` — 4xx, deterministic.
    * `:error` — 5xx. Retryable.
    * `:unavailable` — transport / DNS / timeout. Retryable.
  """
  @type adapter_outcome :: :accepted | :invalid_response | :rejected | :error | :unavailable

  @doc """
  Record an adapter-dispatch lifecycle event (#255).

  `path` is the adapter sub-path under `{base_url}` (e.g.
  `"/dispatch/transfer"`). `outcome` is one of the fixed
  `t:adapter_outcome/0` values. Optional `meta` carries safe
  correlation metadata only — the caller is responsible for not
  passing operator-controlled or secret-bearing values. The
  helper hard-allowlists the metadata keys it propagates so a
  future caller cannot accidentally widen the surface.

  ## Allowlisted meta keys

    * `:status`             — HTTP status integer when known.
    * `:execution_plan_id`  — UUID, lets operators follow one plan.
    * `:intent_id`          — UUID, lets operators follow one intent
      across decision/dispatch/callback events.
    * `:smart_account_id`   — string identifier from grant/revoke
      paths.
    * `:duration_ms`        — request latency for SLI panels.

  All other keys are silently dropped to keep the metadata shape
  stable across call sites.
  """
  @spec adapter_dispatch(String.t(), adapter_outcome(), map()) :: :ok
  def adapter_dispatch(path, outcome, meta \\ %{})
      when is_binary(path) and is_atom(outcome) and is_map(meta) do
    safe_emit(
      [:bank, :adapter, :dispatch],
      %{count: 1},
      Map.merge(
        %{path: path, outcome: outcome},
        Map.take(meta, [
          :status,
          :execution_plan_id,
          :intent_id,
          :smart_account_id,
          :duration_ms
        ])
      )
    )
  end

  defp safe_emit(event, measurements, metadata) do
    try do
      :telemetry.execute(event, measurements, metadata)
      :ok
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end
