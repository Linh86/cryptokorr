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
  use OpenApiSpex.ControllerSpecs

  alias Bank.Security
  alias OpenApiSpex.Reference

  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @unauthorized_ref %Reference{"$ref": "#/components/responses/Unauthorized"}
  @forbidden_ref %Reference{"$ref": "#/components/responses/Forbidden"}
  @unprocessable_ref %Reference{"$ref": "#/components/responses/UnprocessableEntity"}

  # --- POST /v1/security/pause -------------------------------------------

  operation(:pause,
    summary: "Pause automation",
    description: """
    Soft pause — blocks new `executing` transitions while letting
    pending confirmations keep polling, agents keep submitting, and
    decisions keep being written.

    Scope parse: `"counterparty:{id}"` yields a counterparty-scoped
    pause; any other value (omitted, `null`, `"global"`, or an
    unrecognised string) is currently treated as a global pause —
    the runtime does NOT reject unknown scope values today. See
    `SecurityPauseRequest.scope` for the truthful wording.

    The already-paused case returns `200` with
    `status: "already_paused"` — it is idempotent, not an error.
    """,
    tags: ["Security"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Pause body", "application/json", BankWeb.OpenApi.Schemas.SecurityPauseRequest},
    responses: %{
      200 => {"Pause state", "application/json", BankWeb.OpenApi.Schemas.SecurityStateResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      422 => @unprocessable_ref
    }
  )

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

  operation(:resume,
    summary: "Resume automation",
    description: """
    Lifts the pause. Intents that accumulated while paused are NOT
    auto-flushed into execution — each still needs a decision event
    or a manual `POST /v1/decisions/{id}/execute`.

    Scope parse: same semantics as pause — `"counterparty:{id}"`
    resumes that scope, any other value resumes globally. The
    runtime does NOT reject unknown `scope` values today. Returns
    `200` with `status: "already_running"` when the scope was not
    paused.
    """,
    tags: ["Security"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Resume body", "application/json", BankWeb.OpenApi.Schemas.SecurityResumeRequest},
    responses: %{
      200 => {"Resume state", "application/json", BankWeb.OpenApi.Schemas.SecurityStateResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      422 => @unprocessable_ref
    }
  )

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

  operation(:revoke_delegation,
    summary: "Submit a delegation revoke",
    description: """
    Enqueues a delegation revoke for the given smart account. The
    synchronous response is a **receipt**: `202 revoke_enqueued`
    with the `smart_account_id` as the handle. The chain-side state
    change has NOT yet landed — final state is delivered
    asynchronously via the `security:events` realtime channel and
    the audit stream.

    Revoke is one-way at the API: re-delegation is intentionally
    not a v1 `/v1/security` operation. Re-delegation is an operator
    flow in the web console's security surface, outside the
    external API.
    """,
    tags: ["Security"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Revoke body", "application/json", BankWeb.OpenApi.Schemas.RevokeDelegationRequest},
    responses: %{
      202 =>
        {"Revoke enqueued", "application/json", BankWeb.OpenApi.Schemas.RevokeDelegationResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      422 => @unprocessable_ref
    }
  )

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
