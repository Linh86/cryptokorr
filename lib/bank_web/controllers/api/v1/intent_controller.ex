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

  `create/2`, `show/2`, `cancel/2`, and `simulate/2` are live: create
  persists an `%AgentIntent{}` in `:submitted`, audits
  `intent.submitted`, and enqueues `Bank.Runtime.Workers.EvaluateIntent`.
  cancel transitions pre-execution intents to `:cancelled`, audits
  `intent.cancelled` with the operator-supplied reason, and is
  idempotent against an already-cancelled intent. simulate produces
  a fresh `SimulationReport` via `Bank.Quotes.preview/2`; with
  `reason="refresh"` the new report supersedes the prior current and
  the intent's `current_simulation_id` advances, while
  `pre_submit_dry_run` and `operator_inspection` write a
  non-current report (history-only).
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Bank.Audit
  alias Bank.Intents
  alias BankWeb.API.V1.{AuditJSON, IntentJSON}
  alias OpenApiSpex.{Parameter, Reference}

  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @unauthorized_ref %Reference{"$ref": "#/components/responses/Unauthorized"}
  @forbidden_ref %Reference{"$ref": "#/components/responses/Forbidden"}
  @too_many_requests_ref %Reference{"$ref": "#/components/responses/TooManyRequests"}
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
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      429 => @too_many_requests_ref,
      409 => @conflict_ref,
      422 => @unprocessable_ref
    }
  )

  def create(conn, params) do
    workspace_id = conn.assigns.current_scope.workspace.id

    # Pass `workspace_id` via the trusted `opts` channel — never from
    # request params. `Intents.submit/2`'s `stamp_workspace_id/2`
    # strips any body-supplied `workspace_id` defensively (#159b).
    case Intents.submit(params, workspace_id: workspace_id) do
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

      {:error, {:morpho_chain_not_supported, chain}} ->
        render_error(
          conn,
          :unprocessable_entity,
          "morpho_chain_not_supported",
          "chain `#{chain}` is not supported for `allocate_idle_capital`",
          hint:
            ~s|the MVP Morpho deposit path is Base Sepolia only — submit with `"chain": "base-sepolia"`|
        )

      {:error, :mainnet_disabled} ->
        render_error(
          conn,
          :unprocessable_entity,
          "mainnet_disabled",
          "Base mainnet is not enabled for this workspace",
          hint:
            "an admin must opt this workspace into Base mainnet (#178) before submitting mainnet intents"
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
      401 => @unauthorized_ref,
      429 => @too_many_requests_ref,
      404 => @not_found_ref
    }
  )

  def show(conn, %{"id" => id}) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, uuid} <- cast_uuid(id),
         %_{} = intent <- Intents.get_in_workspace(uuid, workspace_id) do
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
    Produces a fresh `SimulationReport` on demand. `reason` chooses
    the semantic:

      * `pre_submit_dry_run` — produce a report without changing the
        intent's `current_simulation_id`. History-only.
      * `refresh` — supersede the prior current simulation, mark the
        new one current, and advance the intent pointer. Resets the
        active report decisioning reads.
      * `operator_inspection` — same shape as `pre_submit_dry_run`
        with an audit trail tagged for operator inspection.

    Allowed source states: `:submitted`, `:evaluating`, `:decided`,
    `:blocked`. In-flight (`:executing`) and terminal
    (`:executed`, `:cancelled`, `:expired`) states return `409`.
    """,
    tags: ["Intents"],
    parameters: [@intent_id_param, @idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Simulation request body", "application/json", BankWeb.OpenApi.Schemas.SimulationRequest},
    responses: %{
      200 =>
        {"Simulation report", "application/json",
         BankWeb.OpenApi.Schemas.IntentSimulationResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      429 => @too_many_requests_ref,
      404 => @not_found_ref,
      409 => @conflict_ref,
      422 => @unprocessable_ref
    }
  )

  def simulate(conn, %{"id" => id} = params) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, uuid} <- cast_uuid(id),
         %_{} <- Intents.get_in_workspace(uuid, workspace_id),
         {:ok, reason} <- cast_simulate_reason(params) do
      handle_simulate(conn, id, reason)
    else
      :error ->
        conn
        |> put_status(:not_found)
        |> json(not_found_envelope(id))

      nil ->
        # Intent does not exist OR belongs to another workspace —
        # 404 either way so cross-workspace probes do not get a
        # different status than genuinely-missing ids (#159b).
        conn
        |> put_status(:not_found)
        |> json(not_found_envelope(id))

      {:error, :reason_required} ->
        render_error(
          conn,
          :unprocessable_entity,
          "invalid_body",
          "`reason` is required"
        )

      {:error, {:invalid_reason, value}} ->
        render_error(
          conn,
          :unprocessable_entity,
          "invalid_reason",
          "`reason` must be one of: pre_submit_dry_run, refresh, operator_inspection",
          hint: "got #{inspect(value)}"
        )
    end
  end

  defp cast_simulate_reason(%{"reason" => reason}) when is_binary(reason) do
    case String.trim(reason) do
      "" ->
        {:error, :reason_required}

      trimmed when trimmed in ~w(pre_submit_dry_run refresh operator_inspection) ->
        {:ok, trimmed}

      other ->
        {:error, {:invalid_reason, other}}
    end
  end

  defp cast_simulate_reason(%{"reason" => other}) do
    {:error, {:invalid_reason, other}}
  end

  defp cast_simulate_reason(_), do: {:error, :reason_required}

  defp handle_simulate(conn, id, reason) do
    case Intents.simulate(id, reason, actor: :agent) do
      {:ok, %{intent: intent, report: report, reason: reason, refreshed?: refreshed?}} ->
        conn
        |> put_status(:ok)
        |> json(
          IntentJSON.simulated(%{
            intent: intent,
            report: report,
            reason: reason,
            refreshed?: refreshed?
          })
        )

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(not_found_envelope(id))

      {:error, {:wrong_state, state}} ->
        render_error(
          conn,
          :conflict,
          "wrong_state",
          "intent cannot be simulated in state `#{state}`",
          hint: simulate_wrong_state_hint(state)
        )

      {:error, {:invalid_reason, value}} ->
        render_error(
          conn,
          :unprocessable_entity,
          "invalid_reason",
          "`reason` must be one of: pre_submit_dry_run, refresh, operator_inspection",
          hint: "got #{inspect(value)}"
        )

      {:error, {:unsupported_chain, chain}} ->
        render_error(
          conn,
          :unprocessable_entity,
          "unsupported_chain",
          "chain `#{chain}` is not supported by simulation",
          hint: ~s|the runtime currently accepts only `"base"`|
        )

      {:error, {:invalid, _other}} ->
        render_error(
          conn,
          :unprocessable_entity,
          "invalid_body",
          "request body failed validation"
        )
    end
  end

  defp simulate_wrong_state_hint(:executing),
    do: "execution is in flight; use replay to inspect what already happened"

  defp simulate_wrong_state_hint(state) when state in [:executed, :blocked, :cancelled, :expired],
    do: "intent is terminal in state `#{state}`; use replay to inspect what was simulated"

  defp simulate_wrong_state_hint(_), do: nil

  operation(:cancel,
    summary: "Cancel an intent before execution",
    description: """
    Operator cancellation prior to execution. Allowed while the
    intent is `submitted`, `evaluating`, or `decided`; once
    `executing`, operators must use security controls instead.
    Re-cancelling an already-`cancelled` intent is idempotent and
    returns `200` with `idempotent: true`.

    On success the intent transitions to `:cancelled`, an
    `intent.cancelled` audit event is written carrying the supplied
    `reason`, and the event is fanned out on `audit:stream`.
    """,
    tags: ["Intents"],
    parameters: [@intent_id_param, @idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Cancel request body", "application/json", BankWeb.OpenApi.Schemas.CancelRequest},
    responses: %{
      200 =>
        {"Intent cancelled", "application/json", BankWeb.OpenApi.Schemas.IntentCancelResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      429 => @too_many_requests_ref,
      404 => @not_found_ref,
      409 => @conflict_ref,
      422 => @unprocessable_ref
    }
  )

  def cancel(conn, %{"id" => id} = params) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, uuid} <- cast_uuid(id),
         %_{} <- Intents.get_in_workspace(uuid, workspace_id),
         {:ok, reason} <- cast_cancel_reason(params) do
      handle_cancel(conn, id, reason)
    else
      :error ->
        conn
        |> put_status(:not_found)
        |> json(not_found_envelope(id))

      nil ->
        # Cross-workspace or missing — 404 either way (#159b).
        conn
        |> put_status(:not_found)
        |> json(not_found_envelope(id))

      {:error, :reason_required} ->
        render_error(
          conn,
          :unprocessable_entity,
          "invalid_body",
          "`reason` is required"
        )
    end
  end

  defp handle_cancel(conn, id, reason) do
    case Intents.cancel(id, reason: reason, actor: :user) do
      {:ok, intent} ->
        conn
        |> put_status(:ok)
        |> json(IntentJSON.cancelled(%{intent: intent, idempotent?: false, reason: reason}))

      {:ok, :already_cancelled, intent} ->
        conn
        |> put_status(:ok)
        |> json(IntentJSON.cancelled(%{intent: intent, idempotent?: true, reason: reason}))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(not_found_envelope(id))

      {:error, {:wrong_state, state}} ->
        render_error(
          conn,
          :conflict,
          "wrong_state",
          "intent cannot be cancelled in state `#{state}`",
          hint: cancel_wrong_state_hint(state)
        )

      {:error, {:invalid, :reason_required}} ->
        render_error(
          conn,
          :unprocessable_entity,
          "invalid_body",
          "`reason` is required"
        )

      {:error, {:invalid, _other}} ->
        render_error(
          conn,
          :unprocessable_entity,
          "invalid_body",
          "request body failed validation"
        )
    end
  end

  defp cast_cancel_reason(%{"reason" => reason}) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp cast_cancel_reason(_), do: {:error, :reason_required}

  defp cancel_wrong_state_hint(:executing),
    do: "use the security pause / revoke surface to halt an executing intent"

  defp cancel_wrong_state_hint(state)
       when state in [:executed, :blocked, :expired],
       do: "intent is already terminal in state `#{state}`"

  defp cancel_wrong_state_hint(_), do: nil

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
      401 => @unauthorized_ref,
      429 => @too_many_requests_ref,
      404 => @not_found_ref
    }
  )

  def replay(conn, %{"id" => id}) do
    workspace_id = conn.assigns.current_scope.workspace.id

    case Ecto.UUID.cast(id) do
      :error ->
        conn
        |> put_status(:not_found)
        |> json(not_found_envelope(id))

      {:ok, intent_id} ->
        case Intents.get_in_workspace(intent_id, workspace_id) do
          nil ->
            # Workspace miss → 404 before we ever touch the audit
            # replay so we never leak a sibling workspace's audit
            # bundle (#159b).
            conn
            |> put_status(:not_found)
            |> json(not_found_envelope(intent_id))

          %_{} ->
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
