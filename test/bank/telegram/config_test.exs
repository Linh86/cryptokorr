defmodule Bank.Telegram.ConfigTest do
  @moduledoc """
  Regression tests for the Telegram operator identity / allowlist /
  role / secrets boundary introduced in issue #70 (parent epic #54).

  Every later Telegram feature (transport, webhook ingress, callback
  tokens, alerts, commands, approvals) sits on top of this module.
  These tests pin the acceptance criteria from #70:

    * one explicit configuration shape covers token, allowlist,
      environment enablement, and role mapping;
    * `authorize/2` is deterministic and runs before any business
      logic;
    * unknown users, wrong chats, disabled bot, and missing token each
      return a distinct fail-closed error atom;
    * usernames cannot authorize — the API is integer-only;
    * role resolution is a static truth table with no silent default.

  An extra regression mirrors `Bank.AdapterConfigTest` from issue #51:
  `config/config.exs` must not set `:bank, Bank.Telegram.Config`
  defaults. Otherwise a misconfigured production boot could silently
  inherit a development allowlist or token.
  """

  use ExUnit.Case, async: false

  alias Bank.Telegram.Config, as: TelegramConfig
  alias Bank.Telegram.Operator

  @viewer %{user_id: 1001, chat_id: 50, role: :viewer, audit_actor: "ops-reader"}
  @approver %{user_id: 1002, chat_id: 50, role: :approver, audit_actor: "ops-alice"}
  @security_op %{user_id: 1003, chat_id: 60, role: :security_operator, audit_actor: "ops-bob"}
  @admin %{user_id: 1004, chat_id: 60, role: :admin, audit_actor: "ops-root"}

  setup do
    original = Application.get_env(:bank, TelegramConfig)

    on_exit(fn ->
      if original do
        Application.put_env(:bank, TelegramConfig, original)
      else
        Application.delete_env(:bank, TelegramConfig)
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

    Application.put_env(:bank, TelegramConfig, Keyword.merge(defaults, opts))
  end

  defp operator(map), do: struct!(Operator, map)

  describe "config/config.exs invariant (mirrors #51 adapter regression)" do
    test "does not set :bank, Bank.Telegram.Config defaults" do
      config =
        "config/config.exs"
        |> Path.expand(File.cwd!())
        |> Config.Reader.read!(env: :prod)

      bank_cfg = Keyword.get(config, :bank, [])

      refute Keyword.has_key?(bank_cfg, Bank.Telegram.Config),
             "config/config.exs must not set :bank, Bank.Telegram.Config — production " <>
               "must supply TELEGRAM_BOT_ENABLED / TELEGRAM_BOT_TOKEN / " <>
               "TELEGRAM_WEBHOOK_SECRET / TELEGRAM_OPERATORS via env in " <>
               "config/runtime.exs. See issues #70 and #69."
    end
  end

  describe "authorize/2 — fail-closed defaults" do
    test "disabled bot rejects every actor with :bot_disabled" do
      configure(enabled: false, operators: [@approver])

      assert {:error, :bot_disabled} =
               TelegramConfig.authorize(@approver.user_id, @approver.chat_id)
    end

    test "missing bot token fails closed with :bot_not_configured even when enabled" do
      configure(bot_token: nil, operators: [@approver])

      assert {:error, :bot_not_configured} =
               TelegramConfig.authorize(@approver.user_id, @approver.chat_id)
    end

    test "blank bot token is treated as unconfigured" do
      configure(bot_token: "", operators: [@approver])

      assert {:error, :bot_not_configured} =
               TelegramConfig.authorize(@approver.user_id, @approver.chat_id)
    end

    test "no application config at all returns :bot_disabled" do
      Application.delete_env(:bank, TelegramConfig)
      assert {:error, :bot_disabled} = TelegramConfig.authorize(1, 1)
    end

    test "malformed config shape returns :invalid_config (never {:ok, _})" do
      Application.put_env(:bank, TelegramConfig,
        enabled: true,
        bot_token: "t",
        operators: [%{user_id: 1, chat_id: 1, role: :god_mode, audit_actor: "x"}]
      )

      assert {:error, :invalid_config} = TelegramConfig.authorize(1, 1)
    end
  end

  describe "authorize/2 — identity checks" do
    setup do
      configure(operators: [@viewer, @approver, @security_op, @admin])
      :ok
    end

    test "authorizes a known (user_id, chat_id) tuple and returns the Operator" do
      assert {:ok,
              %Operator{
                user_id: 1002,
                chat_id: 50,
                role: :approver,
                audit_actor: "ops-alice"
              }} = TelegramConfig.authorize(1002, 50)
    end

    test "rejects an unknown user id with :unknown_user" do
      assert {:error, :unknown_user} = TelegramConfig.authorize(9999, 50)
    end

    test "rejects a known user id on the wrong chat with :chat_mismatch" do
      # 1002 is allowlisted on chat 50; acting from chat 999 must not succeed.
      assert {:error, :chat_mismatch} = TelegramConfig.authorize(1002, 999)
    end

    test "rejects when the operator list is empty regardless of ids" do
      configure(operators: [])
      assert {:error, :unknown_user} = TelegramConfig.authorize(1001, 50)
    end

    test "distinguishes :unknown_user from :chat_mismatch" do
      # Same chat id, but one user id is known and the other is not.
      assert {:error, :unknown_user} = TelegramConfig.authorize(7777, 50)
      assert {:error, :chat_mismatch} = TelegramConfig.authorize(@approver.user_id, 999)
    end

    test "accepts negative chat ids (Telegram group/channel form)" do
      configure(operators: [%{@approver | chat_id: -1_001_234_567_890}])

      assert {:ok, %Operator{chat_id: -1_001_234_567_890}} =
               TelegramConfig.authorize(@approver.user_id, -1_001_234_567_890)
    end

    test "the API has no username path — only integer ids compile" do
      assert_raise FunctionClauseError, fn ->
        TelegramConfig.authorize("@alice", 50)
      end

      assert_raise FunctionClauseError, fn ->
        TelegramConfig.authorize(@approver.user_id, "@group")
      end
    end
  end

  describe "can?/2 — role capability matrix" do
    test ":viewer may only read" do
      op = operator(@viewer)
      assert TelegramConfig.can?(op, :read)
      refute TelegramConfig.can?(op, :approve_reject)
      refute TelegramConfig.can?(op, :pause_resume)
    end

    test ":approver may read and approve/reject, but not pause/resume" do
      op = operator(@approver)
      assert TelegramConfig.can?(op, :read)
      assert TelegramConfig.can?(op, :approve_reject)
      refute TelegramConfig.can?(op, :pause_resume)
    end

    test ":security_operator may read, approve/reject, and pause/resume" do
      op = operator(@security_op)
      assert TelegramConfig.can?(op, :read)
      assert TelegramConfig.can?(op, :approve_reject)
      assert TelegramConfig.can?(op, :pause_resume)
    end

    test ":admin has every listed capability" do
      op = operator(@admin)

      for action <- TelegramConfig.actions() do
        assert TelegramConfig.can?(op, action), "admin should have #{inspect(action)}"
      end
    end

    test "unknown actions raise — there is no silent default-allow" do
      op = operator(@approver)

      assert_raise FunctionClauseError, fn ->
        TelegramConfig.can?(op, :totally_made_up_action)
      end
    end
  end

  describe "load/0 — config shape validation" do
    test "accepts a well-formed config and returns Operator structs" do
      configure(operators: [@approver])
      assert {:ok, cfg} = TelegramConfig.load()
      assert cfg.enabled
      assert cfg.bot_token == "test-bot-token"
      assert cfg.webhook_secret == "test-webhook-secret"
      assert [%Operator{audit_actor: "ops-alice"}] = cfg.operators
    end

    test "rejects an operator with a non-integer user id" do
      configure(
        operators: [%{user_id: "not-an-int", chat_id: 50, role: :approver, audit_actor: "x"}]
      )

      assert {:error, {:invalid_operator, 0, :malformed_operator}} = TelegramConfig.load()
    end

    test "rejects an unknown role with the row index and the bad role atom" do
      configure(operators: [%{user_id: 1, chat_id: 1, role: :god_mode, audit_actor: "x"}])

      assert {:error, {:invalid_operator, 0, {:unknown_role, :god_mode}}} =
               TelegramConfig.load()
    end

    test "rejects a blank audit_actor (cannot attribute silently)" do
      configure(operators: [%{user_id: 1, chat_id: 1, role: :approver, audit_actor: ""}])

      assert {:error, {:invalid_operator, 0, :blank_audit_actor}} = TelegramConfig.load()
    end

    test "rejects when :operators is not a list" do
      Application.put_env(:bank, TelegramConfig,
        enabled: true,
        bot_token: "t",
        operators: %{user_id: 1}
      )

      assert {:error, :operators_not_a_list} = TelegramConfig.load()
    end
  end

  describe "bot_token/0 — safe accessor" do
    test "returns {:ok, token} when enabled and configured" do
      configure(bot_token: "abc123")
      assert {:ok, "abc123"} = TelegramConfig.bot_token()
    end

    test "returns {:error, :bot_disabled} when disabled" do
      configure(enabled: false, bot_token: "abc123")
      assert {:error, :bot_disabled} = TelegramConfig.bot_token()
    end

    test "returns {:error, :bot_not_configured} on a blank token" do
      configure(bot_token: "")
      assert {:error, :bot_not_configured} = TelegramConfig.bot_token()
    end

    test "returns {:error, :bot_not_configured} on a nil token" do
      configure(bot_token: nil)
      assert {:error, :bot_not_configured} = TelegramConfig.bot_token()
    end
  end

  describe "webhook_secret/0 — safe accessor (#69)" do
    test "returns {:ok, secret} when enabled and configured" do
      configure(webhook_secret: "whsec-123")
      assert {:ok, "whsec-123"} = TelegramConfig.webhook_secret()
    end

    test "returns {:error, :bot_disabled} when the bot is off" do
      configure(enabled: false, webhook_secret: "whsec-123")
      assert {:error, :bot_disabled} = TelegramConfig.webhook_secret()
    end

    test "returns {:error, :webhook_secret_not_configured} on a nil secret" do
      configure(webhook_secret: nil)
      assert {:error, :webhook_secret_not_configured} = TelegramConfig.webhook_secret()
    end

    test "returns {:error, :webhook_secret_not_configured} on a blank secret" do
      configure(webhook_secret: "")
      assert {:error, :webhook_secret_not_configured} = TelegramConfig.webhook_secret()
    end

    test "returns {:error, :invalid_config} when the config shape is broken" do
      Application.put_env(:bank, TelegramConfig,
        enabled: true,
        bot_token: "t",
        webhook_secret: "w",
        operators: [%{user_id: 1, chat_id: 1, role: :god_mode, audit_actor: "x"}]
      )

      assert {:error, :invalid_config} = TelegramConfig.webhook_secret()
    end
  end

  describe "enabled?/0" do
    test "true only when enabled flag is true" do
      configure(enabled: true)
      assert TelegramConfig.enabled?()

      configure(enabled: false)
      refute TelegramConfig.enabled?()
    end

    test "false when config shape is broken (fail-closed)" do
      Application.put_env(:bank, TelegramConfig,
        enabled: true,
        bot_token: "t",
        operators: [%{user_id: 1, chat_id: 1, role: :god_mode, audit_actor: "x"}]
      )

      refute TelegramConfig.enabled?()
    end
  end

  describe "parse_operators_env!/1 — TELEGRAM_OPERATORS format" do
    test "parses a well-formed pipe-separated string" do
      raw = "1001:50:viewer:ops-reader|1002:50:approver:ops-alice"

      assert [
               %{user_id: 1001, chat_id: 50, role: :viewer, audit_actor: "ops-reader"},
               %{user_id: 1002, chat_id: 50, role: :approver, audit_actor: "ops-alice"}
             ] = TelegramConfig.parse_operators_env!(raw)
    end

    test "accepts negative chat ids (Telegram group/channel form)" do
      raw = "1002:-1001234567890:approver:ops-alice"
      assert [%{chat_id: -1_001_234_567_890}] = TelegramConfig.parse_operators_env!(raw)
    end

    test "preserves colons inside the audit_actor field" do
      raw = "1002:50:approver:ops:alice:with:colons"
      assert [%{audit_actor: "ops:alice:with:colons"}] = TelegramConfig.parse_operators_env!(raw)
    end

    test "raises on an unknown role with the row index" do
      assert_raise ArgumentError, ~r/unknown role/, fn ->
        TelegramConfig.parse_operators_env!("1002:50:god_mode:ops-alice")
      end
    end

    test "raises on a malformed record (wrong arity)" do
      assert_raise ArgumentError, ~r/malformed/, fn ->
        TelegramConfig.parse_operators_env!("1002:50:approver")
      end
    end

    test "raises on a blank audit_actor" do
      assert_raise ArgumentError, ~r/malformed/, fn ->
        TelegramConfig.parse_operators_env!("1002:50:approver:")
      end
    end

    test "raises on non-integer user id" do
      assert_raise ArgumentError, ~r/user_id/, fn ->
        TelegramConfig.parse_operators_env!("alice:50:approver:ops-alice")
      end
    end

    test "raises on non-integer chat id" do
      assert_raise ArgumentError, ~r/chat_id/, fn ->
        TelegramConfig.parse_operators_env!("1002:notanint:approver:ops-alice")
      end
    end

    test "empty string yields empty list (no implicit rows)" do
      assert [] = TelegramConfig.parse_operators_env!("")
    end

    test "round-trips from env-var format through load/0 into Operator structs" do
      raw = "1002:50:approver:ops-alice|1003:60:security_operator:ops-bob"
      operators = TelegramConfig.parse_operators_env!(raw)

      configure(operators: operators)

      assert {:ok, cfg} = TelegramConfig.load()

      assert [
               %Operator{user_id: 1002, chat_id: 50, role: :approver, audit_actor: "ops-alice"},
               %Operator{
                 user_id: 1003,
                 chat_id: 60,
                 role: :security_operator,
                 audit_actor: "ops-bob"
               }
             ] = cfg.operators
    end
  end
end
