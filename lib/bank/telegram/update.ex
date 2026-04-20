defmodule Bank.Telegram.Update do
  @moduledoc """
  Normalized representation of an inbound Telegram update
  (issue #69, epic #54).

  Telegram's `Update` object is a polymorphic JSON union with many
  fields (text messages, edits, channel posts, joins, inline queries,
  etc.). This module collapses it into the minimum shapes the bot
  actually needs to act on, so higher layers (commands, approvals,
  pause/resume) never see raw Telegram JSON.

  Recognized variants:

    * `{:text_message, %{update_id, user_id, chat_id, text,
      message_id}}` — a plain-text message or command in a chat.
      Command dispatch (e.g. `/status`, `/queue`, `/help`) lands in
      later issues; this module only normalises shape.
    * `{:callback_query, %{update_id, user_id, chat_id, query_id,
      message_id, data}}` — an inline-button press. `data` is the
      opaque callback token string to be passed to
      `Bank.Telegram.CallbackToken.verify/4` by the handler.

  Everything else (edits, channel posts, service messages, unknown
  kinds, payloads missing required fields) resolves to
  `{:ignored, reason}` so the ingress controller can ACK to Telegram
  (stopping retries) without processing.

  This module does not authorize the sender; authorization lives in
  `Bank.Telegram.Config.authorize/2` and is invoked by the
  controller after normalization.
  """

  @type update_id :: integer()
  @type text_message :: %{
          update_id: update_id(),
          user_id: integer(),
          chat_id: integer(),
          text: String.t(),
          message_id: integer()
        }
  @type callback_query :: %{
          update_id: update_id(),
          user_id: integer(),
          chat_id: integer(),
          query_id: String.t(),
          message_id: integer() | nil,
          data: String.t()
        }
  @type ignore_reason ::
          :malformed
          | :unsupported_kind
          | :non_text_or_missing_fields
          | :callback_missing_fields
          | :callback_without_chat

  @type t ::
          {:text_message, text_message()}
          | {:callback_query, callback_query()}
          | {:ignored, ignore_reason()}

  @doc """
  Normalize a raw Telegram update (decoded JSON as a map) into one
  of the recognised shapes or `{:ignored, reason}`.
  """
  @spec from_telegram_json(term()) :: t()
  def from_telegram_json(%{"update_id" => update_id} = raw) when is_integer(update_id) do
    cond do
      is_map(raw["message"]) -> normalize_message(update_id, raw["message"])
      is_map(raw["callback_query"]) -> normalize_callback_query(update_id, raw["callback_query"])
      true -> {:ignored, :unsupported_kind}
    end
  end

  def from_telegram_json(_), do: {:ignored, :malformed}

  defp normalize_message(update_id, %{
         "from" => %{"id" => user_id},
         "chat" => %{"id" => chat_id},
         "message_id" => message_id,
         "text" => text
       })
       when is_integer(user_id) and is_integer(chat_id) and is_integer(message_id) and
              is_binary(text) do
    {:text_message,
     %{
       update_id: update_id,
       user_id: user_id,
       chat_id: chat_id,
       text: text,
       message_id: message_id
     }}
  end

  defp normalize_message(_update_id, _msg), do: {:ignored, :non_text_or_missing_fields}

  defp normalize_callback_query(
         update_id,
         %{"id" => query_id, "from" => %{"id" => user_id}, "data" => data} = cbq
       )
       when is_binary(query_id) and is_integer(user_id) and is_binary(data) do
    chat_id = get_in(cbq, ["message", "chat", "id"])
    message_id = get_in(cbq, ["message", "message_id"])

    cond do
      not is_integer(chat_id) ->
        {:ignored, :callback_without_chat}

      true ->
        {:callback_query,
         %{
           update_id: update_id,
           user_id: user_id,
           chat_id: chat_id,
           query_id: query_id,
           message_id: message_id,
           data: data
         }}
    end
  end

  defp normalize_callback_query(_update_id, _cbq), do: {:ignored, :callback_missing_fields}
end
