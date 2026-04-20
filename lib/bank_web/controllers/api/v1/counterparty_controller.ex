defmodule BankWeb.API.V1.CounterpartyController do
  @moduledoc """
  `/v1/counterparties` — counterparty CRUD, address attachment, evidence
  pinning.

  Endpoints:

    * `GET   /v1/counterparties`                    — list / search
    * `POST  /v1/counterparties`                    — create
    * `PATCH /v1/counterparties/:id`                — name / notes / archive
    * `POST  /v1/counterparties/:id/addresses`      — attach address label
    * `POST  /v1/counterparties/:id/evidence`       — pin manual evidence

  Write paths delegate to `Bank.Counterparties`, which emits the audit
  event for each action through `Bank.Runtime.emit_audit/1`. The
  controller layer is responsible only for input parsing and HTTP
  response shaping.

  `actor`/`actor_id` fall back to `:user` / `nil` today; a real auth
  plug will populate them on the connection and the controller will
  forward those values into the context.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Bank.Counterparties
  alias BankWeb.API.V1.CounterpartyJSON
  alias OpenApiSpex.{Parameter, Reference, Schema}

  @list_limit_default 50
  @list_limit_max 500

  @id_ref %Reference{"$ref": "#/components/schemas/Id"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @not_found_ref %Reference{"$ref": "#/components/responses/NotFound"}
  @conflict_ref %Reference{"$ref": "#/components/responses/Conflict"}
  @unprocessable_ref %Reference{"$ref": "#/components/responses/UnprocessableEntity"}

  @counterparty_id_param %Parameter{
    name: :id,
    in: :path,
    required: true,
    description: "Opaque runtime-assigned counterparty id (UUID).",
    schema: @id_ref
  }

  @list_query_params [
    %Parameter{
      name: :q,
      in: :query,
      required: false,
      description: "Case-insensitive substring match on counterparty `name`.",
      schema: %Schema{type: :string}
    },
    %Parameter{
      name: :active,
      in: :query,
      required: false,
      description: "Filter to active (`true`) or archived (`false`) counterparties.",
      schema: %Schema{type: :string, enum: ["true", "false"]}
    },
    %Parameter{
      name: :limit,
      in: :query,
      required: false,
      description: "Page size. Default 50; max 500.",
      schema: %Schema{type: :integer, minimum: 1, maximum: 500, default: 50}
    },
    %Parameter{
      name: :cursor,
      in: :query,
      required: false,
      description: "Opaque cursor from a prior page.",
      schema: %Schema{type: :string}
    }
  ]

  # --- GET /v1/counterparties -------------------------------------------

  operation(:index,
    summary: "List counterparties",
    description: "Paged / filterable list of counterparties.",
    tags: ["Counterparties"],
    parameters: [@request_id_in_ref | @list_query_params],
    responses: %{
      200 =>
        {"Counterparty list", "application/json",
         BankWeb.OpenApi.Schemas.CounterpartyListResponse},
      422 => @unprocessable_ref
    }
  )

  def index(conn, params) do
    with {:ok, filters} <- parse_filters(params),
         {:ok, opts} <- parse_list_opts(params) do
      page = Counterparties.list_counterparties(filters, opts)

      conn
      |> put_status(:ok)
      |> json(CounterpartyJSON.index(page))
    else
      {:error, envelope} -> render_error(conn, envelope)
    end
  end

  # --- POST /v1/counterparties ------------------------------------------

  operation(:create,
    summary: "Create a counterparty",
    description: "Creates a new counterparty. `name` is required; other fields are optional.",
    tags: ["Counterparties"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Create counterparty body", "application/json",
       BankWeb.OpenApi.Schemas.CreateCounterpartyRequest},
    responses: %{
      201 =>
        {"Counterparty detail", "application/json", BankWeb.OpenApi.Schemas.CounterpartyResponse},
      422 => @unprocessable_ref
    }
  )

  def create(conn, params) do
    attrs =
      params
      |> Map.take(["name", "ownership_context", "notes"])
      |> Map.put("created_by", "user")

    case Counterparties.create_counterparty(attrs, actor_opts(conn)) do
      {:ok, cp} ->
        {:ok, loaded} = Counterparties.get_counterparty_with_preloads(cp.id)

        conn
        |> put_status(:created)
        |> json(CounterpartyJSON.counterparty_created(%{counterparty: loaded}))

      {:error, %Ecto.Changeset{} = changeset} ->
        render_changeset_error(conn, changeset)
    end
  end

  # --- PATCH /v1/counterparties/:id -------------------------------------

  operation(:update,
    summary: "Update a counterparty",
    description:
      "Patch a counterparty's name / notes / active flag. `active: false` soft-archives.",
    tags: ["Counterparties"],
    parameters: [@counterparty_id_param, @idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Update counterparty body", "application/json",
       BankWeb.OpenApi.Schemas.UpdateCounterpartyRequest},
    responses: %{
      200 =>
        {"Counterparty detail", "application/json", BankWeb.OpenApi.Schemas.CounterpartyResponse},
      404 => @not_found_ref,
      422 => @unprocessable_ref
    }
  )

  def update(conn, %{"id" => id} = params) do
    with {:ok, uuid} <- cast_uuid(id, "id"),
         {:ok, cp} <- fetch_counterparty(uuid) do
      attrs = Map.take(params, ["name", "ownership_context", "notes", "active"])

      case Counterparties.update_counterparty(cp, attrs, actor_opts(conn)) do
        {:ok, updated} ->
          {:ok, loaded} = Counterparties.get_counterparty_with_preloads(updated.id)

          conn
          |> put_status(:ok)
          |> json(CounterpartyJSON.counterparty_created(%{counterparty: loaded}))

        {:error, %Ecto.Changeset{} = changeset} ->
          render_changeset_error(conn, changeset)
      end
    else
      {:error, envelope} -> render_error(conn, envelope)
    end
  end

  # --- POST /v1/counterparties/:id/addresses ----------------------------

  operation(:add_address,
    summary: "Attach an address label to a counterparty",
    description: """
    Attach a chain address to an existing counterparty. Duplicates
    (same `(chain, address)` on an active label) return `409
    address_already_labelled`. Attaching to an archived counterparty
    returns `409 counterparty_archived`.
    """,
    tags: ["Counterparties"],
    parameters: [@counterparty_id_param, @idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Attach address body", "application/json", BankWeb.OpenApi.Schemas.AttachAddressRequest},
    responses: %{
      201 =>
        {"New address label", "application/json", BankWeb.OpenApi.Schemas.AddressLabelResponse},
      404 => @not_found_ref,
      409 => @conflict_ref,
      422 => @unprocessable_ref
    }
  )

  def add_address(conn, %{"id" => id} = params) do
    with {:ok, uuid} <- cast_uuid(id, "id"),
         {:ok, cp} <- fetch_counterparty(uuid) do
      attrs = Map.take(params, ["chain", "address", "alias", "role", "verified"])

      case Counterparties.attach_address(cp, attrs, actor_opts(conn)) do
        {:ok, label} ->
          conn
          |> put_status(:created)
          |> json(CounterpartyJSON.address_label_attached(%{address_label: label}))

        {:error, :archived} ->
          render_error(conn, %{
            status: :conflict,
            code: "counterparty_archived",
            message: "counterparty #{cp.id} is archived",
            hint: "unarchive the counterparty before attaching a new address",
            retryable: false
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          # Duplicate active (chain, address) is surfaced as 409 to
          # match the runtime-flow spec's "duplicate attachment
          # returns 409" requirement.
          if duplicate_address?(changeset) do
            render_error(conn, %{
              status: :conflict,
              code: "address_already_labelled",
              message: "(chain, address) is already attached to an active label",
              hint: "retire the existing label or reuse it instead",
              retryable: false
            })
          else
            render_changeset_error(conn, changeset)
          end
      end
    else
      {:error, envelope} -> render_error(conn, envelope)
    end
  end

  # --- POST /v1/counterparties/:id/evidence -----------------------------

  operation(:add_evidence,
    summary: "Pin an evidence artifact to a counterparty",
    description: """
    Append a new evidence artifact to the counterparty. Evidence is
    append-only: this endpoint never edits prior artifacts. Archived
    counterparties reject new evidence with `409
    counterparty_archived`.
    """,
    tags: ["Counterparties"],
    parameters: [@counterparty_id_param, @idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Evidence body", "application/json", BankWeb.OpenApi.Schemas.AddEvidenceRequest},
    responses: %{
      201 =>
        {"New evidence artifact", "application/json", BankWeb.OpenApi.Schemas.EvidenceResponse},
      404 => @not_found_ref,
      409 => @conflict_ref,
      422 => @unprocessable_ref
    }
  )

  def add_evidence(conn, %{"id" => id} = params) do
    with {:ok, uuid} <- cast_uuid(id, "id"),
         {:ok, cp} <- fetch_counterparty(uuid) do
      attrs = Map.take(params, ["kind", "content_uri", "source", "weight", "payload_hash"])

      case Counterparties.pin_evidence(cp, attrs, actor_opts(conn)) do
        {:ok, evidence} ->
          conn
          |> put_status(:created)
          |> json(CounterpartyJSON.evidence_pinned(%{evidence: evidence}))

        {:error, :archived} ->
          render_error(conn, %{
            status: :conflict,
            code: "counterparty_archived",
            message: "counterparty #{cp.id} is archived",
            hint: "unarchive the counterparty before attaching new evidence",
            retryable: false
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          render_changeset_error(conn, changeset)
      end
    else
      {:error, envelope} -> render_error(conn, envelope)
    end
  end

  # --- input parsing ----------------------------------------------------

  defp parse_filters(params) do
    active =
      case Map.get(params, "active") do
        nil -> nil
        "" -> nil
        "true" -> true
        "false" -> false
        _ -> :invalid
      end

    case active do
      :invalid ->
        {:error,
         %{
           status: :unprocessable_entity,
           code: "invalid_query",
           message: "invalid value for `active`",
           hint: ~s|must be "true" or "false"|,
           retryable: false
         }}

      _ ->
        {:ok, %{q: string_param(params, "q"), active: active}}
    end
  end

  defp parse_list_opts(params) do
    with {:ok, limit} <- parse_limit(params) do
      opts = [limit: limit]

      opts =
        case string_param(params, "cursor") do
          nil -> opts
          cursor -> Keyword.put(opts, :cursor, cursor)
        end

      {:ok, opts}
    end
  end

  defp parse_limit(params) do
    case Map.get(params, "limit") do
      nil ->
        {:ok, @list_limit_default}

      "" ->
        {:ok, @list_limit_default}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n > 0 and n <= @list_limit_max ->
            {:ok, n}

          _ ->
            {:error,
             %{
               status: :unprocessable_entity,
               code: "invalid_query",
               message: "invalid value for `limit`",
               hint: "must be a positive integer up to #{@list_limit_max}",
               retryable: false
             }}
        end
    end
  end

  defp string_param(params, key) do
    case Map.get(params, key) do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp cast_uuid(value, field) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} ->
        {:ok, uuid}

      :error ->
        {:error,
         %{
           status: :unprocessable_entity,
           code: "invalid_id",
           message: "`#{field}` must be a UUID",
           hint: nil,
           retryable: false
         }}
    end
  end

  defp fetch_counterparty(id) do
    case Counterparties.get_counterparty(id) do
      {:ok, cp} ->
        {:ok, cp}

      {:error, :not_found} ->
        {:error,
         %{
           status: :not_found,
           code: "not_found",
           message: "no counterparty with id=#{id}",
           hint: "check the id or confirm the counterparty still exists",
           retryable: false
         }}
    end
  end

  defp duplicate_address?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:chain, {_msg, opts}} -> opts[:constraint] == :unique
      {:address, {_msg, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  # --- response shaping -------------------------------------------------

  defp actor_opts(_conn) do
    # Auth wiring is deferred to the operator-auth issue; until then we
    # attribute manual writes to `:user` with no actor_id. Keeping the
    # extraction centralised so the swap-in is a single call site.
    [actor: :user]
  end

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

  # Some changeset error opts (notably `:type` on Ecto.Enum) carry
  # non-stringable tuples. Only substitute placeholders we can render
  # cleanly; the rest stay in the raw message template.
  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn
      {key, value}, acc when is_binary(value) or is_atom(value) or is_integer(value) ->
        String.replace(acc, "%{#{key}}", to_string(value))

      _, acc ->
        acc
    end)
  end
end
