defmodule BankWeb.Internal.AdapterCallbackController do
  @moduledoc """
  Internal callback endpoint for the TypeScript adapter.

  `POST /internal/adapter/callback`

  The adapter posts callbacks here after chain-level events:
  execution broadcast/confirmed/reverted/aborted and delegation state
  changes. Each callback is routed to its owning bounded context
  (`Bank.Decisions` for execution, `Bank.Delegations` for delegation
  state). The context returns enough information for this controller
  to emit audit + runtime broadcasts without re-reading state.

  Not part of the external `/v1/` API surface. Authenticated via a
  shared bearer secret (mTLS in production).
  """

  use BankWeb, :controller

  require Logger

  alias Bank.Audit.Events
  alias Bank.Decisions
  alias Bank.Delegations
  alias Bank.Runtime
  alias Bank.Runtime.Notifier

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
        audit_attrs =
          Events.delegation_state_changed(delegation, prior_state, actor: :adapter)

        _ = Runtime.emit_audit(audit_attrs)

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

  defp handle_kind(conn, kind, params) when kind in @execution_kinds do
    case Decisions.apply_execution_callback(params) do
      {:ok, result} ->
        emit_execution_side_effects(result)

        conn
        |> put_status(:ok)
        |> json(%{status: "accepted", kind: kind})

      {:error, :plan_not_found} ->
        Logger.warning(
          "Execution callback for unknown plan: kind=#{kind}, params=#{inspect(params)}"
        )

        conn
        |> put_status(:ok)
        |> json(%{
          status: "accepted_with_warning",
          kind: kind,
          warning: "plan_not_found"
        })

      {:error, reason} ->
        Logger.warning(
          "Execution callback failed: kind=#{kind}, reason=#{inspect(reason)}, params=#{inspect(params)}"
        )

        conn
        |> put_status(:ok)
        |> json(%{
          status: "accepted_with_warning",
          kind: kind,
          warning: summarise_error(reason)
        })
    end
  end

  defp handle_kind(conn, kind, _params) do
    render_error(conn, %{
      status: :unprocessable_entity,
      code: "unknown_kind",
      message: "unknown callback kind: #{kind}"
    })
  end

  # --- Side effects -------------------------------------------------------

  defp emit_execution_side_effects(%{
         plan: plan,
         prior_plan_status: prior_status,
         intent_transition: intent_transition
       }) do
    _ =
      Runtime.emit_audit(Events.execution_transition(plan, prior_status, actor: :adapter))

    Notifier.execution_progressed(plan, prior_status)

    case intent_transition do
      {:transitioned, from, intent} ->
        _ =
          Runtime.emit_audit(
            Events.intent_state_changed(intent, from, intent.state, actor: :adapter)
          )

        Notifier.intent_lifecycle(intent, :state_changed, %{
          from: from,
          to: intent.state,
          execution_plan_id: plan.id
        })

      _ ->
        :ok
    end
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

  defp summarise_error(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end

  defp summarise_error(reason), do: inspect(reason)

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
