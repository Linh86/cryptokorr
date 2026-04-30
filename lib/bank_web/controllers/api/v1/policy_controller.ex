defmodule BankWeb.API.V1.PolicyController do
  @moduledoc """
  `/v1/policies` — versioned policy rule management.

  Rules are never mutated in place. A `revise` writes a new version and
  marks the prior one `superseded`; in-flight evaluations continue using
  their captured policy snapshot.

  Endpoints:

    * `GET  /v1/policies`               — list (active / superseded / archived)
    * `POST /v1/policies`               — create a new rule
    * `POST /v1/policies/:id/revise`    — write new version
    * `POST /v1/policies/:id/archive`   — archive rule

  Write paths delegate to `Bank.Policies`, which owns the transaction
  boundary and audit composition. The controller is responsible for
  request parsing and response shaping.

  `actor` / `actor_id` fall back to `:user` / `nil` today; a real
  auth plug will populate them on the connection and the controller
  will forward those values into the context.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Bank.Policies
  alias BankWeb.API.V1.PolicyJSON
  alias OpenApiSpex.{Parameter, Reference, Schema}

  @list_limit_default 50
  @list_limit_max 500
  @states ~w(draft active superseded archived)
  @rule_types ~w(amount_limit rolling_spend_cap slippage_ceiling allowed_router allowed_asset allowed_chain autonomy_tier time_window)

  @id_ref %Reference{"$ref": "#/components/schemas/Id"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @unauthorized_ref %Reference{"$ref": "#/components/responses/Unauthorized"}
  @forbidden_ref %Reference{"$ref": "#/components/responses/Forbidden"}
  @not_found_ref %Reference{"$ref": "#/components/responses/NotFound"}
  @conflict_ref %Reference{"$ref": "#/components/responses/Conflict"}
  @unprocessable_ref %Reference{"$ref": "#/components/responses/UnprocessableEntity"}

  @policy_id_param %Parameter{
    name: :id,
    in: :path,
    required: true,
    description: "Opaque runtime-assigned policy rule id (UUID).",
    schema: @id_ref
  }

  @list_query_params [
    %Parameter{
      name: :state,
      in: :query,
      required: false,
      description: "Filter by policy-rule state.",
      schema: %Schema{type: :string, enum: ~w(draft active superseded archived)}
    },
    %Parameter{
      name: :rule_type,
      in: :query,
      required: false,
      description: "Filter by rule type.",
      schema: %Schema{
        type: :string,
        enum:
          ~w(amount_limit rolling_spend_cap slippage_ceiling allowed_router allowed_asset allowed_chain autonomy_tier time_window)
      }
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

  # --- GET /v1/policies -------------------------------------------------

  operation(:index,
    summary: "List policy rules",
    description:
      "Paged list of policy rules, filterable by state and rule type. " <>
        "Returns the full supersession chain when `state=superseded` is included.",
    tags: ["Policies"],
    parameters: [@request_id_in_ref | @list_query_params],
    responses: %{
      200 => {"Policy rule list", "application/json", BankWeb.OpenApi.Schemas.PolicyListResponse},
      401 => @unauthorized_ref,
      422 => @unprocessable_ref
    }
  )

  def index(conn, params) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, filters} <- parse_filters(params),
         {:ok, opts} <- parse_list_opts(params) do
      # Workspace-scope the listing so a viewer in workspace A
      # cannot enumerate workspace B's policy ids (#159b).
      page = Policies.list_rules(filters, Keyword.put(opts, :workspace_id, workspace_id))

      conn
      |> put_status(:ok)
      |> json(PolicyJSON.index(page))
    else
      {:error, envelope} -> render_error(conn, envelope)
    end
  end

  # --- POST /v1/policies ------------------------------------------------

  operation(:create,
    summary: "Create a policy rule",
    description:
      "Creates a new policy rule. `rule_type` is required; `params` / `scope` shape " <>
        "depends on the rule type and is validated at the context boundary.",
    tags: ["Policies"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Create policy body", "application/json", BankWeb.OpenApi.Schemas.CreatePolicyRequest},
    responses: %{
      201 => {"New policy rule", "application/json", BankWeb.OpenApi.Schemas.PolicyResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      422 => @unprocessable_ref
    }
  )

  def create(conn, params) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, attrs} <- parse_create_attrs(params) do
      # Stamp workspace_id from current_scope via the trusted opts
      # channel — never from request params. The context's
      # `stamp_workspace_id/2` strips any body-supplied workspace_id
      # defensively (#159b).
      opts = Keyword.put(actor_opts(conn), :workspace_id, workspace_id)

      case Policies.create_rule(attrs, opts) do
        {:ok, rule} ->
          conn
          |> put_status(:created)
          |> json(PolicyJSON.rule_created(%{rule: rule}))

        {:error, %Ecto.Changeset{} = changeset} ->
          render_changeset_error(conn, changeset)
      end
    else
      {:error, envelope} -> render_error(conn, envelope)
    end
  end

  # --- POST /v1/policies/:id/revise ------------------------------------

  operation(:revise,
    summary: "Revise a policy rule",
    description: """
    Writes a new version of an active rule. The prior version is
    marked `superseded`; in-flight evaluations continue using their
    captured policy snapshot. `rule_type` cannot change across a
    revision. Archived or already-superseded rules return `409
    not_active`.
    """,
    tags: ["Policies"],
    parameters: [@policy_id_param, @idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Revise policy body", "application/json", BankWeb.OpenApi.Schemas.RevisePolicyRequest},
    responses: %{
      201 =>
        {"Successor policy rule", "application/json", BankWeb.OpenApi.Schemas.PolicyResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      404 => @not_found_ref,
      409 => @conflict_ref,
      422 => @unprocessable_ref
    }
  )

  def revise(conn, %{"id" => id} = params) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, uuid} <- cast_uuid(id, "id"),
         {:ok, rule} <- fetch_rule(uuid, workspace_id),
         {:ok, attrs} <- parse_revise_attrs(params) do
      case Policies.revise_rule(rule, attrs, actor_opts(conn)) do
        {:ok, successor} ->
          conn
          |> put_status(:created)
          |> json(PolicyJSON.rule_created(%{rule: successor}))

        {:error, :not_active} ->
          render_error(conn, %{
            status: :conflict,
            code: "not_active",
            message: "only an `:active` rule can be revised",
            hint: "fetch the current active tip of the supersession chain",
            retryable: false
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          render_changeset_error(conn, changeset)
      end
    else
      {:error, envelope} -> render_error(conn, envelope)
    end
  end

  # --- POST /v1/policies/:id/archive -----------------------------------

  operation(:archive,
    summary: "Archive a policy rule",
    description:
      "Soft-deactivate a policy rule. Only active rules can be archived; " <>
        "already-superseded / already-archived rules return `409 not_active`.",
    tags: ["Policies"],
    parameters: [@policy_id_param, @idempotency_key_ref, @request_id_in_ref],
    responses: %{
      200 => {"Archived policy rule", "application/json", BankWeb.OpenApi.Schemas.PolicyResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      404 => @not_found_ref,
      409 => @conflict_ref
    }
  )

  def archive(conn, %{"id" => id}) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, uuid} <- cast_uuid(id, "id"),
         {:ok, rule} <- fetch_rule(uuid, workspace_id) do
      case Policies.archive_rule(rule, actor_opts(conn)) do
        {:ok, archived} ->
          conn
          |> put_status(:ok)
          |> json(PolicyJSON.rule_archived(%{rule: archived}))

        {:error, :not_active} ->
          render_error(conn, %{
            status: :conflict,
            code: "not_active",
            message: "only an `:active` rule can be archived",
            hint: "rules that are already superseded or archived stay where they are",
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
    with {:ok, state} <- parse_atom_enum(params, "state", @states, "state"),
         {:ok, rule_type} <- parse_atom_enum(params, "rule_type", @rule_types, "rule_type") do
      {:ok, %{state: state, rule_type: rule_type}}
    end
  end

  defp parse_create_attrs(params) do
    with :ok <- require_string(params, "rule_type"),
         true <- Map.get(params, "rule_type") in @rule_types || rule_type_error() do
      attrs =
        %{
          "rule_type" => Map.get(params, "rule_type"),
          "params" => Map.get(params, "params") || %{},
          "scope" => Map.get(params, "scope") || %{},
          "priority" => Map.get(params, "priority") || 0,
          "created_by" => Map.get(params, "created_by") || "user",
          "state" => Map.get(params, "state") || "active"
        }

      case Map.get(params, "state") do
        nil ->
          {:ok, attrs}

        s when s in @states ->
          {:ok, attrs}

        _ ->
          {:error, invalid_body(~s|`state` must be one of #{inspect(@states)}|)}
      end
    else
      {:error, envelope} -> {:error, envelope}
      other -> other
    end
  end

  defp parse_revise_attrs(params) do
    # `rule_type` is not editable via revise — it is carried forward
    # from the prior row (see `PolicyRule.supersede/2`). We drop it
    # silently rather than erroring so idempotent clients that PUT the
    # full rule don't need to strip it.
    attrs =
      %{
        "params" => Map.get(params, "params") || %{},
        "scope" => Map.get(params, "scope") || %{},
        "priority" => Map.get(params, "priority") || 0,
        "created_by" => Map.get(params, "created_by") || "user"
      }

    case Map.get(params, "state") do
      nil ->
        {:ok, attrs}

      s when s in @states ->
        {:ok, Map.put(attrs, "state", s)}

      _ ->
        {:error, invalid_body(~s|`state` must be one of #{inspect(@states)}|)}
    end
  end

  defp parse_atom_enum(params, key, allowed, display_key) do
    value = Map.get(params, key)

    cond do
      value in [nil, ""] ->
        {:ok, nil}

      is_binary(value) and value in allowed ->
        {:ok, String.to_existing_atom(value)}

      true ->
        {:error,
         %{
           status: :unprocessable_entity,
           code: "invalid_query",
           message: "invalid value for `#{display_key}`",
           hint: ~s|must be one of #{inspect(allowed)}|,
           retryable: false
         }}
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

  defp require_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> :ok
      _ -> {:error, invalid_body("missing `#{key}`")}
    end
  end

  defp rule_type_error do
    {:error, invalid_body(~s|`rule_type` must be one of #{inspect(@rule_types)}|)}
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

  defp fetch_rule(id, workspace_id) when is_binary(workspace_id) do
    case Policies.get_rule_in_workspace(id, workspace_id) do
      {:ok, rule} ->
        {:ok, rule}

      {:error, :not_found} ->
        # Cross-workspace ids return :not_found — same shape as
        # genuinely-unknown so a caller cannot probe across
        # tenants (#159b).
        {:error,
         %{
           status: :not_found,
           code: "not_found",
           message: "no policy rule with id=#{id}",
           hint: "check the id or confirm the rule still exists",
           retryable: false
         }}
    end
  end

  defp invalid_body(hint) do
    %{
      status: :unprocessable_entity,
      code: "invalid_body",
      message: "request body failed validation",
      hint: hint,
      retryable: false
    }
  end

  # --- response shaping -------------------------------------------------

  defp actor_opts(_conn) do
    [actor: :user, actor_id: nil]
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

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn
      {key, value}, acc when is_binary(value) or is_atom(value) or is_integer(value) ->
        String.replace(acc, "%{#{key}}", to_string(value))

      _, acc ->
        acc
    end)
  end
end
