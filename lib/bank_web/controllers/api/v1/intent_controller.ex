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

  `create/2` and `show/2` are live: create persists an
  `%AgentIntent{}` in `:submitted`, audits `intent.submitted`, and
  enqueues `Bank.Runtime.Workers.EvaluateIntent`. `simulate/2` and
  `cancel/2` still return `501` until the decision / approval engines
  land.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import BankWeb.API.V1.FallbackController, only: [not_implemented: 3]

  alias Bank.Audit
  alias Bank.Intents
  alias BankWeb.API.V1.{AuditJSON, IntentJSON}
  alias OpenApiSpex.{Parameter, Reference}

  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @not_implemented_ref %Reference{"$ref": "#/components/responses/NotImplemented"}
  @not_found_ref %Reference{"$ref": "#/components/responses/NotFound"}
  @conflict_ref %Reference{"$ref": "#/components/responses/Conflict"}
  @unprocessable_ref %Reference{"$ref": "#/components/responses/UnprocessableEntity"}
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

    Persists the intent in `:submitted`, audits `intent.submitted`,
    and enqueues `Bank.Runtime.Workers.EvaluateIntent`. Decision /
    simulation / approval engines have not yet landed, so the
    enqueued job currently cancels with `:engines_pending` —
    expected and visible in the Oban dashboard. Returns
    `202 Accepted`.

    Idempotency: a duplicate `(agent_id, idempotency_key)` with a
    matching body returns the existing intent and sets
    `idempotent_replay: true`; a duplicate with a mismatched body
    returns `409`.
    """,
    tags: ["Intents"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Intent submission body", "application/json",
       BankWeb.OpenApi.Schemas.IntentSubmissionRequest},
    responses: %{
      202 =>
        {"Intent accepted", "application/json", BankWeb.OpenApi.Schemas.IntentSubmitResponse},
      409 => @conflict_ref,
      422 => @unprocessable_ref
    }
  )

  def create(conn, params) do
    case Intents.submit(params) do
      {:ok, %{intent: intent, replay?: replay?}} ->
        conn
        |> put_status(:accepted)
        |> json(IntentJSON.created(%{intent: intent, replay?: replay?}))

      {:error, {:idempotency_conflict, prior}} ->
        render_error(
          conn,
          :conflict,
          "idempotency_conflict",
          "Idempotency-Key reused with a mismatched payload.",
          hint:
            "Retry with a fresh Idempotency-Key for a new intent, " <>
              "or resend the original payload to replay intent #{prior.id}."
        )

      {:error, {:unsupported_chain, chain}} ->
        render_error(
          conn,
          :unprocessable_entity,
          "unsupported_chain",
          "chain `#{chain}` is not supported",
          hint: ~s|the runtime currently accepts only `"base"`|
        )

      {:error, {:unsupported_asset, asset}} ->
        render_error(
          conn,
          :unprocessable_entity,
          "unsupported_asset",
          "asset `#{asset}` is not supported",
          hint: ~s|the runtime currently accepts only `"USDC"`|
        )

      {:error, {:invalid, %Ecto.Changeset{} = changeset}} ->
        render_changeset_error(conn, changeset)

      {:error, {:invalid, reason}} ->
        render_invalid(conn, reason)
    end
  end

  operation(:show,
    summary: "Get an intent by id",
    description: """
    Returns the current state of an intent together with the
    cached current-pointer ids for decision / simulation / trust
    assessment / execution plan.

    Decision / simulation / plan summaries are not inlined here in
    v0.1 — those engines have not landed yet. Callers that need
    the historical chain should use `GET /v1/intents/:id/replay`.
    """,
    tags: ["Intents"],
    parameters: [@intent_id_param, @request_id_in_ref],
    responses: %{
      200 => {"Intent detail", "application/json", BankWeb.OpenApi.Schemas.IntentShowResponse},
      404 => @not_found_ref
    }
  )

  def show(conn, %{"id" => id}) do
    with {:ok, uuid} <- cast_uuid(id),
         %_{} = intent <- Intents.get(uuid) do
      conn
      |> put_status(:ok)
      |> json(IntentJSON.show(%{intent: intent}))
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(not_found_envelope(id))
    end
  end

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

    This endpoint is live today.
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

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_), do: :error

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

  defp render_invalid(conn, :amount) do
    render_error(
      conn,
      :unprocessable_entity,
      "invalid_amount",
      "`amount` must be a positive decimal string",
      hint: ~s|example: "250.00"|
    )
  end

  defp render_invalid(conn, :target_ambiguous) do
    render_error(
      conn,
      :unprocessable_entity,
      "invalid_target",
      "exactly one of `target.counterparty_id` or `target.raw_address` must be set"
    )
  end

  defp render_invalid(conn, :target_missing) do
    render_error(
      conn,
      :unprocessable_entity,
      "invalid_target",
      "`target.counterparty_id` or `target.raw_address` is required"
    )
  end

  defp render_invalid(conn, :target_label_without_counterparty) do
    render_error(
      conn,
      :unprocessable_entity,
      "invalid_target",
      "`target.address_label_id` requires `target.counterparty_id`"
    )
  end

  defp render_invalid(conn, :target_counterparty_id) do
    render_error(
      conn,
      :unprocessable_entity,
      "invalid_target",
      "`target.counterparty_id` must be a UUID"
    )
  end

  defp render_invalid(conn, :target_address_label_id) do
    render_error(
      conn,
      :unprocessable_entity,
      "invalid_target",
      "`target.address_label_id` must be a UUID"
    )
  end

  defp render_invalid(conn, field) when is_atom(field) do
    render_error(
      conn,
      :unprocessable_entity,
      "invalid_body",
      "`#{field}` is required"
    )
  end

  defp render_invalid(conn, _) do
    render_error(
      conn,
      :unprocessable_entity,
      "invalid_body",
      "request body failed validation"
    )
  end

  defp render_error(conn, status, code, message, opts \\ []) do
    conn
    |> put_status(status)
    |> json(%{
      error: %{
        code: code,
        message: message,
        hint: Keyword.get(opts, :hint),
        retryable: Keyword.get(opts, :retryable, false)
      }
    })
  end

  defp render_changeset_error(conn, %Ecto.Changeset{} = changeset) do
    details = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "invalid_body",
        message: "request body failed validation",
        hint: nil,
        retryable: false,
        details: details
      }
    })
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn
      {key, value}, acc when is_binary(value) or is_atom(value) or is_integer(value) ->
        String.replace(acc, "%{#{key}}", to_string(value))

      _, acc ->
        acc
    end)
  end
end
