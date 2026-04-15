defmodule BankWeb.API.V1.FallbackController do
  @moduledoc """
  Shared error-envelope rendering for `/v1/` controllers.

  The runtime-flow doc specifies a structured error shape:

      { "error": { "code": ..., "message": ..., "hint": ..., "retryable": ... } }

  Controllers call `not_implemented/3` from their action bodies to return
  a consistent `501 Not Implemented` envelope while the engines are
  scaffolding. When a real action lands, the call is replaced with the
  implemented behaviour.

  The module is intentionally narrow. Production error rendering for
  the engines arrives alongside the handlers themselves.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  @doc """
  Render a `501 Not Implemented` error envelope.

  `endpoint` is a short caller-supplied label (e.g. `"POST /v1/intents"`)
  that appears in the `message` field so clients can see which surface
  has not yet been wired up.
  """
  def not_implemented(
        conn,
        endpoint,
        hint \\ "scaffold only — implementation lands with the owning engine"
      ) do
    conn
    |> put_status(:not_implemented)
    |> json(%{
      error: %{
        code: "not_implemented",
        message: "#{endpoint} is not implemented yet",
        hint: hint,
        retryable: false
      }
    })
  end
end
