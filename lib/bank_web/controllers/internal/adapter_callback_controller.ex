defmodule BankWeb.Internal.AdapterCallbackController do
  @moduledoc """
  Internal callback endpoint for the TypeScript adapter.

  `POST /internal/adapter/callback`

  The adapter sends callbacks here after chain-level events:
  execution broadcast/confirmed/reverted/aborted and delegation
  state changes. This controller routes each callback kind to the
  appropriate context and emits audit + runtime broadcasts.

  Not part of the external `/v1/` API surface. Authenticated via
  shared bearer secret (mTLS in production).
  """

  use BankWeb, :controller

  require Logger

  alias Bank.Delegations
  alias Bank.Runtime

  @execution_kinds ~w(execution.broadcast execution.confirmed execution.reverted execution.aborted)
  @delegation_kinds ~w(delegation.state_changed)

  def callback(conn, params) do
    with :ok <- validate_contract_version(params),
         {:ok, kind} <- extract_kind(params) do
      handle_kind(conn, kind, params)
    else
      {:error, envelope} -> render_error(conn, envelope)
    end
  end

  # --- Delegation callbacks -----------------------------------------------

  defp handle_kind(conn, "delegation.state_changed", params) do
    prior_state =
      case Delegations.get(params["smart_account_id"]) do
        nil -> nil
        d -> d.state
      end

    case Delegations.apply_callback(params) do
      {:ok, delegation} ->
        # Audit
        audit_attrs =
          Bank.Audit.Events.delegation_state_changed(delegation, prior_state, actor: :adapter)

        _ = Runtime.emit_audit(audit_attrs)

        # Broadcast
        Runtime.broadcast_security_event(:delegation_state_changed, %{
          smart_account_id: delegation.smart_account_id,
          delegation_id: delegation.delegation_id,
          state: delegation.state,
          reason: delegation.last_reason
        })

        conn
        |> put_status(:ok)
        |> json(%{status: "accepted", kind: "delegation.state_changed"})

      {:error, reason} ->
        Logger.warning(
          "Delegation callback failed: #{inspect(reason)}, params: #{inspect(params)}"
        )

        conn
        |> put_status(:ok)
        |> json(%{
          status: "accepted_with_warning",
          kind: "delegation.state_changed",
          warning: to_string(reason)
        })
    end
  end

  # --- Execution callbacks ------------------------------------------------

  defp handle_kind(conn, "execution.broadcast", params) do
    # Update plan status and emit audit.
    # For v0.1 the ConfirmExecution worker handles plan progression;
    # the callback just acknowledges receipt.
    Logger.info("Received execution.broadcast callback",
      execution_plan_id: params["execution_plan_id"]
    )

    conn
    |> put_status(:ok)
    |> json(%{status: "accepted", kind: "execution.broadcast"})
  end

  defp handle_kind(conn, "execution.confirmed", params) do
    Logger.info("Received execution.confirmed callback",
      execution_plan_id: params["execution_plan_id"]
    )

    conn
    |> put_status(:ok)
    |> json(%{status: "accepted", kind: "execution.confirmed"})
  end

  defp handle_kind(conn, "execution.reverted", params) do
    Logger.info("Received execution.reverted callback",
      execution_plan_id: params["execution_plan_id"]
    )

    conn
    |> put_status(:ok)
    |> json(%{status: "accepted", kind: "execution.reverted"})
  end

  defp handle_kind(conn, "execution.aborted", params) do
    Logger.info("Received execution.aborted callback",
      execution_plan_id: params["execution_plan_id"]
    )

    conn
    |> put_status(:ok)
    |> json(%{status: "accepted", kind: "execution.aborted"})
  end

  defp handle_kind(conn, kind, _params) do
    render_error(conn, %{
      status: :unprocessable_entity,
      code: "unknown_kind",
      message: "unknown callback kind: #{kind}"
    })
  end

  # --- Validation ---------------------------------------------------------

  defp validate_contract_version(%{"contract_version" => 1}), do: :ok

  defp validate_contract_version(%{"contract_version" => v}) do
    {:error,
     %{
       status: :unprocessable_entity,
       code: "unsupported_contract_version",
       message: "expected contract_version 1, got #{inspect(v)}"
     }}
  end

  defp validate_contract_version(_) do
    {:error,
     %{
       status: :bad_request,
       code: "missing_contract_version",
       message: "contract_version is required"
     }}
  end

  defp extract_kind(%{"kind" => kind})
       when kind in @execution_kinds or kind in @delegation_kinds do
    {:ok, kind}
  end

  defp extract_kind(%{"kind" => kind}) do
    {:error,
     %{
       status: :unprocessable_entity,
       code: "unknown_kind",
       message: "unknown callback kind: #{kind}"
     }}
  end

  defp extract_kind(_) do
    {:error,
     %{
       status: :bad_request,
       code: "missing_kind",
       message: "kind is required"
     }}
  end

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
