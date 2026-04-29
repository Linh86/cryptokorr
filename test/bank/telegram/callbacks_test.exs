defmodule Bank.Telegram.CallbacksTest do
  @moduledoc """
  Tests for `Bank.Telegram.Callbacks` — the module that maps signed
  Telegram inline-button presses onto the real decision approval
  state machine (issue #72, epic #54).

  Covered boundaries:

    * signed-token verification (valid / malformed / tampered /
      expired / actor-mismatched);
    * role capability (a viewer's button press is refused even if
      the token somehow reached them);
    * decision state-machine edge cases (not-found, already
      superseded, wrong outcome);
    * audit attribution (`actor_id: "telegram:ops-..."`);
    * action-code gating (unsupported action atoms such as `:pause`
      are refused by this module).

  The module never touches the Telegram HTTP API — the controller
  owns the `answer_callback_query` call. The tests therefore do not
  install any `Req.Test` stub on `Bank.Telegram.Transport`; a
  regression that started making HTTP from here would fail loudly.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Bank.Fixtures

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions
  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Telegram.CallbackToken
  alias Bank.Telegram.Callbacks
  alias Bank.Telegram.Operator

  @approver %Operator{
    user_id: 100,
    chat_id: 200,
    role: :approver,
    audit_actor: "ops-alice"
  }

  @viewer %Operator{
    user_id: 101,
    chat_id: 201,
    role: :viewer,
    audit_actor: "ops-view"
  }

  setup do
    original = Application.get_env(:bank, Bank.Telegram.Config)

    Application.put_env(:bank, Bank.Telegram.Config,
      enabled: true,
      bot_token: "test-bot-token",
      webhook_secret: "test-webhook-secret",
      operators: [@approver, @viewer]
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

  defp callback_for(%Operator{} = op, token, overrides \\ %{}) do
    Map.merge(
      %{
        query_id: "cbq-1",
        user_id: op.user_id,
        chat_id: op.chat_id,
        message_id: 20,
        update_id: 1,
        data: token
      },
      overrides
    )
  end

  describe "handle/3 — valid approve" do
    test "mutates the decision and returns :ok with a short success text" do
      envelope = pending_approval_envelope()
      token = CallbackToken.sign(@approver, :approve, envelope.id)

      assert {:ok, "Approved."} = Callbacks.handle(@approver, callback_for(@approver, token))

      successor = Decisions.get_envelope(envelope.id) |> then(fn {:ok, e} -> e end)
      refute successor.current

      updated = Repo.get_by!(DecisionEnvelope, supersedes_id: envelope.id)
      assert updated.outcome == :auto_exec
      assert updated.state == :decided
      assert updated.current
    end

    test "audit row uses actor_id with a 'telegram:' surface prefix" do
      envelope = pending_approval_envelope()
      token = CallbackToken.sign(@approver, :approve, envelope.id)

      {:ok, "Approved."} = Callbacks.handle(@approver, callback_for(@approver, token))

      audit =
        Repo.one!(
          from a in AuditEvent,
            where: a.event_type == "approval.granted",
            order_by: [desc: a.inserted_at],
            limit: 1
        )

      assert audit.actor_id == "telegram:ops-alice"
      assert audit.actor == :user
      assert audit.subject_id == envelope.id
    end
  end

  describe "handle/3 — valid reject" do
    test "mutates the decision and returns :ok with a short reject text" do
      envelope = pending_approval_envelope()
      token = CallbackToken.sign(@approver, :reject, envelope.id)

      assert {:ok, "Rejected."} = Callbacks.handle(@approver, callback_for(@approver, token))

      updated = Repo.get_by!(DecisionEnvelope, supersedes_id: envelope.id)
      assert updated.outcome == :block
      assert updated.state == :resolved
      assert updated.current
    end

    test "audit row records approval.rejected with the telegram-prefixed actor_id" do
      envelope = pending_approval_envelope()
      token = CallbackToken.sign(@approver, :reject, envelope.id)

      {:ok, "Rejected."} = Callbacks.handle(@approver, callback_for(@approver, token))

      audit =
        Repo.one!(
          from a in AuditEvent,
            where: a.event_type == "approval.rejected",
            order_by: [desc: a.inserted_at],
            limit: 1
        )

      assert audit.actor_id == "telegram:ops-alice"
      assert audit.subject_id == envelope.id
    end
  end

  describe "handle/3 — token verification" do
    test "rejects an expired token without touching the database" do
      envelope = pending_approval_envelope()
      now = System.system_time(:second)
      token = CallbackToken.sign(@approver, :approve, envelope.id, now: now - 3600)

      assert {:error, :expired, text} =
               Callbacks.handle(@approver, callback_for(@approver, token), now: now)

      assert text =~ "expired"

      # Envelope unchanged.
      {:ok, reloaded} = Decisions.get_envelope(envelope.id)
      assert reloaded.current
      assert reloaded.outcome == :approval_required
    end

    test "rejects a malformed callback_data string as :malformed" do
      envelope = pending_approval_envelope()

      assert {:error, :malformed, "Invalid button."} =
               Callbacks.handle(@approver, callback_for(@approver, "not-base64!!"))

      {:ok, reloaded} = Decisions.get_envelope(envelope.id)
      assert reloaded.current
    end

    test "rejects a tampered HMAC as :invalid" do
      envelope = pending_approval_envelope()
      token = CallbackToken.sign(@approver, :approve, envelope.id)
      tampered = flip_last_byte(token)

      assert {:error, :invalid, "Invalid button."} =
               Callbacks.handle(@approver, callback_for(@approver, tampered))

      {:ok, reloaded} = Decisions.get_envelope(envelope.id)
      assert reloaded.current
    end

    test "rejects a token bound to a different chat as :actor_mismatch" do
      envelope = pending_approval_envelope()
      # Token signed for @approver, but presented by an operator whose
      # chat_id does not match — e.g. a forwarded button.
      token = CallbackToken.sign(@approver, :approve, envelope.id)

      wrong_chat_cb =
        callback_for(@approver, token, %{chat_id: @approver.chat_id + 999})

      assert {:error, :actor_mismatch, _} = Callbacks.handle(@approver, wrong_chat_cb)

      {:ok, reloaded} = Decisions.get_envelope(envelope.id)
      assert reloaded.current
    end
  end

  describe "handle/3 — role boundary" do
    test "refuses a viewer even if their token verifies" do
      envelope = pending_approval_envelope()
      token = CallbackToken.sign(@viewer, :approve, envelope.id)

      assert {:error, :forbidden, "Not authorized."} =
               Callbacks.handle(@viewer, callback_for(@viewer, token))

      {:ok, reloaded} = Decisions.get_envelope(envelope.id)
      assert reloaded.current
    end
  end

  describe "handle/3 — unsupported action" do
    test "refuses an otherwise-valid :open_replay token as :unsupported_action" do
      envelope = pending_approval_envelope()
      token = CallbackToken.sign(@approver, :open_replay, envelope.id)

      assert {:error, :unsupported_action, _} =
               Callbacks.handle(@approver, callback_for(@approver, token))

      {:ok, reloaded} = Decisions.get_envelope(envelope.id)
      assert reloaded.current
    end
  end

  describe "handle/3 — decision state-machine edge cases" do
    test "returns :already_resolved when the envelope was already approved by someone else" do
      envelope = pending_approval_envelope()
      token = CallbackToken.sign(@approver, :approve, envelope.id)

      # No delegation seeded -> dispatch is held; the successor envelope
      # is still written, which is what this test cares about. The
      # `{:held, _}` shape is the new (#140) approve return value.
      {:ok, _, {:held, _}} = Decisions.approve(envelope.id, actor_id: "someone-else")

      assert {:error, :already_resolved, "Decision already resolved."} =
               Callbacks.handle(@approver, callback_for(@approver, token))
    end

    test "returns :already_resolved when the envelope's outcome is not approval_required" do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :auto_exec,
          current: true
        )

      token = CallbackToken.sign(@approver, :approve, envelope.id)

      assert {:error, :already_resolved, "Decision already resolved."} =
               Callbacks.handle(@approver, callback_for(@approver, token))
    end

    test "returns :not_found when the decision UUID does not exist" do
      missing_id = Ecto.UUID.generate()
      token = CallbackToken.sign(@approver, :approve, missing_id)

      assert {:error, :not_found, "Decision not found."} =
               Callbacks.handle(@approver, callback_for(@approver, token))
    end
  end

  defp flip_last_byte(token) do
    # Edit the last Base64-url character so the decoded HMAC bytes
    # differ. Works on a 64-char Base64-url string.
    {head, <<last>>} = String.split_at(token, byte_size(token) - 1)
    replacement = if last == ?A, do: ?B, else: ?A
    head <> <<replacement>>
  end
end
