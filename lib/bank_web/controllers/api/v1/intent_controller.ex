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
  use OpenApiSpex.ControllerSpecs

  import BankWeb.API.V1.FallbackController, only: [not_implemented: 3]

  alias OpenApiSpex.{Parameter, Reference}

  alias Bank.Audit
  alias BankWeb.API.V1.AuditJSON

  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @not_implemented_ref %Reference{"$ref": "#/components/responses/NotImplemented"}
  @not_found_ref %Reference{"$ref": "#/components/responses/NotFound"}
  @id_ref %Reference{"$ref": "#/components/schemas/Id"}

  @intent_id_param %Parameter{
    name: :id,
    in: :path,
    required: true,
    description: "Opaque runtime-assigned intent id (UUID).",
    schema: @id_ref
  }

  operation(:create,
    summary: "Submit an intent for evaluation",
    description: """
    Agent-facing entry point for submitting a structured
    `AgentIntent` for evaluation. Request body fields match the
    pinned contract in `docs/bank-v0.1-runtime-flow-and-api.md`.

    **Current runtime behavior: returns `501 Not Implemented` —
    intent engine work is still pending.** The operation spec
    documents the target contract so SDK tooling can be generated
    ahead of the engine landing.
    """,
    tags: ["Intents"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Intent submission body", "application/json",
       BankWeb.OpenApi.Schemas.IntentSubmissionRequest},
    responses: %{
      501 => @not_implemented_ref
    }
  )

  def create(conn, _params),
    do: not_implemented(conn, "POST /v1/intents", "implemented with the intent engine")

  operation(:show,
    summary: "Get an intent by id",
    description: """
    Returns the current state of an intent together with linked
    decision / simulation / plan summaries.

    **Current runtime behavior: returns `501 Not Implemented`.**
    """,
    tags: ["Intents"],
    parameters: [@intent_id_param, @request_id_in_ref],
    responses: %{
      501 => @not_implemented_ref
    }
  )

  def show(conn, _params),
    do: not_implemented(conn, "GET /v1/intents/:id", "implemented with the intent engine")

  operation(:simulate,
    summary: "Request an on-demand simulation",
    description: """
    Produces a fresh `SimulationReport` on demand (pre-submit dry
    run, refresh, or operator inspection). `reason="refresh"`
    resets the active report used by decisioning.

    **Current runtime behavior: returns `501 Not Implemented`.**
    """,
    tags: ["Intents"],
    parameters: [@intent_id_param, @idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Simulation request body", "application/json", BankWeb.OpenApi.Schemas.SimulationRequest},
    responses: %{
      501 => @not_implemented_ref
    }
  )

  def simulate(conn, _params),
    do: not_implemented(conn, "POST /v1/intents/:id/simulate", "implemented in issue #9")

  operation(:cancel,
    summary: "Cancel an intent before execution",
    description: """
    Operator cancellation prior to execution. Allowed while the
    intent is `submitted`, `evaluating`, or `decided`; once
    `executing`, operators must use security controls instead.

    **Current runtime behavior: returns `501 Not Implemented`.**
    """,
    tags: ["Intents"],
    parameters: [@intent_id_param, @idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Cancel request body", "application/json", BankWeb.OpenApi.Schemas.CancelRequest},
    responses: %{
      501 => @not_implemented_ref
    }
  )

  def cancel(conn, _params),
    do: not_implemented(conn, "POST /v1/intents/:id/cancel", "implemented with the intent engine")

  operation(:replay,
    summary: "Get the full replay bundle for an intent",
    description: """
    Returns a deterministic replay bundle: the original intent, the
    policy snapshot each decision referenced, the trust assessment
    chain, simulation chain, decision chain, execution plan chain,
    and audit events. Rendered by
    `BankWeb.API.V1.AuditJSON.replay/1`.

    This endpoint is live today — unlike the other `/v1/intents`
    actions, it is not routed through the `not_implemented`
    fallback.
    """,
    tags: ["Intents"],
    parameters: [@intent_id_param, @request_id_in_ref],
    responses: %{
      200 => {"Replay bundle", "application/json", BankWeb.OpenApi.Schemas.IntentReplayResponse},
      404 => @not_found_ref
    }
  )

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
