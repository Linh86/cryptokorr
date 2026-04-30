defmodule BankWeb.HealthController do
  @moduledoc """
  Health and readiness probes.

  * `GET /health`     — unauthenticated liveness probe. Returns 200 as
    long as the web endpoint is up. Does not touch the database.
  * `GET /v1/health`  — operator-facing readiness probe. Confirms the
    database connection is reachable so an orchestrator can distinguish
    a running web process from one that cannot serve traffic.

  The boundary matters: `/health` is safe to expose to a load balancer
  without leaking state about dependencies. `/v1/health` is readiness:
  it is still cheap, but a failure is a signal to hold traffic.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  @app_version Mix.Project.config()[:version]

  # `/health` (liveness) is intentionally excluded from the external
  # OpenAPI spec — it is a load-balancer-only probe outside the
  # `/v1` surface. Declare `false` so ControllerSpecs does not warn.
  operation(:liveness, false)

  @doc "Liveness probe — no external dependencies."
  def liveness(conn, _params) do
    json(conn, %{status: "ok", service: "bank", version: @app_version})
  end

  operation(:readiness,
    summary: "Readiness probe",
    description: """
    Confirms the Postgres connection is reachable so an orchestrator
    can distinguish a running web process from one that cannot serve
    traffic. Returns `200` with `status: "ok"` when every check
    reports `"ok"`; otherwise returns `503` with `status: "degraded"`
    and the same body shape.
    """,
    tags: ["Health"],
    security: [],
    responses: [
      ok:
        {"Readiness snapshot", "application/json",
         BankWeb.OpenApi.Schemas.HealthReadinessResponse},
      service_unavailable:
        {"At least one check is degraded; body mirrors the 200 shape.", "application/json",
         BankWeb.OpenApi.Schemas.HealthReadinessResponse}
    ]
  )

  @doc "Readiness probe — verifies the Postgres connection."
  def readiness(conn, _params) do
    checks = %{database: database_check()}
    overall = if Enum.all?(checks, fn {_, v} -> v == "ok" end), do: "ok", else: "degraded"
    status_code = if overall == "ok", do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(%{status: overall, service: "bank", version: @app_version, checks: checks})
  end

  operation(:deep,
    summary: "Deep operational-health probe",
    description: """
    Runs every operational check in `Bank.Ops.Health.snapshot/0`:
    Postgres, adapter reachability, stuck-plan count, … Returns
    `200` when every check is `ok`; otherwise `503` with a non-`ok`
    overall `status`. Safe to alert on.
    """,
    tags: ["Health"],
    security: [],
    responses: [
      ok:
        {"Deep health snapshot", "application/json", BankWeb.OpenApi.Schemas.HealthDeepResponse},
      service_unavailable:
        {"At least one check is degraded; body mirrors the 200 shape.", "application/json",
         BankWeb.OpenApi.Schemas.HealthDeepResponse}
    ]
  )

  @doc """
  Deep readiness probe — runs every operational check: Postgres,
  adapter reachability, stuck-plan count. Returns 503 if any check is
  degraded. Safe to alert on.
  """
  def deep(conn, _params) do
    %{status: overall, checks: checks} = Bank.Ops.Health.snapshot()
    status_code = if overall == :ok, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(%{
      status: Atom.to_string(overall),
      service: "bank",
      version: @app_version,
      checks: render_checks(checks)
    })
  end

  defp render_checks(checks) do
    Map.new(checks, fn {name, %{status: status} = v} ->
      {name, Map.put(v, :status, Atom.to_string(status))}
    end)
  end

  defp database_check do
    case Ecto.Adapters.SQL.query(Bank.Repo, "SELECT 1", []) do
      {:ok, _} -> "ok"
      {:error, _} -> "error"
    end
  rescue
    _ -> "error"
  end
end
