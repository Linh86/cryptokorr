defmodule BankWeb.Internal.TelegramWebhookController do
  @moduledoc """
  Ingress endpoint for Telegram updates
  (`POST /internal/telegram/webhook`, issue #69).

  Responsibilities at this boundary:

    * Hand the JSON body to `Bank.Telegram.Update` for normalization.
      Anything that does not fit a recognised variant is logged at
      `:debug` and ACKed as `ignored_update` (no retry).
    * Authorize the actor via `Bank.Telegram.Config.authorize/2`.
      Unknown users, wrong chats, disabled bot → ACK as
      `ignored_sender` at `:info`. We do NOT surface 401/403 here
      because Telegram would retry the update.
    * Respond 200 on everything we accept or deliberately ignore so
      Telegram's retry loop stops at the first delivery.

  This controller does not dispatch commands, approvals, or any
  state-changing action. Those land in later issues of epic #54 and
  consume the normalized shape from `Bank.Telegram.Update` plus the
  authenticated operator.

  The plug `BankWeb.Plugs.VerifyTelegramWebhook` sits in front of
  this endpoint and enforces the
  `X-Telegram-Bot-Api-Secret-Token` header; by the time the
  controller runs, the webhook secret is already verified.
  """

  use BankWeb, :controller
  require Logger

  alias Bank.Telegram.Config, as: TelegramConfig
  alias Bank.Telegram.Update

  def webhook(conn, params) do
    params
    |> Update.from_telegram_json()
    |> dispatch(conn)
  end

  defp dispatch({:text_message, msg}, conn) do
    case TelegramConfig.authorize(msg.user_id, msg.chat_id) do
      {:ok, _operator} ->
        ack(conn, "text_message_accepted")

      {:error, reason} ->
        Logger.info(
          "BankWeb.Internal.TelegramWebhookController: ignoring text from unauthorized actor " <>
            "(user_id=#{msg.user_id} chat_id=#{msg.chat_id} reason=#{reason})"
        )

        ack(conn, "ignored_sender")
    end
  end

  defp dispatch({:callback_query, cb}, conn) do
    case TelegramConfig.authorize(cb.user_id, cb.chat_id) do
      {:ok, _operator} ->
        ack(conn, "callback_query_accepted")

      {:error, reason} ->
        Logger.info(
          "BankWeb.Internal.TelegramWebhookController: ignoring callback from unauthorized actor " <>
            "(user_id=#{cb.user_id} chat_id=#{cb.chat_id} reason=#{reason})"
        )

        ack(conn, "ignored_sender")
    end
  end

  defp dispatch({:ignored, reason}, conn) do
    Logger.debug("BankWeb.Internal.TelegramWebhookController: ignoring update (#{reason})")
    ack(conn, "ignored_update")
  end

  defp ack(conn, status_str) do
    conn
    |> put_status(:ok)
    |> json(%{status: status_str})
  end
end
