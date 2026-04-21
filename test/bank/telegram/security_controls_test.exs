defmodule Bank.Telegram.SecurityControlsTest do
  @moduledoc """
  Tests for the Telegram runtime pause / resume step-up flow (#73).

  The text command only renders a confirmation button. The state
  mutation happens through the same callback-query boundary as #72, so
  these tests exercise both `Bank.Telegram.SecurityControls` and the
  delegated `Bank.Telegram.Callbacks.handle/3` path.
  """

  use Bank.DataCase, async: false

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Repo
  alias Bank.Security
  alias Bank.Security.PauseState
  alias Bank.Telegram.CallbackToken
  alias Bank.Telegram.Callbacks
  alias Bank.Telegram.Operator
  alias Bank.Telegram.SecurityControls

  @viewer %Operator{user_id: 1001, chat_id: 50, role: :viewer, audit_actor: "ops-reader"}
  @approver %Operator{user_id: 1002, chat_id: 60, role: :approver, audit_actor: "ops-alice"}
  @security_op %Operator{
    user_id: 1003,
    chat_id: 70,
    role: :security_operator,
    audit_actor: "ops-bob"
  }
  @admin %Operator{user_id: 1004, chat_id: 80, role: :admin, audit_actor: "ops-root"}

  setup do
    PauseState.reset()
    :ok
  end

  describe "parse_command/1" do
    test "recognises /pause and /resume without taking over read commands" do
      assert {:ok, :pause} = SecurityControls.parse_command("/pause")
      assert {:ok, :resume} = SecurityControls.parse_command("/Resume now")
      assert :not_security_command = SecurityControls.parse_command("/status")
      assert :not_security_command = SecurityControls.parse_command("/unknown")
      assert :not_a_command = SecurityControls.parse_command("hello")
    end

    test "ignores @BotName-suffixed security commands" do
      assert :not_a_command = SecurityControls.parse_command("/pause@OtherBot")
      assert :not_a_command = SecurityControls.parse_command("/resume@BankBot now")
    end
  end

  describe "confirmation/2" do
    test "security operator gets a short-lived actor-bound pause button" do
      assert {:ok, text, [[button]]} = SecurityControls.confirmation(@security_op, :pause)

      assert text =~ "Confirm runtime pause"
      assert text =~ "/security"
      assert button.label == "Confirm pause"

      assert {:ok, payload} =
               CallbackToken.verify(
                 button.callback_data,
                 @security_op.user_id,
                 @security_op.chat_id
               )

      assert payload.action == :pause
      assert payload.target_id == SecurityControls.runtime_control_target_id()
    end

    test "admin gets a resume button" do
      assert {:ok, text, [[button]]} = SecurityControls.confirmation(@admin, :resume)

      assert text =~ "Confirm runtime resume"
      assert button.label == "Confirm resume"

      assert {:ok, %{action: :resume}} =
               CallbackToken.verify(button.callback_data, @admin.user_id, @admin.chat_id)
    end

    test "viewer and approver do not get high-risk controls" do
      assert {:error, :forbidden, text, []} = SecurityControls.confirmation(@viewer, :pause)
      assert text =~ "Not authorized"

      assert {:error, :forbidden, _text, []} = SecurityControls.confirmation(@approver, :resume)
    end
  end

  describe "callbacks — pause" do
    test "valid pause confirmation pauses runtime and records Telegram actor attribution" do
      token = sign(@security_op, :pause)

      assert {:ok, "Runtime paused."} =
               Callbacks.handle(@security_op, callback(@security_op, token))

      assert Security.paused?(:global)

      event = latest_event!("security.paused")
      assert event.actor == :user
      assert event.actor_id == "telegram:ops-bob"
      assert event.subject_type == "runtime"
      assert event.subject_id == "global"
    end

    test "replayed pause confirmation is idempotent and does not emit duplicate audit" do
      token = sign(@security_op, :pause)

      assert {:ok, "Runtime paused."} =
               Callbacks.handle(@security_op, callback(@security_op, token))

      before = count_events("security.paused")

      assert {:error, :already_paused, "Runtime already paused."} =
               Callbacks.handle(@security_op, callback(@security_op, token))

      assert count_events("security.paused") == before
    end

    test "approver role cannot pause even with a token bound to that actor" do
      token = sign(@approver, :pause)

      assert {:error, :forbidden, "Not authorized."} =
               Callbacks.handle(@approver, callback(@approver, token))

      refute Security.paused?(:global)
    end
  end

  describe "callbacks — resume" do
    test "valid resume confirmation resumes runtime" do
      {:ok, :paused} = Security.pause(:global, reason: :incident)
      token = sign(@security_op, :resume)

      assert {:ok, "Runtime resumed."} =
               Callbacks.handle(@security_op, callback(@security_op, token))

      refute Security.paused?(:global)

      event = latest_event!("security.resumed")
      assert event.actor_id == "telegram:ops-bob"
    end

    test "resume while running is deterministic and non-mutating" do
      token = sign(@security_op, :resume)
      before = count_events("security.resumed")

      assert {:error, :already_running, "Runtime already running."} =
               Callbacks.handle(@security_op, callback(@security_op, token))

      assert count_events("security.resumed") == before
    end
  end

  describe "callbacks — token safety" do
    test "expired confirmation is rejected safely" do
      now = System.system_time(:second)
      token = sign(@security_op, :pause, now: now - 120, max_age: 60)

      assert {:error, :expired, text} =
               Callbacks.handle(@security_op, callback(@security_op, token), now: now)

      assert text =~ "expired"
      refute Security.paused?(:global)
    end

    test "tampered confirmation is rejected safely" do
      token = sign(@security_op, :pause) |> flip_last_byte()

      assert {:error, :invalid, "Invalid button."} =
               Callbacks.handle(@security_op, callback(@security_op, token))

      refute Security.paused?(:global)
    end

    test "forwarded confirmation from another chat is rejected safely" do
      token = sign(@security_op, :pause)

      assert {:error, :actor_mismatch, "This button is not yours."} =
               Callbacks.handle(@security_op, callback(@security_op, token, %{chat_id: 999}))

      refute Security.paused?(:global)
    end

    test "pause token with a non-runtime target is rejected safely" do
      token = CallbackToken.sign(@security_op, :pause, Ecto.UUID.generate())

      assert {:error, :wrong_target, "Invalid confirmation."} =
               Callbacks.handle(@security_op, callback(@security_op, token))

      refute Security.paused?(:global)
    end
  end

  defp sign(%Operator{} = op, action, opts \\ []) do
    CallbackToken.sign(op, action, SecurityControls.runtime_control_target_id(), opts)
  end

  defp callback(%Operator{} = op, token, overrides \\ %{}) do
    Map.merge(
      %{
        query_id: "cbq-security",
        user_id: op.user_id,
        chat_id: op.chat_id,
        message_id: 42,
        update_id: 1,
        data: token
      },
      overrides
    )
  end

  defp latest_event!(event_type) do
    AuditEvent
    |> where([e], e.event_type == ^event_type)
    |> order_by([e], desc: e.ts, desc: e.id)
    |> limit(1)
    |> Repo.one!()
  end

  defp count_events(event_type) do
    AuditEvent
    |> where([e], e.event_type == ^event_type)
    |> Repo.aggregate(:count, :id)
  end

  defp flip_last_byte(token) do
    {head, <<last>>} = String.split_at(token, byte_size(token) - 1)
    replacement = if last == ?A, do: ?B, else: ?A
    head <> <<replacement>>
  end
end
