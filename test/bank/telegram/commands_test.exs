defmodule Bank.Telegram.CommandsTest do
  @moduledoc """
  Tests for the inbound read-only Telegram command surface
  introduced in issue #71.

  Pins:

    * `parse/1` handles DM commands, safely ignores group-chat
      `@BotName`-suffixed commands until the bot has an authoritative
      username to compare against, plus trailing args, whitespace, unknown command names,
      and non-command text;
    * `handle/2` renders each command deterministically from
      existing source-of-truth helpers (`Bank.Security.snapshot/0`,
      `Bank.Decisions.list_pending_approvals/0`) and never introduces
      Telegram-specific state;
    * unknown commands resolve to the `/help` text — no business
      code is reachable via a typoed command;
    * `handle/2` runs only when `Bank.Telegram.Config.can?(op, :read)`
      grants the read capability.
  """

  use Bank.DataCase, async: false

  alias Bank.Fixtures
  alias Bank.Security.PauseState
  alias Bank.Telegram.Commands
  alias Bank.Telegram.Operator

  @viewer %Operator{
    user_id: 1001,
    chat_id: 50,
    role: :viewer,
    audit_actor: "ops-reader"
  }

  @approver %Operator{
    user_id: 1002,
    chat_id: 60,
    role: :approver,
    audit_actor: "ops-alice"
  }

  setup do
    PauseState.reset()
    :ok
  end

  describe "parse/1" do
    test "recognises /help, /status, /queue" do
      assert {:command, :help, ""} = Commands.parse("/help")
      assert {:command, :status, ""} = Commands.parse("/status")
      assert {:command, :queue, ""} = Commands.parse("/queue")
    end

    test "ignores @BotName-suffixed group commands to avoid answering commands for other bots" do
      assert :not_a_command = Commands.parse("/status@MyBot")
      assert :not_a_command = Commands.parse("/queue@OtherBot")
      assert :not_a_command = Commands.parse("/help@SomeBot extra")
    end

    test "captures trimmed args after the command name" do
      assert {:command, :status, "global"} = Commands.parse("/status global")
      assert {:command, :queue, "limit=5"} = Commands.parse("/queue  limit=5  ")
    end

    test "is case-insensitive on the command name" do
      assert {:command, :help, ""} = Commands.parse("/HELP")
      assert {:command, :status, ""} = Commands.parse("/Status")
    end

    test "tolerates leading whitespace" do
      assert {:command, :help, ""} = Commands.parse("   /help")
    end

    test "non-command text → :not_a_command" do
      assert :not_a_command = Commands.parse("hello bot")
      assert :not_a_command = Commands.parse("")
      assert :not_a_command = Commands.parse("just chatting")
    end

    test "unknown slash-prefixed command → {:unknown, name}" do
      assert {:unknown, "approve"} = Commands.parse("/approve")
      assert {:unknown, "nonsense"} = Commands.parse("/nonsense args here")
    end

    test "non-binary input → :not_a_command" do
      assert :not_a_command = Commands.parse(nil)
      assert :not_a_command = Commands.parse(42)
    end
  end

  describe "handle/2 — /help" do
    test "returns the supported command list with one-line blurbs" do
      assert {:ok, text} = Commands.handle({:command, :help, ""}, @approver)
      assert text =~ "/help"
      assert text =~ "/status"
      assert text =~ "/queue"
      # Commands section header so downstream text parsing stays
      # stable across small wording tweaks.
      assert text =~ "Commands:"
    end
  end

  describe "handle/2 — /status" do
    test "renders 'running' + 'none' on a fresh pause state" do
      assert {:ok, text} = Commands.handle({:command, :status, ""}, @approver)
      assert text =~ "Runtime status"
      assert text =~ "Global: running"
      assert text =~ "Counterparty pauses: none"
      assert text =~ "/security"
    end

    test "renders 'paused' with the reason when global pause is active" do
      {:ok, :paused} = Bank.Security.pause(:global, reason: "operator_requested", actor: :user)

      assert {:ok, text} = Commands.handle({:command, :status, ""}, @approver)
      assert text =~ "Global: paused"
      assert text =~ "operator_requested"
    end

    test "lists small counterparty-scope pauses inline" do
      {:ok, :paused} =
        Bank.Security.pause({:counterparty, "acme-inc"}, reason: "risk_spike", actor: :user)

      assert {:ok, text} = Commands.handle({:command, :status, ""}, @approver)
      assert text =~ "Counterparty pauses: acme-inc"
    end

    test "sorts small counterparty-scope pauses so /status output stays deterministic" do
      {:ok, :paused} =
        Bank.Security.pause({:counterparty, "zeta-co"}, reason: "risk_spike", actor: :user)

      {:ok, :paused} =
        Bank.Security.pause({:counterparty, "acme-inc"}, reason: "risk_spike", actor: :user)

      assert {:ok, text} = Commands.handle({:command, :status, ""}, @approver)
      assert text =~ "Counterparty pauses: acme-inc, zeta-co"
    end
  end

  describe "handle/2 — /queue" do
    test "renders 'Pending approvals: 0' when the queue is empty" do
      assert {:ok, text} = Commands.handle({:command, :queue, ""}, @approver)
      assert text =~ "Pending approvals: 0"
      assert text =~ "/queue"
    end

    test "lists a pending approval with short ids, risk, and expires_at" do
      intent = Fixtures.agent_intent()

      envelope =
        Fixtures.decision_envelope(%{
          intent: intent,
          outcome: :approval_required,
          risk_tier: :elevated,
          current: true,
          approval_expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      assert {:ok, text} = Commands.handle({:command, :queue, ""}, @approver)
      assert text =~ "Pending approvals: 1"
      # Short-id prefixes only — the full id lives in the web console.
      assert text =~ String.slice(envelope.id, 0, 8)
      assert text =~ String.slice(intent.id, 0, 8)
      assert text =~ "risk=elevated"
    end
  end

  describe "handle/2 — unknown command" do
    test "returns the /help text (safe fallback per #71)" do
      assert {:ok, text} = Commands.handle({:unknown, "approve"}, @approver)
      assert text =~ "Unknown command: /approve"
      assert text =~ "Commands:"
      assert text =~ "/help"
    end
  end

  describe "handle/2 — role boundary" do
    # Every current role has :read, so this mainly pins the intent:
    # if a future role restriction strips :read, these commands
    # stop working in lockstep without any extra plumbing.

    test "viewer (has :read) gets the normal response" do
      assert {:ok, text} = Commands.handle({:command, :help, ""}, @viewer)
      assert text =~ "Commands:"
    end

    test "rejects operator whose role is stripped of :read" do
      # Hand-craft an Operator with an unknown role so can?/2 returns
      # false. This is defensive — the config boundary at #70 never
      # produces a role outside its enum — but proves handle/2
      # centralises the read gate.
      stripped = %Operator{@viewer | role: :__no_role__}

      assert {:ok, text} = Commands.handle({:command, :help, ""}, stripped)
      assert text =~ "does not currently allow read commands"
    end
  end
end
