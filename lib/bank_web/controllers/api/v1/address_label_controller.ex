defmodule BankWeb.API.V1.AddressLabelController do
  @moduledoc """
  `/v1/address_labels` — patch labels attached to a counterparty.

  The address value itself is immutable; a wrong address is retired and
  replaced with a new label. Setting `retired: true` routes through the
  dedicated retirement path in the context.

  Endpoints:

    * `PATCH /v1/address_labels/:id` — alias / role / verified / retired

  Audit is emitted by `Bank.Counterparties.update_address_label/3`
  (either `address_label.updated` or `address_label.retired` depending
  on the path taken). This module only parses input and shapes the
  response.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import Ecto.Query

  alias Bank.Counterparties
  alias Bank.Counterparties.{AddressLabel, Counterparty}
  alias Bank.Repo
  alias BankWeb.API.V1.CounterpartyJSON
  alias OpenApiSpex.{Parameter, Reference}

  @id_ref %Reference{"$ref": "#/components/schemas/Id"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @unauthorized_ref %Reference{"$ref": "#/components/responses/Unauthorized"}
  @forbidden_ref %Reference{"$ref": "#/components/responses/Forbidden"}
  @not_found_ref %Reference{"$ref": "#/components/responses/NotFound"}
  @conflict_ref %Reference{"$ref": "#/components/responses/Conflict"}
  @unprocessable_ref %Reference{"$ref": "#/components/responses/UnprocessableEntity"}

  @label_id_param %Parameter{
    name: :id,
    in: :path,
    required: true,
    description: "Opaque runtime-assigned address label id (UUID).",
    schema: @id_ref
  }

  operation(:update,
    summary: "Update an address label",
    description: """
    Patch the label's alias / role / verified flag, or retire it.
    The address value itself is immutable — wrong addresses require
    retiring the label and attaching a new one.
    """,
    tags: ["AddressLabels"],
    parameters: [@label_id_param, @idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Update address label body", "application/json",
       BankWeb.OpenApi.Schemas.UpdateAddressLabelRequest},
    responses: %{
      200 =>
        {"Updated address label", "application/json",
         BankWeb.OpenApi.Schemas.AddressLabelResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      404 => @not_found_ref,
      409 => @conflict_ref,
      422 => @unprocessable_ref
    }
  )

  def update(conn, %{"id" => id} = params) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, uuid} <- cast_uuid(id),
         {:ok, label} <- fetch_label(uuid, workspace_id) do
      attrs = Map.take(params, ["alias", "role", "verified", "retired"])

      case Counterparties.update_address_label(label, attrs, actor_opts(conn)) do
        {:ok, updated} ->
          conn
          |> put_status(:ok)
          |> json(CounterpartyJSON.address_label_updated(%{address_label: updated}))

        {:error, :already_retired} ->
          render_error(conn, %{
            status: :conflict,
            code: "already_retired",
            message: "address label #{label.id} is already retired",
            hint: "retired labels are immutable; attach a new label if needed",
            retryable: false
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          render_changeset_error(conn, changeset)
      end
    else
      {:error, envelope} -> render_error(conn, envelope)
    end
  end

  # --- helpers ---------------------------------------------------------

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} ->
        {:ok, uuid}

      :error ->
        {:error,
         %{
           status: :unprocessable_entity,
           code: "invalid_id",
           message: "`id` must be a UUID",
           hint: nil,
           retryable: false
         }}
    end
  end

  # Workspace scoping (#159b): the label is scoped via its parent
  # counterparty's `workspace_id`. Cross-workspace ids return
  # `:not_found` rather than `:forbidden` so a caller cannot probe
  # for label ids in another tenant.
  defp fetch_label(id, workspace_id) when is_binary(workspace_id) do
    query =
      from(l in AddressLabel,
        join: c in Counterparty,
        on: l.counterparty_id == c.id,
        where: l.id == ^id and c.workspace_id == ^workspace_id
      )

    case Repo.one(query) do
      nil ->
        {:error,
         %{
           status: :not_found,
           code: "not_found",
           message: "no address label with id=#{id}",
           hint: "check the id or confirm the label still exists",
           retryable: false
         }}

      %AddressLabel{} = label ->
        {:ok, label}
    end
  end

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
