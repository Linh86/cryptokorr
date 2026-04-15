defmodule BankWeb.API.V1.AuditController do
  @moduledoc """
  `/v1/audit` — filterable append-only audit trail.

  This is not an analytics surface. Aggregations live elsewhere. Event
  records cannot be edited via any endpoint.

  ## `GET /v1/audit`

  Supported query parameters (all optional):

    * `intent_id`     — uuid; matches `correlation_id`
    * `subject_type`  — e.g. `agent_intent`, `decision_envelope`
    * `subject_id`    — opaque id (typically uuid, may be a smart
      account id or on-chain address)
    * `event_type`    — e.g. `intent.submitted`
    * `from`, `to`    — ISO 8601 timestamps (inclusive)
    * `cursor`        — opaque cursor from a prior page
    * `limit`         — page size, default 50, max 500
    * `order`         — `asc` (default) or `desc`

  Response:

      {
        "data": [ ...audit event objects... ],
        "page": { "next_cursor": "..." | null }
      }
  """

  use BankWeb, :controller

  alias Bank.Audit
  alias BankWeb.API.V1.AuditJSON

  action_fallback BankWeb.API.V1.FallbackController

  def index(conn, params) do
    with {:ok, filters} <- parse_filters(params),
         {:ok, opts} <- parse_opts(params) do
      page = Audit.list_events(filters, opts)

      conn
      |> put_status(:ok)
      |> json(AuditJSON.index(page))
    else
      {:error, {:invalid, field, reason}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "invalid_query",
            message: "invalid value for `#{field}`",
            hint: reason,
            retryable: false
          }
        })
    end
  end

  # --- parsing -----------------------------------------------------------

  defp parse_filters(params) do
    with {:ok, intent_id} <- parse_uuid(params, "intent_id"),
         {:ok, from} <- parse_ts(params, "from"),
         {:ok, to} <- parse_ts(params, "to") do
      {:ok,
       %{
         correlation_id: intent_id,
         subject_type: string_param(params, "subject_type"),
         # `subject_id` is polymorphic — most values are uuids, but
         # smart-account / on-chain subjects use opaque strings.
         subject_id: string_param(params, "subject_id"),
         event_type: string_param(params, "event_type"),
         from: from,
         to: to
       }}
    end
  end

  defp parse_opts(params) do
    with {:ok, limit} <- parse_limit(params),
         {:ok, order} <- parse_order(params) do
      opts =
        [limit: limit, order: order]
        |> maybe_put(:cursor, string_param(params, "cursor"))

      {:ok, opts}
    end
  end

  defp parse_uuid(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, {:invalid, key, "must be a valid UUID"}}
        end
    end
  end

  defp parse_ts(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> {:ok, dt}
          _ -> {:error, {:invalid, key, "must be an ISO 8601 timestamp"}}
        end
    end
  end

  defp parse_limit(params) do
    case Map.get(params, "limit") do
      nil ->
        {:ok, 50}

      "" ->
        {:ok, 50}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, {:invalid, "limit", "must be a positive integer"}}
        end
    end
  end

  defp parse_order(params) do
    case Map.get(params, "order") do
      nil -> {:ok, :asc}
      "" -> {:ok, :asc}
      "asc" -> {:ok, :asc}
      "desc" -> {:ok, :desc}
      _ -> {:error, {:invalid, "order", ~s|must be "asc" or "desc"|}}
    end
  end

  defp string_param(params, key) do
    case Map.get(params, key) do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> value
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
