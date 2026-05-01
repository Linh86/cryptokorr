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
    * `POST /v1/security/pause_agent_keys`   — workspace-wide pause
      for agent-key auth (#231-b). Refuses every `/v1` request from
      this workspace's API keys until resumed.
    * `POST /v1/security/resume_agent_keys`  — resume workspace-wide
      agent-key auth.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Bank.Accounts
  alias Bank.APIKeys
  alias Bank.Security
  alias Bank.Workspaces.Workspace
  alias OpenApiSpex.Reference

  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @unauthorized_ref %Reference{"$ref": "#/components/responses/Unauthorized"}
  @forbidden_ref %Reference{"$ref": "#/components/responses/Forbidden"}
  @too_many_requests_ref %Reference{"$ref": "#/components/responses/TooManyRequests"}
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
      429 => @too_many_requests_ref,
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
      429 => @too_many_requests_ref,
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
      429 => @too_many_requests_ref,
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
        reason_atom = parse_revoke_reason(Map.get(params, "reason"))

        case Security.revoke_delegation(smart_account_id,
               reason: reason_atom,
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

  # Pattern-matched allowlist for revoke reasons. Pre-#212 patch the
  # controller did `String.to_atom(reason)` on the request body, which
  # would mint a fresh atom for any caller-controlled string and
  # exhaust the atom table over time. The clauses below dispatch to
  # baked-in atom literals — no `String.to_atom/1`,
  # `String.to_existing_atom/1`, or `Module.concat/1` is reachable
  # from request bytes. Any value not on the list (including `nil`,
  # empty string, or junk) collapses to `:operator_requested`,
  # matching the prior default behavior. The whitelist mirrors the
  # operator-facing values documented on
  # `Bank.Runtime.enqueue_delegation_revoke/3`.
  defp parse_revoke_reason("operator_requested"), do: :operator_requested
  defp parse_revoke_reason("agent_offboarded"), do: :agent_offboarded
  defp parse_revoke_reason("pause_policy"), do: :pause_policy
  defp parse_revoke_reason(_), do: :operator_requested

  # --- POST /v1/security/pause_agent_keys (#231-b) -----------------------

  operation(:pause_agent_keys,
    summary: "Pause workspace-wide agent-key auth",
    description: """
    Refuses every `/v1` request from this workspace's API keys with
    `401 invalid_credentials` until resumed. Operates on the calling
    key's workspace (taken from `current_scope.workspace.id`); a
    `workspace_id` field in the request body is silently ignored.

    Idempotent: calling on an already-paused workspace returns the
    same `200` payload as the original pause (no second audit row).

    ## Bootstrap caveat (load-bearing)

    Once paused, every API key in this workspace returns
    `401 invalid_credentials` from `/v1` — including the calling
    key. Resume MUST come from a non-API-key path:

      * the LiveView Security console at `/security` (Google OAuth
        session, signed-in admin operator), or
      * `Bank.APIKeys.resume_workspace/3` from IEx.

    There is no API-side resume bypass. Deployments that authenticate
    only via API keys (CI / IEx-only) lose access; document this in
    your pause runbook.
    """,
    tags: ["Security"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Pause body", "application/json", BankWeb.OpenApi.Schemas.AgentKeysPauseRequest},
    responses: %{
      200 =>
        {"Workspace agent-key pause state", "application/json",
         BankWeb.OpenApi.Schemas.AgentKeysPauseStateResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      429 => @too_many_requests_ref,
      422 => @unprocessable_ref
    }
  )

  def pause_agent_keys(conn, params) do
    scope = conn.assigns.current_scope
    reason = clean_reason(Map.get(params, "reason"))

    with {:ok, actor} <- resolve_creator(scope),
         {:ok, _result, paused} <- APIKeys.pause_workspace(scope.workspace, actor, reason: reason) do
      conn
      |> put_status(:ok)
      |> json(%{data: pause_state(paused)})
    else
      {:error, :no_creator_user} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{code: "creator_user_unavailable"}})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: changeset_error(changeset)})
    end
  end

  # --- POST /v1/security/resume_agent_keys (#231-b) ----------------------

  operation(:resume_agent_keys,
    summary: "Resume workspace-wide agent-key auth",
    description: """
    Clears the workspace pause set by `pause_agent_keys`.

    > **Bootstrap note:** if this workspace's API keys are currently
    > paused, calls to this endpoint return `401 invalid_credentials`
    > because `VerifyAPIKey` short-circuits before the controller.
    > Use the LiveView Security console at `/security` or
    > `Bank.APIKeys.resume_workspace/3` from IEx instead.

    Idempotent: calling on an unpaused workspace returns the same
    `200` payload as the original resume (no second audit row).
    """,
    tags: ["Security"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    responses: %{
      200 =>
        {"Workspace agent-key pause state (now unpaused)", "application/json",
         BankWeb.OpenApi.Schemas.AgentKeysPauseStateResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      429 => @too_many_requests_ref,
      422 => @unprocessable_ref
    }
  )

  def resume_agent_keys(conn, _params) do
    scope = conn.assigns.current_scope

    with {:ok, actor} <- resolve_creator(scope),
         {:ok, _result, resumed} <- APIKeys.resume_workspace(scope.workspace, actor) do
      conn
      |> put_status(:ok)
      |> json(%{data: pause_state(resumed)})
    else
      {:error, :no_creator_user} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{code: "creator_user_unavailable"}})
    end
  end

  # --- Helpers ------------------------------------------------------------

  defp parse_scope(%{"scope" => "counterparty:" <> id}), do: {:counterparty, id}
  defp parse_scope(_), do: :global

  defp scope_json(:global), do: "global"
  defp scope_json({:counterparty, id}), do: "counterparty:#{id}"

  # Empty / whitespace-only reason → nil (matches the LiveView pattern).
  defp clean_reason(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_reason(_), do: nil

  # The audit `actor_id` is the calling user. When the request is
  # itself authenticated by an API key, `current_scope.user == nil`
  # and we resolve the human creator via `created_by_user_id`. Same
  # pattern as `BankWeb.API.V1.APIKeyController.resolve_creator/1`.
  defp resolve_creator(%{user: %Bank.Accounts.User{} = user}), do: {:ok, user}

  defp resolve_creator(%{api_key: %Bank.APIKeys.APIKey{} = api_key}) do
    case Accounts.get_user(api_key.created_by_user_id) do
      %Bank.Accounts.User{} = user -> {:ok, user}
      _ -> {:error, :no_creator_user}
    end
  end

  defp resolve_creator(_), do: {:error, :no_creator_user}

  defp pause_state(%Workspace{} = ws) do
    paused? = Workspace.agent_keys_paused?(ws)

    %{
      workspace_id: ws.id,
      paused: paused?,
      agent_keys_paused_at: ws.agent_keys_paused_at,
      paused_by_user_id: ws.agent_keys_paused_by_user_id,
      reason: ws.agent_keys_paused_reason
    }
  end

  # Surface the FIRST validation error in a stable wire shape. The
  # only validation today is `validate_length(:agent_keys_paused_reason,
  # max: 256)` from `Workspace.pause_changeset/2`.
  defp changeset_error(%Ecto.Changeset{errors: errors}) do
    case errors do
      [{:agent_keys_paused_reason, {_msg, _}} | _] ->
        %{code: "invalid_reason", message: "reason must be 256 characters or fewer"}

      [{field, {msg, _}} | _] ->
        %{code: "invalid_body", message: "#{field}: #{msg}"}

      [] ->
        %{code: "invalid_body"}
    end
  end
end
