defmodule BankWeb.API.V1.DecisionController do
  @moduledoc """
  `/v1/decisions` — decision envelope inspection and manual execution.

  Endpoints:

    * `GET  /v1/decisions/:id`         — envelope with supersession chain
    * `POST /v1/decisions/:id/execute` — manual trigger (hold release,
      retry after aborted plan, tiered-autonomy manual confirm)
  """

  use BankWeb, :controller

  alias Bank.Decisions

  # --- GET /v1/decisions/:id -------------------------------------------

  def show(conn, %{"id" => id}) do
    with {:ok, uuid} <- cast_uuid(id),
         {:ok, envelope} <- Decisions.get_envelope_with_plans(uuid) do
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

  def execute(conn, %{"id" => id} = params) do
    smart_account_id = Map.get(params, "smart_account_id")
    reason = Map.get(params, "reason", "manual_confirm")

    with {:ok, uuid} <- cast_uuid(id),
         :ok <- require_smart_account_id(smart_account_id) do
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
      {:error, envelope} -> render_error(conn, envelope)
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
