defmodule BankWeb.Internal.TelegramWebhookControllerTest do
  @moduledoc """
  Tests for the Telegram webhook ingress controller (issues #69 + #72).

  Past the plug (see `verify_telegram_webhook_test.exs`), the
  controller normalizes, authenticates, and — for a callback_query
  from an allowlisted operator — dispatches to
  `Bank.Telegram.Callbacks` and acknowledges the button press via
  `Bank.Telegram.Transport.answer_callback_query/2`.

  Covered:

    * text_message and callback_query updates from an allowlisted
      operator produce 200 `{status: "…_accepted"}`;
    * updates from an unknown user, wrong chat, or disabled bot are
      ACKed with 200 `{status: "ignored_sender"}` rather than 4xxing,
      so Telegram does not retry;
    * malformed or unsupported updates are ACKed 200
      `{status: "ignored_update"}`;
    * a callback_query with an invalid token is still 200 `{status:
      "callback_query_accepted"}` because Telegram only cares about
      the HTTP status; the per-button verdict is surfaced via
      `answer_callback_query`.
  """

  use BankWeb.ConnCase, async: false

  import Bank.Fixtures
  import Plug.Conn, only: [put_req_header: 3]

  alias Bank.Decisions
  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Security
  alias Bank.Security.PauseState
  alias Bank.Telegram.CallbackToken
  alias Bank.Telegram.Operator
  alias Bank.Telegram.SecurityControls

  @webhook_path "/internal/telegram/webhook"
  @secret_header "x-telegram-bot-api-secret-token"
  @secret "test-webhook-secret"

  @approver %{user_id: 100, chat_id: 200, role: :approver, audit_actor: "ops-alice"}
  @security_op %{user_id: 101, chat_id: 201, role: :security_operator, audit_actor: "ops-bob"}

  setup do
    original = Application.get_env(:bank, Bank.Telegram.Config)
    PauseState.reset()

    Application.put_env(:bank, Bank.Telegram.Config,
      enabled: true,
      bot_token: "test-bot-token",
      webhook_secret: @secret,
      operators: [@approver, @security_op]
    )

    # Default Transport stub: accept any outbound Telegram call with a
    # boolean-true ACK. Individual tests that care about
    # answer_callback_query payload install their own stub on top.
    Req.Test.stub(Bank.Telegram.Transport, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
    end)

    on_exit(fn ->
      if original do
        Application.put_env(:bank, Bank.Telegram.Config, original)
      else
        Application.delete_env(:bank, Bank.Telegram.Config)
      end
    end)

    :ok
  end

  defp operator_struct do
    %Operator{
      user_id: @approver.user_id,
      chat_id: @approver.chat_id,
      role: @approver.role,
      audit_actor: @approver.audit_actor
    }
  end

  defp security_operator_struct do
    %Operator{
      user_id: @security_op.user_id,
      chat_id: @security_op.chat_id,
      role: @security_op.role,
      audit_actor: @security_op.audit_actor
    }
  end

  defp pending_approval_envelope do
    intent = agent_intent()

    decision_envelope(
      intent: intent,
      outcome: :approval_required,
      state: :pending_decision,
      current: true,
      approval_expires_at: ~U[2030-01-01 00:00:00Z]
    )
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

    test "dispatches /pause as step-up confirmation with signed inline button",
         %{conn: conn} do
      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram_sent, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 2}}))
      end)

      payload = %{
        "update_id" => 9,
        "message" => %{
          "message_id" => 19,
          "from" => %{"id" => @security_op.user_id},
          "chat" => %{"id" => @security_op.chat_id},
          "text" => "/pause"
        }
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      assert json_response(conn, 200)["status"] == "command_handled"
      assert_receive {:telegram_sent, path, sent}, 500
      assert path =~ "/sendMessage"
      assert sent["chat_id"] == @security_op.chat_id
      assert sent["text"] =~ "Confirm runtime pause"
      assert sent["text"] =~ "/security"

      [[button]] = sent["reply_markup"]["inline_keyboard"]
      assert button["text"] == "Confirm pause"

      assert {:ok, %{action: :pause, target_id: target_id}} =
               CallbackToken.verify(
                 button["callback_data"],
                 @security_op.user_id,
                 @security_op.chat_id
               )

      assert target_id == SecurityControls.runtime_control_target_id()
    end

    test "approver gets an informational denial for /pause and no reply_markup",
         %{conn: conn} do
      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram_sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 3}}))
      end)

      payload = %{
        "update_id" => 10,
        "message" => %{
          "message_id" => 20,
          "from" => %{"id" => @approver.user_id},
          "chat" => %{"id" => @approver.chat_id},
          "text" => "/pause"
        }
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      assert json_response(conn, 200)["status"] == "command_handled"
      assert_receive {:telegram_sent, sent}, 500
      assert sent["text"] =~ "Not authorized"
      refute Map.has_key?(sent, "reply_markup")
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
    test "ACKs callback_query_accepted even when the data is not a valid token", %{conn: conn} do
      # The per-button verdict is surfaced via answer_callback_query,
      # not via the webhook HTTP status. Telegram only retries on
      # non-200 responses, so an unverifiable token must still 200
      # here.
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

    test "valid approve callback mutates the decision and calls answer_callback_query",
         %{conn: conn} do
      envelope = pending_approval_envelope()
      token = CallbackToken.sign(operator_struct(), :approve, envelope.id)

      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn tg_conn ->
        {:ok, body, tg_conn} = Plug.Conn.read_body(tg_conn)
        send(test_pid, {:telegram_sent, tg_conn.request_path, Jason.decode!(body)})

        tg_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      payload = %{
        "update_id" => 7,
        "callback_query" => %{
          "id" => "cbq-approve",
          "from" => %{"id" => @approver.user_id},
          "data" => token,
          "message" => %{
            "message_id" => 30,
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

      # answer_callback_query was called with the success text.
      assert_receive {:telegram_sent, path, tg_body}
      assert path =~ "/answerCallbackQuery"
      assert tg_body["callback_query_id"] == "cbq-approve"
      assert tg_body["text"] == "Approved."

      # The decision mutation went through.
      {:ok, prior} = Decisions.get_envelope(envelope.id)
      refute prior.current

      successor = Bank.Repo.get_by!(DecisionEnvelope, supersedes_id: envelope.id)
      assert successor.outcome == :auto_exec
      assert successor.current
    end

    test "invalid callback token still answers the query so the button stops spinning",
         %{conn: conn} do
      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn tg_conn ->
        {:ok, body, tg_conn} = Plug.Conn.read_body(tg_conn)
        send(test_pid, {:telegram_sent, tg_conn.request_path, Jason.decode!(body)})

        tg_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      payload = %{
        "update_id" => 8,
        "callback_query" => %{
          "id" => "cbq-bad",
          "from" => %{"id" => @approver.user_id},
          "data" => "not-a-real-token",
          "message" => %{
            "message_id" => 31,
            "chat" => %{"id" => @approver.chat_id}
          }
        }
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      assert json_response(conn, 200)["status"] == "callback_query_accepted"
      assert_receive {:telegram_sent, path, tg_body}
      assert path =~ "/answerCallbackQuery"
      assert tg_body["callback_query_id"] == "cbq-bad"
      # The operator-facing text is the malformed-button copy.
      assert tg_body["text"] == "Invalid button."
    end

    test "valid pause callback mutates security state and answers the query",
         %{conn: conn} do
      token =
        CallbackToken.sign(
          security_operator_struct(),
          :pause,
          SecurityControls.runtime_control_target_id()
        )

      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn tg_conn ->
        {:ok, body, tg_conn} = Plug.Conn.read_body(tg_conn)
        send(test_pid, {:telegram_sent, tg_conn.request_path, Jason.decode!(body)})

        tg_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      payload = %{
        "update_id" => 11,
        "callback_query" => %{
          "id" => "cbq-pause",
          "from" => %{"id" => @security_op.user_id},
          "data" => token,
          "message" => %{
            "message_id" => 40,
            "chat" => %{"id" => @security_op.chat_id}
          }
        }
      }

      conn =
        conn
        |> authenticated()
        |> post(@webhook_path, payload)

      assert json_response(conn, 200)["status"] == "callback_query_accepted"
      assert Security.paused?(:global)
      assert_receive {:telegram_sent, path, tg_body}, 500
      assert path =~ "/answerCallbackQuery"
      assert tg_body["callback_query_id"] == "cbq-pause"
      assert tg_body["text"] == "Runtime paused."
    end

    test "ACKs ignored_sender on a callback from an unknown user and closes the spinner",
         %{conn: conn} do
      # Unauthorized callers get no action and no operator-visible
      # toast text, but we still close the Telegram UI spinner on
      # the button that was tapped so it does not hang in the
      # tapper's client forever.
      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn tg_conn ->
        {:ok, body, tg_conn} = Plug.Conn.read_body(tg_conn)
        send(test_pid, {:telegram_sent, tg_conn.request_path, Jason.decode!(body)})

        tg_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

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

      assert json_response(conn, 200)["status"] == "ignored_sender"

      # answer_callback_query was called, but with no :text — we are
      # not disclosing anything beyond closing the spinner.
      assert_receive {:telegram_sent, path, tg_body}
      assert path =~ "/answerCallbackQuery"
      assert tg_body["callback_query_id"] == "cbq-2"
      refute Map.has_key?(tg_body, "text")
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
