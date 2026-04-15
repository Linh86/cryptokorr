defmodule BankWeb.API.V1.SecurityController do
  @moduledoc """
  `/v1/security` — operator safety controls.

  Endpoints:

    * `POST /v1/security/pause`              — halt new `executing`
      transitions; pending confirmations keep polling
    * `POST /v1/security/resume`             — lift pause; queued
      intents do not auto-flush into execution
    * `POST /v1/security/revoke_delegation`  — submit delegation
      revocation via the chain adapter; final state change is delivered
      through `security:events` and audit
  """

  use BankWeb, :controller

  import BankWeb.API.V1.FallbackController, only: [not_implemented: 3]

  def pause(conn, _params),
    do: not_implemented(conn, "POST /v1/security/pause", "implemented in issue #12")

  def resume(conn, _params),
    do: not_implemented(conn, "POST /v1/security/resume", "implemented in issue #12")

  def revoke_delegation(conn, _params),
    do: not_implemented(conn, "POST /v1/security/revoke_delegation", "implemented in issue #12")
end
