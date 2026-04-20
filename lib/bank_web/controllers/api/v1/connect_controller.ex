defmodule BankWeb.API.V1.ConnectController do
  @moduledoc """
  `/v1/connect` — browser-initiated smart-account connect flow.

  The v0.1 delegation path flows through the adapter callback. This
  controller is the v1.1 scaffolding for the browser-native flow
  described in `docs/wallet-connect.md`: the JS hook at
  `assets/js/hooks/wallet_connect.js` builds a signed delegation
  payload and POSTs it here. The controller writes an audit event
  and hands off to `Bank.Delegations.request_connect/1`, which is a
  stub until the adapter exposes `POST /dispatch/grant_delegation`.

  The endpoint is intentionally lenient on payload shape during the
  stub phase; it requires the three fields that identify the smart
  account + signer + chain, and carries everything else through on
  the audit trail.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Bank.Delegations
  alias OpenApiSpex.Reference

  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @unprocessable_ref %Reference{"$ref": "#/components/responses/UnprocessableEntity"}

  # --- POST /v1/connect/smart_account -------------------------------------

  operation(:request,
    summary: "Request a browser-initiated smart-account connect",
    description: """
    v1.1 scaffolding for the browser-native connect flow (see
    `docs/wallet-connect.md`). The synchronous response is
    `202 accepted` with a `note` stating that adapter dispatch is
    stubbed: the runtime persists the connect intent and emits an
    audit event, but `Bank.Delegations.request_connect/1` does NOT
    yet grant a delegation on-chain. Chain ids other than `8453`
    (Base) and `84532` (Base Sepolia) return `422
    unsupported_chain`.
    """,
    tags: ["Connect"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"Connect smart-account body", "application/json",
       BankWeb.OpenApi.Schemas.ConnectSmartAccountRequest},
    responses: %{
      202 =>
        {"Connect accepted (adapter dispatch stubbed)", "application/json",
         BankWeb.OpenApi.Schemas.ConnectSmartAccountResponse},
      422 => @unprocessable_ref
    }
  )

  def request(conn, params) do
    with {:ok, payload} <- validate_payload(params),
         {:ok, :accepted} <- Delegations.request_connect(payload) do
      conn
      |> put_status(:accepted)
      |> json(%{
        status: "accepted",
        smart_account_id: payload["smart_account_id"],
        note: "Adapter dispatch is stubbed in v1.1 — see docs/wallet-connect.md."
      })
    else
      {:error, {:missing, field}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_body", message: "#{field} is required"}})

      {:error, :unsupported_chain} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "unsupported_chain",
            message: "chain_id must be 8453 (Base) or 84532 (Base Sepolia)"
          }
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "connect_failed", message: inspect(reason)}})
    end
  end

  defp validate_payload(params) do
    with {:ok, sa_id} <- require_string(params, "smart_account_id"),
         {:ok, account} <- require_string(params, "account"),
         {:ok, chain_id} <- require_integer(params, "chain_id") do
      {:ok,
       %{
         "smart_account_id" => sa_id,
         "account" => account,
         "chain_id" => chain_id,
         "delegation_payload" => Map.get(params, "delegation_payload")
       }}
    end
  end

  defp require_string(params, field) do
    case Map.get(params, field) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing, field}}
    end
  end

  defp require_integer(params, field) do
    case Map.get(params, field) do
      v when is_integer(v) -> {:ok, v}
      _ -> {:error, {:missing, field}}
    end
  end
end
