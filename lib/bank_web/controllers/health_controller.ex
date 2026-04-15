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

  @app_version Mix.Project.config()[:version]

  @doc "Liveness probe — no external dependencies."
  def liveness(conn, _params) do
    json(conn, %{status: "ok", service: "bank", version: @app_version})
  end

  @doc "Readiness probe — verifies the Postgres connection."
  def readiness(conn, _params) do
    checks = %{database: database_check()}
    overall = if Enum.all?(checks, fn {_, v} -> v == "ok" end), do: "ok", else: "degraded"
    status_code = if overall == "ok", do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(%{status: overall, service: "bank", version: @app_version, checks: checks})
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
