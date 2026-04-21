defmodule BankWeb.Internal.TelegramWebhookController do
  @moduledoc """
  Ingress endpoint for Telegram updates
  (`POST /internal/telegram/webhook`, issues #69 + #71 + #72).

  Responsibilities at this boundary:

    * Hand the JSON body to `Bank.Telegram.Update` for normalization.
      Anything that does not fit a recognised variant is logged at
      `:debug` and ACKed as `ignored_update` (no retry).
    * Authorize the actor via `Bank.Telegram.Config.authorize/2`.
      Unknown users, wrong chats, disabled bot → ACK as
      `ignored_sender` at `:info`. We do NOT surface 401/403 here
      because Telegram would retry the update.
    * For a `{:text_message, ...}` update from an authorized
      operator, hand off to `Bank.Telegram.Commands` (#71) to
      classify and produce a reply, which is sent via
      `Bank.Telegram.Transport.send_message/3`. Free-form
      non-command text is accepted but produces no reply.
    * For a `{:callback_query, ...}` update from an authorized
      operator, delegate to `Bank.Telegram.Callbacks.handle/2` to
      verify the signed callback token and apply the decision
      mutation (#72), then acknowledge the button press through
      `Bank.Telegram.Transport.answer_callback_query/2` so the
      Telegram UI stops spinning. Failures from the ack call are
      swallowed — we still 200 this request so Telegram's retry
      loop stops at the first delivery.
    * Even when a callback_query comes from an *unauthorized*
      caller, we silently close the Telegram spinner (no text) so
      the button in that user's UI does not spin forever. No
      action is taken, only the spinner is cleared.
    * Respond 200 on everything we accept or deliberately ignore so
      Telegram's retry loop stops at the first delivery.

  The plug `BankWeb.Plugs.VerifyTelegramWebhook` sits in front of
  this endpoint and enforces the
  `X-Telegram-Bot-Api-Secret-Token` header; by the time the
  controller runs, the webhook secret is already verified.
  """

  use BankWeb, :controller
  require Logger

  alias Bank.Telegram.Callbacks
  alias Bank.Telegram.Commands
  alias Bank.Telegram.Config, as: TelegramConfig
  alias Bank.Telegram.Transport
  alias Bank.Telegram.Update

  def webhook(conn, params) do
    params
    |> Update.from_telegram_json()
    |> dispatch(conn)
  end

  defp dispatch({:text_message, msg}, conn) do
    case TelegramConfig.authorize(msg.user_id, msg.chat_id) do
      {:ok, operator} ->
        handle_text(msg, operator, conn)

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
      {:ok, operator} ->
        text = handle_callback(operator, cb)
        answer_callback_query(cb.query_id, text)
        ack(conn, "callback_query_accepted")

      {:error, reason} ->
        Logger.info(
          "BankWeb.Internal.TelegramWebhookController: ignoring callback from unauthorized actor " <>
            "(user_id=#{cb.user_id} chat_id=#{cb.chat_id} reason=#{reason})"
        )

        answer_callback_query(cb.query_id, nil)
        ack(conn, "ignored_sender")
    end
  end

  defp dispatch({:ignored, reason}, conn) do
    Logger.debug("BankWeb.Internal.TelegramWebhookController: ignoring update (#{reason})")
    ack(conn, "ignored_update")
  end

  defp handle_text(msg, operator, conn) do
    case Commands.parse(msg.text) do
      :not_a_command ->
        # Non-command text is accepted but produces no reply. Free-
        # form chat interaction is an explicit non-goal in #71.
        ack(conn, "text_message_accepted")

      parsed ->
        {:ok, reply} = Commands.handle(parsed, operator)

        case Transport.send_message(msg.chat_id, reply) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            # Best-effort reply — we still 200-ACK to Telegram so
            # its retry loop does not hammer us with the same
            # inbound update.
            Logger.warning(
              "BankWeb.Internal.TelegramWebhookController: command reply to " <>
                "chat_id=#{msg.chat_id} failed: #{inspect(reason)}"
            )
        end

        ack(conn, "command_handled")
    end
  end

  defp handle_callback(operator, cb) do
    case Callbacks.handle(operator, cb) do
      {:ok, text} -> text
      {:error, _reason, text} -> text
    end
  end

  defp answer_callback_query(query_id, text) do
    opts = if is_binary(text), do: [text: text], else: []

    case Transport.answer_callback_query(query_id, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "BankWeb.Internal.TelegramWebhookController: answer_callback_query failed " <>
            "(query_id=#{query_id} reason=#{inspect(reason)})"
        )

        :ok
    end
  end

  defp ack(conn, status_str) do
    conn
    |> put_status(:ok)
    |> json(%{status: status_str})
  end
end
