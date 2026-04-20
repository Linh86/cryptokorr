defmodule BankWeb.Plugs.VerifyTelegramWebhookTest do
  @moduledoc """
  Tests for the Telegram webhook gatekeeper (issue #69).

  Validates that:

    * the `X-Telegram-Bot-Api-Secret-Token` header is required and
      compared via `Plug.Crypto.secure_compare/2`;
    * each fail-closed path returns a distinct 401 error code
      (`missing_secret_token`, `invalid_secret_token`, `bot_disabled`,
      `server_misconfigured`);
    * a matching secret lets the request through to the controller.
  """

  # async: false because tests mutate :bank, Bank.Telegram.Config
  # and restore it afterwards.
  use BankWeb.ConnCase, async: false

  import Plug.Conn, only: [put_req_header: 3]

  @webhook_path "/internal/telegram/webhook"
  @header "x-telegram-bot-api-secret-token"

  setup do
    original = Application.get_env(:bank, Bank.Telegram.Config)

    on_exit(fn ->
      if original do
        Application.put_env(:bank, Bank.Telegram.Config, original)
      else
        Application.delete_env(:bank, Bank.Telegram.Config)
      end
    end)

    :ok
  end

  defp configure(opts) do
    defaults = [
      enabled: true,
      bot_token: "test-bot-token",
      webhook_secret: "test-webhook-secret",
      operators: []
    ]

    Application.put_env(:bank, Bank.Telegram.Config, Keyword.merge(defaults, opts))
  end

  describe "authorization" do
    test "401 missing_secret_token when no header is sent", %{conn: conn} do
      configure([])
      conn = post(conn, @webhook_path, %{})
      body = json_response(conn, 401)
      assert body["error"]["code"] == "missing_secret_token"
    end

    test "401 invalid_secret_token when header does not match", %{conn: conn} do
      configure([])

      conn =
        conn
        |> put_req_header(@header, "definitely-not-the-secret")
        |> post(@webhook_path, %{})

      body = json_response(conn, 401)
      assert body["error"]["code"] == "invalid_secret_token"
    end

    test "401 bot_disabled when the bot is disabled", %{conn: conn} do
      configure(enabled: false, webhook_secret: "test-webhook-secret")

      conn =
        conn
        |> put_req_header(@header, "test-webhook-secret")
        |> post(@webhook_path, %{})

      body = json_response(conn, 401)
      assert body["error"]["code"] == "bot_disabled"
    end

    test "401 server_misconfigured when webhook_secret is not configured", %{conn: conn} do
      configure(webhook_secret: nil)

      conn =
        conn
        |> put_req_header(@header, "anything")
        |> post(@webhook_path, %{})

      body = json_response(conn, 401)
      assert body["error"]["code"] == "server_misconfigured"
    end

    test "401 server_invalid_config bubbles as server_misconfigured", %{conn: conn} do
      # Break the operator shape to force :invalid_config.
      Application.put_env(:bank, Bank.Telegram.Config,
        enabled: true,
        bot_token: "t",
        webhook_secret: "w",
        operators: [%{user_id: 1, chat_id: 1, role: :god_mode, audit_actor: "x"}]
      )

      conn =
        conn
        |> put_req_header(@header, "w")
        |> post(@webhook_path, %{})

      body = json_response(conn, 401)
      assert body["error"]["code"] == "server_misconfigured"
    end

    test "200 accepted when the secret matches — control reaches the controller", %{conn: conn} do
      configure([])

      # A malformed body still reaches the controller because the plug's only
      # job is header auth. The controller normalizes it to :ignored and ACKs.
      conn =
        conn
        |> put_req_header(@header, "test-webhook-secret")
        |> post(@webhook_path, %{"garbage" => true})

      body = json_response(conn, 200)
      # The controller translated the malformed payload to a stable status.
      assert is_binary(body["status"])
    end
  end
end
