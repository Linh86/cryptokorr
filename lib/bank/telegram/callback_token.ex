defmodule Bank.Telegram.CallbackToken do
  @moduledoc """
  Signed, short-lived callback tokens for Telegram inline buttons
  (issue #69, epic #54).

  ## Why a custom compact format

  Telegram's `InlineKeyboardButton.callback_data` field has a hard
  **64-byte** limit. A `Phoenix.Token` signed blob of the payload we
  need to bind (action, target id, actor, expiry) exceeds that. This
  module uses a fixed 48-byte binary (38-byte body + 10-byte
  truncated HMAC), encoded as 64 URL-safe Base64 characters — the
  Telegram maximum.

  ## Binary layout

      |  1 byte  |  1 byte  | 4 bytes    | 8 bytes   | 8 bytes         | 16 bytes    | 10 bytes |
      | version  | action   | expires_at | user_id   | chat_id         | target_id   | hmac     |
      | 0x02     | code     | uint32 s   | uint64    | int64 signed    | uuid raw    | sha256   |
                                                                                    (truncated)

  The HMAC key is derived from the endpoint's `:secret_key_base` via
  SHA-256 with a module-specific domain separator, so tokens rotate
  automatically when the key rotates and tokens for this module do
  not collide with other signed payloads elsewhere in the app.

  ### Why `user_id` is uint64 (not uint48)

  Telegram documents user and chat ids as requiring **up to 52
  significant bits**, so the `uint48` layout used before the #69
  fix could overflow on legitimate operator IDs and break
  button-based flows. Widening `user_id` to `uint64` adds 2 bytes;
  the `hmac` field was narrowed from 12 to 10 bytes (SHA-256
  truncated to 80 bits) to keep the total body at 48 bytes so the
  Base64-URL-encoded output still fits Telegram's 64-character
  `callback_data` limit. 80-bit HMAC is comfortably secure for
  5-minute-expiry tokens — online forgery against the bot endpoint
  requires ~2⁸⁰ guesses, and each guess requires a Telegram →
  Phoenix round-trip. The `version` byte bumps from `0x01` to
  `0x02` so the new parser cleanly rejects any legacy-layout
  tokens as malformed.

  ## Bindings

    * `user_id` + `chat_id` are signed into the token; `verify/4`
      rejects tokens where those do not match the actor presenting
      them. This defends against the operator forwarding a captured
      callback to a different chat, or another operator replaying it.
    * `expires_at` is a hard wall-clock upper bound. Default max-age
      is 5 minutes — long enough for a human to tap a button, short
      enough that a leaked token is useless.
    * `target_id` is a UUID (our standard id format across decisions,
      execution plans, and security actions). It is bound into the
      HMAC so an attacker cannot swap in a different target.

  ## Error surface

    * `{:ok, payload}` — verified and fresh.
    * `{:error, :malformed}` — wrong length, bad version byte, or an
      unknown action code. Also garbled Base64.
    * `{:error, :invalid}` — HMAC mismatch (tampered, or signed with
      a different `:secret_key_base`).
    * `{:error, :expired}` — past `expires_at`.
    * `{:error, :actor_mismatch}` — token binds a different actor
      than the one presenting it.

  ## Action codes

  Adding a new action is a code change in this module (extend
  `@actions`). Higher-level issues (#72 approve/reject, #73
  pause/resume) consume the existing codes rather than introducing
  new ones ad-hoc.

      :approve      → 0x01
      :reject       → 0x02
      :pause        → 0x03
      :resume       → 0x04
      :open_replay  → 0x05

  ## Scope

  This module is a pure crypto / framing boundary. It does not
  dispatch, touch the approval state machine, or read the database.
  """

  alias Bank.Telegram.Operator

  @version 0x02
  @default_max_age_s 5 * 60
  @token_bytes 48
  @hmac_bytes 10
  @body_bytes @token_bytes - @hmac_bytes

  @actions %{
    approve: 0x01,
    reject: 0x02,
    pause: 0x03,
    resume: 0x04,
    open_replay: 0x05
  }

  @codes_to_actions Enum.into(@actions, %{}, fn {atom, code} -> {code, atom} end)

  @type action :: :approve | :reject | :pause | :resume | :open_replay
  @type payload :: %{
          action: action(),
          target_id: String.t(),
          user_id: integer(),
          chat_id: integer(),
          expires_at: pos_integer()
        }
  @type verify_error :: :malformed | :invalid | :expired | :actor_mismatch

  @doc "Valid action atoms for `sign/4`."
  @spec actions() :: [action()]
  def actions, do: Map.keys(@actions)

  @doc """
  Sign a callback token that binds `operator` to `action` on
  `target_id`.

  Options:

    * `:max_age` — seconds until expiry; default 300 (5 minutes).
    * `:now` — override the issuance clock. Seconds since the Unix
      epoch. Tests use this to exercise expiry without `Process.sleep/1`.
  """
  @spec sign(Operator.t(), action(), String.t(), keyword()) :: String.t()
  def sign(%Operator{user_id: user_id, chat_id: chat_id}, action, target_id, opts \\ [])
      when is_integer(user_id) and is_integer(chat_id) and is_binary(target_id) do
    action_code =
      Map.get(@actions, action) ||
        raise ArgumentError,
              "unknown Telegram callback action #{inspect(action)}; valid: #{inspect(actions())}"

    max_age = Keyword.get(opts, :max_age, @default_max_age_s)
    now = Keyword.get(opts, :now, System.system_time(:second))
    expires_at = now + max_age
    target_bin = decode_uuid!(target_id)

    body =
      <<@version::8, action_code::8, expires_at::32, user_id::64, chat_id::signed-64,
        target_bin::binary-size(16)>>

    mac = mac(body)
    Base.url_encode64(body <> mac, padding: false)
  end

  @doc """
  Verify a callback token string against the actor presenting it.

  `incoming_user_id` and `incoming_chat_id` are the numeric ids from
  the Telegram callback query (`callback_query.from.id` and
  `callback_query.message.chat.id`). Mismatch against the ids bound
  into the token is a `:actor_mismatch` rejection.
  """
  @spec verify(String.t(), integer(), integer(), keyword()) ::
          {:ok, payload()} | {:error, verify_error()}
  def verify(token, incoming_user_id, incoming_chat_id, opts \\ [])
      when is_binary(token) and is_integer(incoming_user_id) and is_integer(incoming_chat_id) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, decoded} <- decode_base64(token),
         {:ok, {body, presented_mac}} <- split_body_mac(decoded),
         :ok <- verify_mac(body, presented_mac),
         {:ok, fields} <- parse_body(body),
         :ok <- check_expiry(fields.expires_at, now),
         :ok <- check_actor(fields, incoming_user_id, incoming_chat_id) do
      {:ok,
       %{
         action: fields.action,
         target_id: format_uuid(fields.target_id),
         user_id: fields.user_id,
         chat_id: fields.chat_id,
         expires_at: fields.expires_at
       }}
    end
  end

  # --- internals ---

  defp decode_base64(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, bin} when byte_size(bin) == @token_bytes -> {:ok, bin}
      _ -> {:error, :malformed}
    end
  end

  defp split_body_mac(bin) do
    <<body::binary-size(@body_bytes), mac::binary-size(@hmac_bytes)>> = bin
    {:ok, {body, mac}}
  end

  defp verify_mac(body, presented_mac) do
    if Plug.Crypto.secure_compare(mac(body), presented_mac) do
      :ok
    else
      {:error, :invalid}
    end
  end

  defp parse_body(
         <<@version::8, action_code::8, expires_at::32, user_id::64, chat_id::signed-64,
           target_id::binary-size(16)>>
       ) do
    case Map.fetch(@codes_to_actions, action_code) do
      {:ok, action} ->
        {:ok,
         %{
           action: action,
           expires_at: expires_at,
           user_id: user_id,
           chat_id: chat_id,
           target_id: target_id
         }}

      :error ->
        {:error, :malformed}
    end
  end

  defp parse_body(_), do: {:error, :malformed}

  defp check_expiry(expires_at, now) when expires_at > now, do: :ok
  defp check_expiry(_expires_at, _now), do: {:error, :expired}

  defp check_actor(%{user_id: u, chat_id: c}, u, c), do: :ok
  defp check_actor(_fields, _user_id, _chat_id), do: {:error, :actor_mismatch}

  defp mac(body) do
    :crypto.mac(:hmac, :sha256, hmac_key(), body) |> binary_part(0, @hmac_bytes)
  end

  defp hmac_key do
    secret_key_base =
      Application.fetch_env!(:bank, BankWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.hash(:sha256, ["bank.telegram.callback.v1\x00", secret_key_base])
  end

  defp decode_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, bin} ->
        bin

      :error ->
        raise ArgumentError,
              "Bank.Telegram.CallbackToken: target_id must be a UUID string, got: " <>
                inspect(uuid)
    end
  end

  defp format_uuid(<<_::binary-size(16)>> = bin) do
    case Ecto.UUID.load(bin) do
      {:ok, uuid} -> uuid
      :error -> raise "Bank.Telegram.CallbackToken: 16-byte target failed UUID format"
    end
  end
end
