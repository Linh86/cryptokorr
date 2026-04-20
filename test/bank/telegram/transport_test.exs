defmodule Bank.Telegram.TransportTest do
  @moduledoc """
  Tests for the outbound Telegram transport (issue #69).

  These tests exercise:

    * the URL / header / payload shape sent to the Telegram Bot API;
    * the narrow error surface (`:bot_disabled`, `:bot_not_configured`,
      `:invalid_config`, `:telegram_unavailable`,
      `{:telegram_rejected, ...}`, `:invalid_response`);
    * normalization of the `{ok: true, result: ...}` response envelope
      into a minimal internal shape.

  Network stubbing is per-process via `Req.Test`, keyed on the
  transport module name (`Bank.Telegram.Transport`). The live bot
  token never leaves the test env.
  """

  use ExUnit.Case, async: false

  alias Bank.Telegram.Transport

  @bot_token "test-bot-token"

  setup do
    original = Application.get_env(:bank, Bank.Telegram.Config)

    Application.put_env(:bank, Bank.Telegram.Config,
      enabled: true,
      bot_token: @bot_token,
      webhook_secret: "unused-here",
      operators: []
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

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "send_message/3 — happy path" do
    test "posts to /bot<token>/sendMessage with chat_id + text" do
      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, conn.method, conn.request_path, Jason.decode!(body)})

        json_resp(conn, 200, %{"ok" => true, "result" => %{"message_id" => 123}})
      end)

      assert {:ok, %{message_id: 123}} = Transport.send_message(4242, "hello")

      assert_received {:sent, "POST", path, payload}
      assert path == "/bot#{@bot_token}/sendMessage"
      assert payload["chat_id"] == 4242
      assert payload["text"] == "hello"
      refute Map.has_key?(payload, "reply_markup")
    end

    test "attaches an inline keyboard when :inline_buttons is given (single row)" do
      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, Jason.decode!(body)})
        json_resp(conn, 200, %{"ok" => true, "result" => %{"message_id" => 1}})
      end)

      buttons = [
        %{label: "Approve", callback_data: "tok-ok"},
        %{label: "Reject", callback_data: "tok-no"}
      ]

      assert {:ok, _} = Transport.send_message(4242, "queued", inline_buttons: buttons)

      assert_received {:sent, payload}

      assert payload["reply_markup"] == %{
               "inline_keyboard" => [
                 [
                   %{"text" => "Approve", "callback_data" => "tok-ok"},
                   %{"text" => "Reject", "callback_data" => "tok-no"}
                 ]
               ]
             }
    end

    test "supports a multi-row keyboard when :inline_buttons is a list of lists" do
      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, Jason.decode!(body)})
        json_resp(conn, 200, %{"ok" => true, "result" => %{"message_id" => 2}})
      end)

      buttons = [
        [%{label: "Approve", callback_data: "a"}, %{label: "Reject", callback_data: "r"}],
        [%{label: "Open replay", callback_data: "o"}]
      ]

      assert {:ok, _} = Transport.send_message(4242, "multi", inline_buttons: buttons)

      assert_received {:sent, payload}
      [[a, r], [o]] = payload["reply_markup"]["inline_keyboard"]
      assert a["text"] == "Approve" and a["callback_data"] == "a"
      assert r["text"] == "Reject" and r["callback_data"] == "r"
      assert o["text"] == "Open replay" and o["callback_data"] == "o"
    end

    test "returns {:error, :invalid_response} on a 200 with unexpected body shape" do
      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        json_resp(conn, 200, %{"something" => "else"})
      end)

      assert {:error, :invalid_response} = Transport.send_message(4242, "hi")
    end
  end

  describe "send_message/3 — error surface" do
    test "maps 4xx responses to {:error, {:telegram_rejected, status, body}}" do
      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        json_resp(conn, 400, %{"ok" => false, "description" => "Bad Request: chat not found"})
      end)

      assert {:error, {:telegram_rejected, 400, body}} = Transport.send_message(4242, "hi")
      assert body["description"] =~ "chat not found"
    end

    test "maps 5xx responses to {:error, {:telegram_rejected, status, body}}" do
      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        json_resp(conn, 502, %{"ok" => false})
      end)

      assert {:error, {:telegram_rejected, 502, _}} = Transport.send_message(4242, "hi")
    end

    test "maps transport errors to {:error, :telegram_unavailable}" do
      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :telegram_unavailable} = Transport.send_message(4242, "hi")
    end

    test "propagates :bot_disabled from Config.bot_token/0 without dispatching" do
      Application.put_env(:bank, Bank.Telegram.Config,
        enabled: false,
        bot_token: @bot_token,
        webhook_secret: "s",
        operators: []
      )

      # No stub — if the transport attempted a request, the call would raise
      # because Req.Test has no stub; the assertion proves it short-circuited.
      assert {:error, :bot_disabled} = Transport.send_message(4242, "hi")
    end

    test "propagates :bot_not_configured when the bot token is missing" do
      Application.put_env(:bank, Bank.Telegram.Config,
        enabled: true,
        bot_token: nil,
        webhook_secret: "s",
        operators: []
      )

      assert {:error, :bot_not_configured} = Transport.send_message(4242, "hi")
    end
  end

  describe "answer_callback_query/2" do
    test "posts to /bot<token>/answerCallbackQuery with the query id and optional text" do
      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, conn.request_path, Jason.decode!(body)})
        json_resp(conn, 200, %{"ok" => true, "result" => true})
      end)

      assert {:ok, %{message_id: nil}} =
               Transport.answer_callback_query("cbq-1", text: "Approving…")

      assert_received {:sent, path, payload}
      assert path == "/bot#{@bot_token}/answerCallbackQuery"
      assert payload["callback_query_id"] == "cbq-1"
      assert payload["text"] == "Approving…"
    end

    test "omits :text when not provided" do
      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, Jason.decode!(body)})
        json_resp(conn, 200, %{"ok" => true, "result" => true})
      end)

      assert {:ok, %{message_id: nil}} = Transport.answer_callback_query("cbq-2")

      assert_received {:sent, payload}
      refute Map.has_key?(payload, "text")
    end
  end
end
