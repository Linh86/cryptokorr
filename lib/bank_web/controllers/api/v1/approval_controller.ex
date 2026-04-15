defmodule BankWeb.API.V1.ApprovalController do
  @moduledoc """
  `/v1/approvals` — operator approval queue.

  Endpoints:

    * `GET  /v1/approvals`                         — pending queue
    * `POST /v1/approvals/:decision_id/approve`    — produces a
      successor envelope with outcome `auto_exec`
    * `POST /v1/approvals/:decision_id/reject`     — produces a
      successor envelope with outcome `block`
  """

  use BankWeb, :controller

  import BankWeb.API.V1.FallbackController, only: [not_implemented: 3]

  def index(conn, _params),
    do: not_implemented(conn, "GET /v1/approvals", "implemented in issue #10")

  def approve(conn, _params),
    do:
      not_implemented(conn, "POST /v1/approvals/:decision_id/approve", "implemented in issue #10")

  def reject(conn, _params),
    do:
      not_implemented(conn, "POST /v1/approvals/:decision_id/reject", "implemented in issue #10")
end
