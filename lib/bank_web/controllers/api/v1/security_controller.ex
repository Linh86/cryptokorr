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

  alias Bank.Security

  # --- POST /v1/security/pause -------------------------------------------

  def pause(conn, params) do
    scope = parse_scope(params)
    reason = Map.get(params, "reason", "operator_requested")

    case Security.pause(scope, reason: reason, actor: :user) do
      {:ok, :paused} ->
        conn |> put_status(:ok) |> json(%{status: "paused", scope: scope_json(scope)})

      {:ok, :already_paused} ->
        conn |> put_status(:ok) |> json(%{status: "already_paused", scope: scope_json(scope)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "pause_failed", message: inspect(reason)}})
    end
  end

  # --- POST /v1/security/resume ------------------------------------------

  def resume(conn, params) do
    scope = parse_scope(params)

    case Security.resume(scope, actor: :user) do
      {:ok, :resumed} ->
        conn |> put_status(:ok) |> json(%{status: "resumed", scope: scope_json(scope)})

      {:ok, :already_running} ->
        conn |> put_status(:ok) |> json(%{status: "already_running", scope: scope_json(scope)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "resume_failed", message: inspect(reason)}})
    end
  end

  # --- POST /v1/security/revoke_delegation --------------------------------

  def revoke_delegation(conn, params) do
    case Map.get(params, "smart_account_id") do
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_body", message: "smart_account_id is required"}})

      "" ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_body", message: "smart_account_id is required"}})

      smart_account_id ->
        reason = Map.get(params, "reason", "operator_requested")

        case Security.revoke_delegation(smart_account_id,
               reason: String.to_atom(reason),
               actor: :user
             ) do
          {:ok, _job} ->
            conn
            |> put_status(:accepted)
            |> json(%{
              status: "revoke_enqueued",
              smart_account_id: smart_account_id
            })

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "revoke_failed", message: inspect(reason)}})
        end
    end
  end

  # --- Helpers ------------------------------------------------------------

  defp parse_scope(%{"scope" => "counterparty:" <> id}), do: {:counterparty, id}
  defp parse_scope(_), do: :global

  defp scope_json(:global), do: "global"
  defp scope_json({:counterparty, id}), do: "counterparty:#{id}"
end
