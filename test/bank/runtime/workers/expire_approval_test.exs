defmodule Bank.Runtime.Workers.ExpireApprovalTest do
  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.PubSub
  alias Bank.Runtime.Workers.ExpireApproval

  defp approval_envelope(intent, opts \\ []) do
    Fixtures.decision_envelope(
      Keyword.merge(
        [
          intent: intent,
          current: true,
          outcome: :approval_required,
          approval_expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          risk_tier: :moderate,
          state: :decided
        ],
        opts
      )
    )
  end

  describe "successful expiry (real transition)" do
    setup do
      intent = Fixtures.agent_intent()

      {:ok, intent} =
        intent
        |> AgentIntent.current_pointer_changeset(%{state: :decided})
        |> Repo.update()

      envelope = approval_envelope(intent)
      %{intent: intent, envelope: envelope}
    end

    test "supersedes the envelope with a :block successor and transitions the intent to :blocked",
         %{intent: intent, envelope: envelope} do
      assert :ok =
               perform_job(ExpireApproval, %{"decision_envelope_id" => envelope.id})

      # prior envelope: current flipped off, still approval_required
      assert %DecisionEnvelope{
               current: false,
               outcome: :approval_required
             } = Repo.get!(DecisionEnvelope, envelope.id)

      # successor is a block envelope, current, superseding the prior
      successor =
        Repo.one!(
          from d in DecisionEnvelope,
            where: d.intent_id == ^intent.id and d.supersedes_id == ^envelope.id
        )

      assert successor.outcome == :block
      assert successor.current == true
      assert successor.state == :resolved
      assert successor.decided_by == :runtime
      assert is_nil(successor.approval_expires_at)
      assert [%{"code" => "approval_expired"}] = successor.reasons["items"]
      # policy snapshot carried forward
      assert successor.policy_snapshot_ref == envelope.policy_snapshot_ref
      # risk tier preserved for observability
      assert successor.risk_tier == envelope.risk_tier

      # intent is blocked and points at the successor
      assert %AgentIntent{state: :blocked, current_decision_id: cd_id} =
               Repo.get!(AgentIntent, intent.id)

      assert cd_id == successor.id
    end

    test "emits decision.decided and intent.state_changed audit events", %{
      intent: intent,
      envelope: envelope
    } do
      assert :ok = perform_job(ExpireApproval, %{"decision_envelope_id" => envelope.id})

      events = Repo.all(AuditEvent)
      event_types = Enum.map(events, & &1.event_type) |> Enum.sort()
      assert "decision.decided" in event_types
      assert "intent.state_changed" in event_types

      [state_change] = Enum.filter(events, &(&1.event_type == "intent.state_changed"))
      assert state_change.correlation_id == intent.id
      assert state_change.before_ref == %{"state" => "decided"}
      assert state_change.after_ref == %{"state" => "blocked"}
    end

    test "broadcasts on approval:queue, intent:{id}, and audit:stream", %{
      intent: intent,
      envelope: envelope
    } do
      :ok = PubSub.subscribe(PubSub.approval_queue())
      :ok = PubSub.subscribe(PubSub.intent(intent.id))
      :ok = PubSub.subscribe(PubSub.audit_stream())

      assert :ok = perform_job(ExpireApproval, %{"decision_envelope_id" => envelope.id})

      envelope_id = envelope.id
      intent_id = intent.id

      assert_receive %{
        topic: :approval_queue,
        event: :expired,
        decision_envelope_id: ^envelope_id,
        payload: %{final_outcome: :block}
      }

      assert_receive %{
        topic: :intent_lifecycle,
        event: :decision_updated,
        intent_id: ^intent_id,
        payload: %{outcome: :block, reason: :approval_expired}
      }

      # At least one audit:stream broadcast arrives — we emit two
      # audit events (decision.decided, intent.state_changed).
      assert_receive %{topic: :audit_stream, event: :appended}
      assert_receive %{topic: :audit_stream, event: :appended}
    end
  end

  describe "idempotency / safety" do
    test "cancels with :already_superseded if prior is already not current" do
      intent = Fixtures.agent_intent()
      envelope = approval_envelope(intent, current: false)

      assert {:cancel, :already_superseded} =
               perform_job(ExpireApproval, %{"decision_envelope_id" => envelope.id})

      # no successor written
      assert Repo.aggregate(DecisionEnvelope, :count) == 1
    end

    test "cancels with {:wrong_outcome, outcome} for a non-approval envelope" do
      envelope = Fixtures.decision_envelope(current: true, outcome: :auto_exec)

      assert {:cancel, {:wrong_outcome, :auto_exec}} =
               perform_job(ExpireApproval, %{"decision_envelope_id" => envelope.id})
    end

    test "cancels with :not_found for an unknown envelope id" do
      assert {:cancel, :not_found} =
               perform_job(ExpireApproval, %{"decision_envelope_id" => Ecto.UUID.generate()})
    end
  end
end
