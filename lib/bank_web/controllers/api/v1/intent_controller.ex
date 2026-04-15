defmodule BankWeb.API.V1.IntentController do
  @moduledoc """
  `/v1/intents` — agent-facing intent submission and inspection.

  Endpoints (see runtime-flow doc for details):

    * `POST /v1/intents`              — submit an intent for evaluation
    * `GET  /v1/intents/:id`          — current state with linked
      decision / simulation / plan
    * `POST /v1/intents/:id/simulate` — on-demand dry-run simulation
    * `POST /v1/intents/:id/cancel`   — operator pre-execution cancel
    * `GET  /v1/intents/:id/replay`   — full replay bundle
  """

  use BankWeb, :controller

  import BankWeb.API.V1.FallbackController, only: [not_implemented: 3]

  alias Bank.Audit
  alias BankWeb.API.V1.AuditJSON

  def create(conn, _params),
    do: not_implemented(conn, "POST /v1/intents", "implemented with the intent engine")

  def show(conn, _params),
    do: not_implemented(conn, "GET /v1/intents/:id", "implemented with the intent engine")

  def simulate(conn, _params),
    do: not_implemented(conn, "POST /v1/intents/:id/simulate", "implemented in issue #9")

  def cancel(conn, _params),
    do: not_implemented(conn, "POST /v1/intents/:id/cancel", "implemented with the intent engine")

  def replay(conn, %{"id" => id}) do
    case Ecto.UUID.cast(id) do
      :error ->
        conn
        |> put_status(:not_found)
        |> json(not_found_envelope(id))

      {:ok, intent_id} ->
        case Audit.replay(intent_id) do
          {:ok, bundle} ->
            conn
            |> put_status(:ok)
            |> json(AuditJSON.replay(%{bundle: bundle}))

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(not_found_envelope(intent_id))
        end
    end
  end

  defp not_found_envelope(intent_id) do
    %{
      error: %{
        code: "not_found",
        message: "no intent with id=#{intent_id}",
        hint: "check the intent id or confirm the intent still exists",
        retryable: false
      }
    }
  end
end
