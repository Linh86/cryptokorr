defmodule BankWeb.API.V1.DecisionController do
  @moduledoc """
  `/v1/decisions` — decision envelope inspection and manual execution.

  Endpoints:

    * `GET  /v1/decisions/:id`         — envelope with supersession chain
    * `POST /v1/decisions/:id/execute` — manual trigger (hold release,
      retry after aborted plan, tiered-autonomy manual confirm)
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Bank.Decisions
  alias OpenApiSpex.{Parameter, Reference}

  @id_ref %Reference{"$ref": "#/components/schemas/Id"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @unauthorized_ref %Reference{"$ref": "#/components/responses/Unauthorized"}
  @forbidden_ref %Reference{"$ref": "#/components/responses/Forbidden"}
  @not_found_ref %Reference{"$ref": "#/components/responses/NotFound"}
  @conflict_ref %Reference{"$ref": "#/components/responses/Conflict"}
  @unprocessable_ref %Reference{"$ref": "#/components/responses/UnprocessableEntity"}
  @service_unavailable_ref %Reference{"$ref": "#/components/responses/ServiceUnavailable"}

  @decision_id_param %Parameter{
    name: :id,
    in: :path,
    required: true,
    description: "Opaque runtime-assigned decision envelope id (UUID).",
    schema: @id_ref
  }

  # --- GET /v1/decisions/:id -------------------------------------------

  operation(:show,
    summary: "Get a decision envelope",
    description: """
    Returns a decision envelope's detail plus the execution plans
    currently linked to it. This endpoint is live.
    """,
    tags: ["Decisions"],
    parameters: [@decision_id_param, @request_id_in_ref],
    responses: %{
      200 =>
        {"Decision envelope detail", "application/json",
         BankWeb.OpenApi.Schemas.DecisionShowResponse},
      401 => @unauthorized_ref,
      404 => @not_found_ref,
      422 => @unprocessable_ref
    }
  )

  def show(conn, %{"id" => id}) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, uuid} <- cast_uuid(id),
         {:ok, envelope} <- Decisions.get_envelope_with_plans_in_workspace(uuid, workspace_id) do
      conn
      |> put_status(:ok)
      |> json(%{
        data: %{
          id: envelope.id,
          intent_id: envelope.intent_id,
          outcome: envelope.outcome,
          risk_tier: envelope.risk_tier,
          state: envelope.state,
          current: envelope.current,
          decided_at: envelope.decided_at,
          decided_by: envelope.decided_by,
          approval_expires_at: envelope.approval_expires_at,
          supersedes_id: envelope.supersedes_id,
          policy_snapshot_ref: envelope.policy_snapshot_ref,
          execution_plans:
            Enum.map(envelope.execution_plans, fn p ->
              %{
                id: p.id,
                execution_status: p.execution_status,
                active: p.active,
                smart_account_id: p.smart_account_id,
                final_outcome: p.final_outcome,
                final_reason: p.final_reason
              }
            end)
        }
      })
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "decision envelope not found"}})

      {:error, envelope} ->
        render_error(conn, envelope)
    end
  end

  # --- POST /v1/decisions/:id/execute ----------------------------------

  operation(:execute,
    summary: "Manually execute an auto_exec decision",
    description: """
    Triggers execution on an `auto_exec` envelope. Used for hold
    release, retry after an aborted plan, and tiered-autonomy
    manual confirm. Requires `smart_account_id` in the body; the
    adapter will sign with the delegation bound to that account.
    Returns `202` with the new execution plan on success.
    """,
    tags: ["Decisions"],
    parameters: [@decision_id_param, @idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Execute decision body", "application/json",
       BankWeb.OpenApi.Schemas.ExecuteDecisionRequest},
    responses: %{
      202 =>
        {"Execution plan enqueued", "application/json",
         BankWeb.OpenApi.Schemas.ExecuteDecisionResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      404 => @not_found_ref,
      409 => @conflict_ref,
      422 => @unprocessable_ref,
      503 => @service_unavailable_ref
    }
  )

  def execute(conn, %{"id" => id} = params) do
    smart_account_id = Map.get(params, "smart_account_id")
    reason = Map.get(params, "reason", "manual_confirm")
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, uuid} <- cast_uuid(id),
         :ok <- require_smart_account_id(smart_account_id),
         {:ok, _envelope} <- Decisions.get_envelope_in_workspace(uuid, workspace_id) do
      case Decisions.request_manual_execution(uuid, smart_account_id,
             reason: reason,
             actor_id: nil
           ) do
        {:ok, plan} ->
          conn
          |> put_status(:accepted)
          |> json(%{
            data: %{
              id: plan.id,
              decision_id: plan.decision_id,
              intent_id: plan.intent_id,
              execution_status: plan.execution_status,
              smart_account_id: plan.smart_account_id,
              active: plan.active
            },
            status: "execution_enqueued"
          })

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: %{code: "not_found", message: "decision envelope not found"}})

        {:error, :not_current} ->
          conn
          |> put_status(:conflict)
          |> json(%{
            error: %{
              code: "not_current",
              message: "this envelope has been superseded"
            }
          })

        {:error, :active_plan_exists} ->
          conn
          |> put_status(:conflict)
          |> json(%{
            error: %{
              code: "active_plan_exists",
              message: "an active execution plan already exists for this decision"
            }
          })

        {:error, :runtime_paused} ->
          conn
          |> put_status(503)
          |> json(%{
            error: %{
              code: "runtime_paused",
              message: "execution is paused; resume the runtime first"
            }
          })

        {:error, :delegation_not_active} ->
          conn
          |> put_status(:conflict)
          |> json(%{
            error: %{
              code: "delegation_not_active",
              message: "no active delegation for smart account #{smart_account_id}"
            }
          })

        {:error, reason} ->
          conn
          |> put_status(:conflict)
          |> json(%{
            error: %{
              code: "execution_blocked",
              message: "cannot execute: #{reason}"
            }
          })
      end
    else
      # Cross-workspace or genuinely-unknown id from
      # `get_envelope_in_workspace/2` collapses to 404 — same shape
      # so a caller cannot probe across tenants (#159b).
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "decision envelope not found"}})

      {:error, envelope} ->
        render_error(conn, envelope)
    end
  end

  # --- Helpers ------------------------------------------------------------

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} ->
        {:ok, uuid}

      :error ->
        {:error,
         %{
           status: :unprocessable_entity,
           code: "invalid_id",
           message: "`id` must be a UUID"
         }}
    end
  end

  defp require_smart_account_id(nil) do
    {:error,
     %{
       status: :unprocessable_entity,
       code: "invalid_body",
       message: "smart_account_id is required"
     }}
  end

  defp require_smart_account_id("") do
    {:error,
     %{
       status: :unprocessable_entity,
       code: "invalid_body",
       message: "smart_account_id is required"
     }}
  end

  defp require_smart_account_id(_), do: :ok

  defp render_error(conn, %{status: status} = envelope) do
    conn
    |> put_status(status)
    |> json(%{
      error: %{
        code: envelope.code,
        message: envelope.message
      }
    })
  end
end
