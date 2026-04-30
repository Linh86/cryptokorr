defmodule BankWeb.Plugs.VerifyAPIKey do
  @moduledoc """
  Bearer-token authentication for `/v1` (#218b).

  Pulls `Authorization: Bearer cb_<body>` off the request, verifies
  it via `Bank.APIKeys.verify_key/1`, and populates
  `conn.assigns.current_scope` so downstream `Plugs.RequireRole`
  and controllers can authorize without re-querying.

  ## current_scope shape

      %{
        user: nil,
        workspace: %Workspace{},
        membership: nil,
        role: api_key.role,
        api_key: %APIKey{}
      }

  Mirrors the LiveView session shape from #157 / #159a in every
  field that authorization reads (`workspace`, `role`), and
  diverges where the request is machine-, not user-, attributable
  (`user: nil`, `membership: nil`, `api_key: %APIKey{}`).

  ## Failure modes

  All map to a generic 401 with a single error code on the wire so
  an attacker cannot distinguish "no such prefix" from "bad
  secret" by response shape:

    * No `authorization` header → `missing_authorization`.
    * Header present but not `Bearer ...` → `invalid_authorization_scheme`.
    * Bearer token does not match `cb_<body>` shape → `invalid_credentials`.
    * Prefix lookup misses, hash mismatches, key is revoked or
      expired → `invalid_credentials`.

  All four `verify_key` error reasons (`:not_found`,
  `:hash_mismatch`, `:revoked`, `:expired`) collapse to
  `invalid_credentials` on the wire. Distinct internal reasons are
  preserved in `Logger.warning` for operator triage.
  """

  import Plug.Conn

  require Logger

  alias Bank.APIKeys

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, presented} <- extract_bearer(conn),
         {:ok, api_key, workspace} <- APIKeys.verify_key(presented) do
      assign(conn, :current_scope, %{
        user: nil,
        workspace: workspace,
        membership: nil,
        role: api_key.role,
        api_key: api_key
      })
    else
      {:error, scheme_error}
      when scheme_error in [:missing_authorization, :invalid_authorization_scheme] ->
        halt_with(conn, Atom.to_string(scheme_error))

      {:error, verify_error}
      when verify_error in [:malformed, :not_found, :hash_mismatch, :revoked, :expired] ->
        Logger.warning(
          "BankWeb.Plugs.VerifyAPIKey: rejecting from #{peer_for_log(conn)} (#{verify_error})"
        )

        halt_with(conn, "invalid_credentials")
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:error, :missing_authorization}

      ["Bearer " <> token] when byte_size(token) > 0 ->
        {:ok, token}

      [_other] ->
        {:error, :invalid_authorization_scheme}

      _multiple ->
        {:error, :invalid_authorization_scheme}
    end
  end

  defp halt_with(conn, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, Jason.encode!(%{error: %{code: code}}))
    |> halt()
  end

  defp peer_for_log(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      other -> inspect(other)
    end
  end
end
