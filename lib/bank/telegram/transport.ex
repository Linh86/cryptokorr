defmodule Bank.Telegram.Transport do
  @moduledoc """
  Outbound Telegram Bot API client (issue #69, epic #54).

  This is the single HTTP boundary for every message the bot emits.
  Callers above it never build URLs, attach bot tokens, or parse raw
  Telegram response envelopes — they invoke one of the typed helpers
  here and map a narrow error set onto their own retry / fail-closed
  semantics.

  Scope is deliberately narrow:

    * `send_message/3` — plain text, optionally with inline buttons
      for interactive approval / pause / resume flows. Each inline
      button label carries an opaque `callback_data` string; higher
      layers are expected to place a
      `Bank.Telegram.CallbackToken` there so button presses are
      replay-safe.
    * `answer_callback_query/2` — acknowledges a button press so
      the Telegram UI stops spinning; optional user-visible text.

  Alerts, command replies, and approval flows consume this module in
  later issues (#68, #71-#73). The transport itself knows nothing
  about those.

  ## Error surface

    * `{:ok, %{message_id: integer() | nil}}` — Telegram accepted the
      call. `message_id` is `nil` when the API returns a boolean
      result (e.g. `answerCallbackQuery`).
    * `{:error, :bot_disabled}` — config says the bot is off.
    * `{:error, :bot_not_configured}` — enabled but no token.
    * `{:error, :invalid_config}` — `Bank.Telegram.Config` shape is
      broken. The plug-side fail-closed invariant is preserved.
    * `{:error, :telegram_unavailable}` — transport error (timeout,
      connection refused, DNS). Callers may retry with backoff.
    * `{:error, {:telegram_rejected, status, body}}` — Telegram
      returned a non-2xx response (bad chat id, blocked user,
      malformed payload). Callers must not retry blindly.
    * `{:error, :invalid_response}` — 200 with an unexpected body
      shape. Treat as a contract bug; do not retry.

  ## Configuration

  The client reads two application-env keys:

    * `:bank, Bank.Telegram.Config` for the bot token. `bot_token/0`
      is the only accessor — raw `TELEGRAM_BOT_TOKEN` env access is
      forbidden at this level.
    * `:bank, Bank.Telegram.Transport` for transport-specific options:

          config :bank, Bank.Telegram.Transport,
            base_url: "https://api.telegram.org",
            req_options: [plug: {Req.Test, Bank.Telegram.Transport}]

      Tests stub with `Req.Test.stub/2` on the module name. Production
      defaults `base_url` to `https://api.telegram.org` when unset.
  """

  require Logger

  alias Bank.Telegram.Config
  alias Bank.Telegram.Telemetry, as: TelegramTelemetry

  @default_base_url "https://api.telegram.org"
  @default_timeout_ms 5_000

  @type send_ok :: %{message_id: integer() | nil}
  @type error ::
          :bot_disabled
          | :bot_not_configured
          | :invalid_config
          | :telegram_unavailable
          | {:telegram_rejected, pos_integer(), map() | String.t()}
          | :invalid_response
  @type inline_button :: %{label: String.t(), callback_data: String.t()}
  @type inline_keyboard :: [[inline_button()]] | [inline_button()]

  @doc """
  Send a Telegram message to `chat_id`.

  Options:

    * `:inline_buttons` — an inline keyboard. Either a flat list of
      `%{label: "..", callback_data: ".."}` maps (single row) or a
      list of such lists (multiple rows). Labels are user-visible
      text; `callback_data` should be a signed
      `Bank.Telegram.CallbackToken` for any action-bearing button.
  """
  @spec send_message(integer(), String.t(), keyword()) :: {:ok, send_ok()} | {:error, error()}
  def send_message(chat_id, text, opts \\ [])
      when is_integer(chat_id) and is_binary(text) do
    payload =
      %{chat_id: chat_id, text: text}
      |> maybe_put_reply_markup(opts[:inline_buttons])

    call("sendMessage", payload)
  end

  @doc """
  Acknowledge a Telegram inline-button press.

  Called after receiving a `callback_query` update so the Telegram
  client stops showing the loading indicator on the tapped button.
  `opts[:text]` (optional) is a short string Telegram shows to the
  operator as a toast.
  """
  @spec answer_callback_query(String.t(), keyword()) :: {:ok, send_ok()} | {:error, error()}
  def answer_callback_query(callback_query_id, opts \\ [])
      when is_binary(callback_query_id) do
    payload =
      %{callback_query_id: callback_query_id}
      |> maybe_put(:text, opts[:text])

    call("answerCallbackQuery", payload)
  end

  @doc """
  Classify an error reason as retriable, not-retriable, or unknown.

  Used by telemetry and higher-level callers (`Bank.Telegram.Alerts`,
  the webhook controller) to decide whether a failed call is worth
  another attempt later or whether the caller should give up and
  surface a hard signal to the operator.

    * `:telegram_unavailable` — network / DNS / timeout; retriable
      with backoff.
    * `{:telegram_rejected, status, _}` — 5xx is retriable, and 429
      is retriable flood control (`retry_after` in Telegram's Bot
      API). Other 4xx are not retriable because the request itself is
      wrong (bad chat id, blocked user, malformed payload).
    * `:invalid_response` — 200 with an unexpected body shape;
      treat as a contract bug, not retriable.
    * Config-side errors (`:bot_disabled` / `:bot_not_configured` /
      `:invalid_config`) are not retriable by the caller — an
      operator has to change configuration first.

  This is a classification function only; it does not perform any
  retry, and `Bank.Telegram.Transport` itself never retries on its
  own. Higher layers choose their retry policy.
  """
  @spec retriable?(any()) :: boolean() | :unknown
  def retriable?(:telegram_unavailable), do: true

  def retriable?({:telegram_rejected, status, _body}) when is_integer(status) and status >= 500,
    do: true

  def retriable?({:telegram_rejected, 429, _body}), do: true

  def retriable?({:telegram_rejected, status, _body}) when is_integer(status), do: false
  def retriable?(:invalid_response), do: false
  def retriable?(:bot_disabled), do: false
  def retriable?(:bot_not_configured), do: false
  def retriable?(:invalid_config), do: false
  def retriable?(_), do: :unknown

  # --- internals ---

  defp call(method, payload) do
    case Config.bot_token() do
      {:ok, token} ->
        {:ok, url} = url_for(token, method)
        emit_transport(method, do_post(url, payload, method))

      {:error, reason} ->
        emit_transport(method, {:error, reason})
    end
  end

  defp emit_transport(method, {:ok, _} = ok) do
    TelegramTelemetry.transport(method, :ok, false)
    ok
  end

  defp emit_transport(method, {:error, reason} = err) do
    tag = error_tag(reason)
    TelegramTelemetry.transport(method, tag, retriable?(reason))
    err
  end

  defp error_tag({:telegram_rejected, _, _}), do: :telegram_rejected
  defp error_tag(atom) when is_atom(atom), do: atom
  defp error_tag(_), do: :unknown

  defp url_for(token, method) do
    base = base_url()
    {:ok, "#{base}/bot#{token}/#{method}"}
  end

  defp do_post(url, payload, method) do
    opts =
      [
        url: url,
        method: :post,
        headers: [{"content-type", "application/json"}],
        json: payload,
        receive_timeout: @default_timeout_ms,
        retry: false
      ]
      |> Keyword.merge(req_options())

    case Req.request(opts) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, normalize_result(result)}

      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.warning(
          "Bank.Telegram.Transport: unexpected 2xx body for #{method}: #{inspect(body)}"
        )

        {:error, :invalid_response}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:telegram_rejected, status, body}}

      {:error, reason} ->
        Logger.warning("Bank.Telegram.Transport: #{method} unavailable: #{inspect(reason)}")
        {:error, :telegram_unavailable}
    end
  end

  defp normalize_result(%{"message_id" => id}) when is_integer(id), do: %{message_id: id}
  defp normalize_result(true), do: %{message_id: nil}
  defp normalize_result(_other), do: %{message_id: nil}

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp maybe_put_reply_markup(payload, nil), do: payload

  defp maybe_put_reply_markup(payload, buttons) when is_list(buttons) do
    Map.put(payload, :reply_markup, %{inline_keyboard: normalize_keyboard(buttons)})
  end

  defp normalize_keyboard([%{label: _, callback_data: _} | _] = single_row) do
    [Enum.map(single_row, &button_json/1)]
  end

  defp normalize_keyboard(rows) when is_list(rows) do
    Enum.map(rows, fn row when is_list(row) ->
      Enum.map(row, &button_json/1)
    end)
  end

  defp button_json(%{label: label, callback_data: cb}) when is_binary(label) and is_binary(cb) do
    %{text: label, callback_data: cb}
  end

  defp base_url do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

  defp req_options do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
