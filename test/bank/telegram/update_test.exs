defmodule Bank.Telegram.UpdateTest do
  @moduledoc """
  Tests for the inbound Telegram update normalizer (issue #69).

  The goal of this module under test is to keep raw Telegram JSON
  from leaking beyond the webhook boundary. Every recognised variant
  gets a specific tuple shape; anything else resolves to
  `{:ignored, reason}` with a stable reason atom so the controller
  can ACK (200) instead of 4xxing and triggering Telegram retries.
  """

  use ExUnit.Case, async: true

  alias Bank.Telegram.Update

  describe "text message updates" do
    test "normalizes a bot command message into :text_message" do
      raw = %{
        "update_id" => 10_001,
        "message" => %{
          "message_id" => 42,
          "from" => %{"id" => 100, "first_name" => "Alice"},
          "chat" => %{"id" => 200, "type" => "private"},
          "text" => "/status"
        }
      }

      assert {:text_message,
              %{
                update_id: 10_001,
                user_id: 100,
                chat_id: 200,
                text: "/status",
                message_id: 42
              }} = Update.from_telegram_json(raw)
    end

    test "normalizes a plain text message" do
      raw = %{
        "update_id" => 10_002,
        "message" => %{
          "message_id" => 43,
          "from" => %{"id" => 100},
          "chat" => %{"id" => 200},
          "text" => "hello bot"
        }
      }

      assert {:text_message, %{text: "hello bot"}} = Update.from_telegram_json(raw)
    end

    test "ignores a non-text message variant (photo, sticker, etc.)" do
      raw = %{
        "update_id" => 10_003,
        "message" => %{
          "message_id" => 44,
          "from" => %{"id" => 100},
          "chat" => %{"id" => 200},
          "photo" => [%{"file_id" => "abc"}]
        }
      }

      assert {:ignored, :non_text_or_missing_fields} = Update.from_telegram_json(raw)
    end

    test "ignores a message missing the chat id" do
      raw = %{
        "update_id" => 10_004,
        "message" => %{
          "message_id" => 45,
          "from" => %{"id" => 100},
          "text" => "hi"
        }
      }

      assert {:ignored, :non_text_or_missing_fields} = Update.from_telegram_json(raw)
    end

    test "ignores a message missing the from field" do
      raw = %{
        "update_id" => 10_005,
        "message" => %{
          "message_id" => 46,
          "chat" => %{"id" => 200},
          "text" => "no from"
        }
      }

      assert {:ignored, :non_text_or_missing_fields} = Update.from_telegram_json(raw)
    end
  end

  describe "callback query updates" do
    test "normalizes a callback query with chat context into :callback_query" do
      raw = %{
        "update_id" => 20_001,
        "callback_query" => %{
          "id" => "cbq-1",
          "from" => %{"id" => 100},
          "data" => "some-opaque-token",
          "message" => %{"message_id" => 44, "chat" => %{"id" => 200}}
        }
      }

      assert {:callback_query,
              %{
                update_id: 20_001,
                user_id: 100,
                chat_id: 200,
                query_id: "cbq-1",
                message_id: 44,
                data: "some-opaque-token"
              }} = Update.from_telegram_json(raw)
    end

    test "accepts negative chat ids on callback queries (group/channel form)" do
      raw = %{
        "update_id" => 20_002,
        "callback_query" => %{
          "id" => "cbq-2",
          "from" => %{"id" => 100},
          "data" => "tok",
          "message" => %{"message_id" => 55, "chat" => %{"id" => -1_001_234}}
        }
      }

      assert {:callback_query, %{chat_id: -1_001_234}} = Update.from_telegram_json(raw)
    end

    test "ignores a callback query without a message.chat.id (inline mode)" do
      raw = %{
        "update_id" => 20_003,
        "callback_query" => %{
          "id" => "cbq-3",
          "from" => %{"id" => 100},
          "data" => "tok"
        }
      }

      assert {:ignored, :callback_without_chat} = Update.from_telegram_json(raw)
    end

    test "ignores a callback query missing the data field" do
      raw = %{
        "update_id" => 20_004,
        "callback_query" => %{
          "id" => "cbq-4",
          "from" => %{"id" => 100},
          "message" => %{"message_id" => 55, "chat" => %{"id" => 200}}
        }
      }

      assert {:ignored, :callback_missing_fields} = Update.from_telegram_json(raw)
    end

    test "ignores a callback query missing the from id" do
      raw = %{
        "update_id" => 20_005,
        "callback_query" => %{
          "id" => "cbq-5",
          "data" => "tok",
          "message" => %{"message_id" => 55, "chat" => %{"id" => 200}}
        }
      }

      assert {:ignored, :callback_missing_fields} = Update.from_telegram_json(raw)
    end
  end

  describe "unrecognized / malformed updates" do
    test "ignores updates without update_id" do
      assert {:ignored, :malformed} = Update.from_telegram_json(%{"message" => %{}})
    end

    test "ignores updates that are not maps" do
      assert {:ignored, :malformed} = Update.from_telegram_json("not a map")
      assert {:ignored, :malformed} = Update.from_telegram_json(nil)
    end

    test "ignores updates with a non-integer update_id" do
      raw = %{"update_id" => "abc", "message" => %{"text" => "x"}}
      assert {:ignored, :malformed} = Update.from_telegram_json(raw)
    end

    test "ignores updates of unsupported kinds (edited_message, channel_post, etc.)" do
      raw = %{
        "update_id" => 30_001,
        "edited_message" => %{"text" => "oops"}
      }

      assert {:ignored, :unsupported_kind} = Update.from_telegram_json(raw)
    end
  end
end
