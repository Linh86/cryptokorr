defmodule BankWeb.Plugs.VerifyAdapterAuth do
  @moduledoc """
  Gatekeeper for the internal adapter callback endpoint.

  The TypeScript adapter posts to `POST /internal/adapter/callback`
  over a private network. This plug enforces a bearer secret that both
  sides agree on via `:bank, Bank.AdapterClient, callback_secret`
  config.

  This is the *callback* direction of the trust boundary. The opposite
  direction — Phoenix → adapter on `/dispatch/*` — uses a separate
  `:dispatch_secret` so each direction can be rotated independently
  and a leak in one direction does not authenticate the other.

  Transport security is operator-supplied (see `docs/security.md`):
  Phoenix can be fronted by a TLS-terminating ingress, and the bearer
  check here remains as defense in depth regardless.

  ## Behaviour

    * No `authorization` header → 401 `missing_authorization`.
    * Header present but not `Bearer <secret>` → 401
      `invalid_authorization_scheme`.
    * Bearer secret mismatch → 401 `invalid_credentials`.
    * Valid → conn untouched.

  The comparison uses `Plug.Crypto.secure_compare/2` so a wrong token
  does not leak length information via timing.

  The expected secret is resolved at request time, not compile time,
  so runtime config changes are picked up without restart.
  """

  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, presented} <- extract_bearer(conn),
         {:ok, expected} <- expected_secret(),
         true <- Plug.Crypto.secure_compare(presented, expected) do
      conn
    else
      :no_expected_secret ->
        Logger.error(
          "BankWeb.Plugs.VerifyAdapterAuth: no :callback_secret configured; refusing callback"
        )

        halt_with(conn, "server_misconfigured")

      {:error, reason} ->
        Logger.warning(
          "BankWeb.Plugs.VerifyAdapterAuth: rejecting callback from #{peer_for_log(conn)} (#{reason})"
        )

        halt_with(conn, reason)

      false ->
        Logger.warning(
          "BankWeb.Plugs.VerifyAdapterAuth: bearer mismatch from #{peer_for_log(conn)}"
        )

        halt_with(conn, "invalid_credentials")
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:error, "missing_authorization"}

      ["Bearer " <> token] when byte_size(token) > 0 ->
        {:ok, token}

      [_other] ->
        {:error, "invalid_authorization_scheme"}

      _multiple ->
        {:error, "invalid_authorization_scheme"}
    end
  end

  defp expected_secret do
    case Application.get_env(:bank, Bank.AdapterClient) do
      nil ->
        :no_expected_secret

      config ->
        case Keyword.get(config, :callback_secret) do
          value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
          _ -> :no_expected_secret
        end
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
