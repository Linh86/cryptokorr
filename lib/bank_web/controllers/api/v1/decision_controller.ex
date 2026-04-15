defmodule BankWeb.API.V1.DecisionController do
  @moduledoc """
  `/v1/decisions` — decision envelope inspection and manual execution.

  Endpoints:

    * `GET  /v1/decisions/:id`         — envelope with supersession chain
    * `POST /v1/decisions/:id/execute` — manual trigger (hold release,
      retry after aborted plan, tiered-autonomy manual confirm)
  """

  use BankWeb, :controller

  import BankWeb.API.V1.FallbackController, only: [not_implemented: 3]

  def show(conn, _params),
    do: not_implemented(conn, "GET /v1/decisions/:id", "implemented in issue #10")

  def execute(conn, _params),
    do: not_implemented(conn, "POST /v1/decisions/:id/execute", "implemented in issue #11")
end
