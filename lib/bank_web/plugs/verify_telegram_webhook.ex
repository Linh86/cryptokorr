defmodule BankWeb.Plugs.VerifyTelegramWebhook do
  @moduledoc """
  Gatekeeper for `POST /internal/telegram/webhook` (issue #69).

  Telegram does not sign webhook payloads the way a Stripe or GitHub
  webhook does. The Bot API's recommended auth mechanism is a shared
  secret: when the operator registers the webhook URL via
  `setWebhook` with a `secret_token` parameter, Telegram echoes that
  value back on every inbound update in the
  `X-Telegram-Bot-Api-Secret-Token` header. This plug validates that
  header against `Bank.Telegram.Config.webhook_secret/0`.

  Unlike `BankWeb.Plugs.VerifyAdapterAuth` (issue #51), the expected
  secret comes from the Telegram config boundary rather than the
  adapter boundary, and the header name is Telegram-specific (not
  `Authorization: Bearer …`).

  Comparison is constant-time via `Plug.Crypto.secure_compare/2`.

  ## Behaviour

    * Missing `X-Telegram-Bot-Api-Secret-Token` → 401
      `missing_secret_token`.
    * Header present but does not match → 401 `invalid_secret_token`.
    * Bot disabled → 401 `bot_disabled`. We refuse the callback
      rather than silently 404-ing so an operator who accidentally
      still has Telegram pointing at the webhook gets a loud signal.
    * Webhook secret not configured → 401 `server_misconfigured`.
    * Config shape broken → 401 `server_misconfigured`.
    * Valid → conn untouched.
  """

  import Plug.Conn
  require Logger

  alias Bank.Telegram.Config
  alias Bank.Telegram.Telemetry, as: TelegramTelemetry

  @header_name "x-telegram-bot-api-secret-token"

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, presented} <- extract_secret(conn),
         {:ok, expected} <- Config.webhook_secret(),
         true <- Plug.Crypto.secure_compare(presented, expected) do
      TelegramTelemetry.webhook_auth(:ok)
      conn
    else
      :missing ->
        log_reject(conn, "missing_secret_token")
        TelegramTelemetry.webhook_auth(:missing_secret_token)
        halt_with(conn, "missing_secret_token")

      {:error, :bot_disabled} ->
        Logger.warning("BankWeb.Plugs.VerifyTelegramWebhook: refusing webhook — bot disabled")
        TelegramTelemetry.webhook_auth(:bot_disabled)
        halt_with(conn, "bot_disabled")

      {:error, :webhook_secret_not_configured} ->
        Logger.error(
          "BankWeb.Plugs.VerifyTelegramWebhook: no :webhook_secret configured; refusing webhook"
        )

        TelegramTelemetry.webhook_auth(:server_misconfigured)
        halt_with(conn, "server_misconfigured")

      {:error, :invalid_config} ->
        Logger.error(
          "BankWeb.Plugs.VerifyTelegramWebhook: Telegram config shape is invalid; refusing webhook"
        )

        TelegramTelemetry.webhook_auth(:server_misconfigured)
        halt_with(conn, "server_misconfigured")

      false ->
        log_reject(conn, "invalid_secret_token")
        TelegramTelemetry.webhook_auth(:invalid_secret_token)
        halt_with(conn, "invalid_secret_token")
    end
  end

  defp extract_secret(conn) do
    case get_req_header(conn, @header_name) do
      [value] when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> :missing
    end
  end

  defp log_reject(conn, reason) do
    Logger.warning(
      "BankWeb.Plugs.VerifyTelegramWebhook: rejecting webhook from #{peer_for_log(conn)} (#{reason})"
    )
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
