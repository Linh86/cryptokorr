defmodule BankWeb.Internal.TelegramWebhookControllerTest do
  @moduledoc """
  Tests for the Telegram webhook ingress controller (issue #69).

  Past the plug (see `verify_telegram_webhook_test.exs`), the
  controller only normalizes and authenticates. It never executes
  approval, pause/resume, or command logic in this issue's scope.

  Covered:

    * text_message and callback_query updates from an allowlisted
      operator produce 200 `{status: "…_accepted"}`;
    * updates from an unknown user, wrong chat, or disabled bot are
      ACKed with 200 `{status: "ignored_sender"}` rather than 4xxing,
      so Telegram does not retry;
    * malformed or unsupported updates are ACKed 200
      `{status: "ignored_update"}`.
  """

  use BankWeb.ConnCase, async: false

  import Plug.Conn, only: [put_req_header: 3]

  @webhook_path "/internal/telegram/webhook"
  @secret_header "x-telegram-bot-api-secret-token"
  @secret "test-webhook-secret"

  @approver %{user_id: 100, chat_id: 200, role: :approver, audit_actor: "ops-alice"}

  setup do
    original = Application.get_env(:bank, Bank.Telegram.Config)

    Application.put_env(:bank, Bank.Telegram.Config,
      enabled: true,
      bot_token: "test-bot-token",
      webhook_secret: @secret,
      operators: [@approver]
    )

    on_exit(fn ->
      if original do
        Application.put_env(:bank, Bank.Telegram.Config, original)
      else
        Application.delete_env(:bank, Bank.Telegram.Config)
      end
    end)

    :ok
  end

  defp authenticated(conn) do
    put_req_header(conn, @secret_header, @secret)
  end

  describe "text messages" do
    test "ACKs text_message_accepted on non-command text when the sender is allowlisted",
         %{conn: conn} do
      payload = %{
        "update_id" => 1,
        "message" => %{
          "message_id" => 10,
          "from" => %{"id" => @approver.user_id},
          "chat" => %{"id" => @approver.chat_id},
          "text" => "hello bot"
        }
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      body = json_response(conn, 200)
      assert body["status"] == "text_message_accepted"
    end

    test "dispatches /help as a command, sends the help reply, and ACKs command_handled",
         %{conn: conn} do
      # #71 round-trip: an allowlisted operator sends a known
      # command → controller parses it via Bank.Telegram.Commands,
      # sends the reply via Bank.Telegram.Transport (stubbed
      # here), and ACKs with the "command_handled" status so the
      # ingress path has an operational signal distinct from
      # non-command text.
      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram_sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 1}}))
      end)

      payload = %{
        "update_id" => 1,
        "message" => %{
          "message_id" => 10,
          "from" => %{"id" => @approver.user_id},
          "chat" => %{"id" => @approver.chat_id},
          "text" => "/help"
        }
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      body = json_response(conn, 200)
      assert body["status"] == "command_handled"

      assert_receive {:telegram_sent, sent}, 500
      assert sent["chat_id"] == @approver.chat_id
      assert sent["text"] =~ "Commands:"
      assert sent["text"] =~ "/help"
      assert sent["text"] =~ "/status"
      assert sent["text"] =~ "/queue"
    end

    test "ACKs ignored_sender when the user is unknown", %{conn: conn} do
      payload = %{
        "update_id" => 2,
        "message" => %{
          "message_id" => 11,
          "from" => %{"id" => 9999},
          "chat" => %{"id" => @approver.chat_id},
          "text" => "/status"
        }
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      body = json_response(conn, 200)
      assert body["status"] == "ignored_sender"
    end

    test "ACKs ignored_sender when the known user sends from the wrong chat", %{conn: conn} do
      payload = %{
        "update_id" => 3,
        "message" => %{
          "message_id" => 12,
          "from" => %{"id" => @approver.user_id},
          "chat" => %{"id" => 99_999},
          "text" => "/status"
        }
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      body = json_response(conn, 200)
      assert body["status"] == "ignored_sender"
    end
  end

  describe "callback queries" do
    test "ACKs callback_query_accepted when the sender is allowlisted", %{conn: conn} do
      payload = %{
        "update_id" => 4,
        "callback_query" => %{
          "id" => "cbq-1",
          "from" => %{"id" => @approver.user_id},
          "data" => "opaque-callback-token",
          "message" => %{
            "message_id" => 20,
            "chat" => %{"id" => @approver.chat_id}
          }
        }
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      body = json_response(conn, 200)
      assert body["status"] == "callback_query_accepted"
    end

    test "ACKs ignored_sender on a callback from an unknown user", %{conn: conn} do
      payload = %{
        "update_id" => 5,
        "callback_query" => %{
          "id" => "cbq-2",
          "from" => %{"id" => 9999},
          "data" => "t",
          "message" => %{"message_id" => 21, "chat" => %{"id" => @approver.chat_id}}
        }
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      body = json_response(conn, 200)
      assert body["status"] == "ignored_sender"
    end
  end

  describe "unrecognised / malformed updates" do
    test "ACKs ignored_update on an edited_message variant", %{conn: conn} do
      payload = %{
        "update_id" => 6,
        "edited_message" => %{"text" => "oops"}
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      body = json_response(conn, 200)
      assert body["status"] == "ignored_update"
    end

    test "ACKs ignored_update on a payload without an update_id", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, %{"garbage" => true})

      body = json_response(conn, 200)
      assert body["status"] == "ignored_update"
    end
  end
end
