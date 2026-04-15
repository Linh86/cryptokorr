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
