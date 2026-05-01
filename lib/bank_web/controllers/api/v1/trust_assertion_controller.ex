defmodule BankWeb.API.V1.TrustAssertionController do
  @moduledoc """
  `/v1/trust_assertions` — operator-issued manual trust overrides.

  Trust levels are the fixed v1 vocabulary: `trusted`, `sensitive`,
  `unknown`, `conflicted`. Trust-engine-derived assertions take the
  same internal shape but never come through this endpoint.

  Endpoints:

    * `POST /v1/trust_assertions` — new assertion; any prior active
      assertion with overlapping scope is marked `superseded`

  Request body (from the runtime-flow doc):

      {
        "subject": { "type": "counterparty" | "address_label", "id": "..." },
        "level":   "trusted" | "sensitive" | "unknown" | "conflicted",
        "scope":   { ... },
        "rationale": "...",
        "expires_at": "..."
      }

  The context emits `trust_assertion.issued` — this controller only
  parses input and shapes the response. Unscoped `trusted` assertions
  are accepted but flagged `coarse: true` in the response.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Bank.Counterparties
  alias BankWeb.API.V1.CounterpartyJSON
  alias OpenApiSpex.Reference

  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @unauthorized_ref %Reference{"$ref": "#/components/responses/Unauthorized"}
  @forbidden_ref %Reference{"$ref": "#/components/responses/Forbidden"}
  @too_many_requests_ref %Reference{"$ref": "#/components/responses/TooManyRequests"}
  @not_found_ref %Reference{"$ref": "#/components/responses/NotFound"}
  @unprocessable_ref %Reference{"$ref": "#/components/responses/UnprocessableEntity"}

  @subject_types ~w(counterparty address_label)
  @levels ~w(trusted sensitive unknown conflicted)

  operation(:create,
    summary: "Issue a trust assertion",
    description: """
    Operator-issued manual trust override. Any prior active
    assertion with overlapping scope is marked `superseded`.
    Trust-engine-derived assertions take the same internal shape
    but never come through this endpoint; the response's
    `issued_by` disambiguates.
    """,
    tags: ["TrustAssertions"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Trust assertion body", "application/json",
       BankWeb.OpenApi.Schemas.IssueTrustAssertionRequest},
    responses: %{
      201 =>
        {"New trust assertion", "application/json",
         BankWeb.OpenApi.Schemas.IssueTrustAssertionResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      429 => @too_many_requests_ref,
      404 => @not_found_ref,
      422 => @unprocessable_ref
    }
  )

  def create(conn, params) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, {subject_type, subject_id}} <- parse_subject(params),
         {:ok, level} <- parse_level(params),
         {:ok, expires_at} <- parse_expires_at(params),
         {:ok, scope} <- parse_scope(params),
         :ok <- ensure_subject_in_workspace(subject_type, subject_id, workspace_id) do
      attrs = %{
        level: level,
        scope: scope,
        rationale: Map.get(params, "rationale"),
        expires_at: expires_at,
        evidence_ids: Map.get(params, "evidence_ids", []),
        issued_by: :user
      }

      case Counterparties.issue_trust_assertion(
             subject_type,
             subject_id,
             attrs,
             actor_opts(conn)
           ) do
        {:ok, assertion} ->
          conn
          |> put_status(:created)
          |> json(CounterpartyJSON.trust_assertion_issued(%{trust_assertion: assertion}))

        {:error, :not_found} ->
          render_error(conn, %{
            status: :not_found,
            code: "not_found",
            message: "no active #{subject_type} with id=#{subject_id}",
            hint: "check the subject or confirm it is not archived / retired",
            retryable: false
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          render_changeset_error(conn, changeset)
      end
    else
      {:error, envelope} -> render_error(conn, envelope)
    end
  end

  # --- parsing ----------------------------------------------------------

  defp parse_subject(%{"subject" => %{"type" => type, "id" => id}})
       when type in @subject_types and is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        {:ok, {type, uuid}}

      :error ->
        {:error, invalid_body_envelope("subject.id must be a UUID")}
    end
  end

  defp parse_subject(%{"subject" => %{"type" => type}}) when type not in @subject_types do
    {:error, invalid_body_envelope(~s|subject.type must be one of #{inspect(@subject_types)}|)}
  end

  defp parse_subject(_params),
    do:
      {:error,
       invalid_body_envelope(~s|missing `subject` object — expected {"type": ..., "id": ...}|)}

  defp parse_level(%{"level" => level}) when level in @levels,
    do: {:ok, String.to_existing_atom(level)}

  defp parse_level(%{"level" => _}),
    do: {:error, invalid_body_envelope(~s|`level` must be one of #{inspect(@levels)}|)}

  defp parse_level(_params),
    do: {:error, invalid_body_envelope("missing `level`")}

  defp parse_expires_at(%{"expires_at" => nil}), do: {:ok, nil}
  defp parse_expires_at(%{"expires_at" => ""}), do: {:ok, nil}

  defp parse_expires_at(%{"expires_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, invalid_body_envelope("`expires_at` must be an ISO 8601 timestamp")}
    end
  end

  defp parse_expires_at(_params), do: {:ok, nil}

  defp parse_scope(%{"scope" => nil}), do: {:ok, %{}}
  defp parse_scope(%{"scope" => %{} = scope}), do: {:ok, scope}

  defp parse_scope(%{"scope" => _other}),
    do: {:error, invalid_body_envelope("`scope` must be an object")}

  defp parse_scope(_params), do: {:ok, %{}}

  defp invalid_body_envelope(hint) do
    %{
      status: :unprocessable_entity,
      code: "invalid_body",
      message: "request body failed validation",
      hint: hint,
      retryable: false
    }
  end

  # Workspace scoping for the trust-assertion subject (#159b).
  # An operator in workspace A must not be able to issue a trust
  # assertion against a counterparty / address-label in workspace
  # B. Both subject types are reachable via
  # `Bank.Counterparties.get_counterparty_in_workspace/2` (direct)
  # or via the counterparty FK on `address_labels` (one extra
  # join). Cross-workspace ids return 404 — same shape as a
  # genuinely-unknown id so a caller cannot probe across tenants.
  defp ensure_subject_in_workspace("counterparty", subject_id, workspace_id) do
    case Counterparties.get_counterparty_in_workspace(subject_id, workspace_id) do
      {:ok, _cp} ->
        :ok

      {:error, :not_found} ->
        {:error,
         %{
           status: :not_found,
           code: "not_found",
           message: "no active counterparty with id=#{subject_id}",
           hint: "check the subject or confirm it is not archived",
           retryable: false
         }}
    end
  end

  defp ensure_subject_in_workspace("address_label", subject_id, workspace_id) do
    import Ecto.Query

    query =
      from(l in Bank.Counterparties.AddressLabel,
        join: c in Bank.Counterparties.Counterparty,
        on: l.counterparty_id == c.id,
        where: l.id == ^subject_id and c.workspace_id == ^workspace_id,
        select: l.id
      )

    case Bank.Repo.one(query) do
      nil ->
        {:error,
         %{
           status: :not_found,
           code: "not_found",
           message: "no active address_label with id=#{subject_id}",
           hint: "check the subject or confirm it is not retired",
           retryable: false
         }}

      _id ->
        :ok
    end
  end

  # --- response shaping ------------------------------------------------

  defp actor_opts(_conn), do: [actor: :user]

  defp render_error(conn, %{status: status} = envelope) do
    conn
    |> put_status(status)
    |> json(%{
      error: %{
        code: envelope.code,
        message: envelope.message,
        hint: envelope[:hint],
        retryable: envelope[:retryable] || false
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
