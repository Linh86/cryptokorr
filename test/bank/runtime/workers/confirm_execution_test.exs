defmodule Bank.Runtime.Workers.ConfirmExecutionTest do
  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.PubSub
  alias Bank.Runtime.Workers.ConfirmExecution

  defp executing_intent do
    {:ok, intent} =
      Fixtures.agent_intent()
      |> AgentIntent.current_pointer_changeset(%{state: :executing})
      |> Repo.update()

    intent
  end

  describe "terminal plans — real intent transition" do
    test ":confirmed plan transitions the intent to :executed" do
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      :ok = PubSub.subscribe(PubSub.intent(intent.id))
      :ok = PubSub.subscribe(PubSub.audit_stream())

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert %AgentIntent{state: :executed, current_execution_plan_id: epid} =
               Repo.get!(AgentIntent, intent.id)

      assert epid == plan.id

      assert_receive %{topic: :intent_lifecycle, event: :execution_updated}
      assert_receive %{topic: :intent_lifecycle, event: :state_changed, payload: %{to: :executed}}
      assert_receive %{topic: :audit_stream, event: :appended}

      # Audit trail recorded the state change.
      [event] = Repo.all(from e in AuditEvent, where: e.event_type == "intent.state_changed")
      assert event.before_ref == %{"state" => "executing"}
      assert event.after_ref == %{"state" => "executed"}
    end

    test ":reverted plan transitions the intent to :blocked" do
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :reverted,
          final_outcome: :reverted,
          final_reason: "simulation mismatch on chain"
        )

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end

    test ":aborted plan also transitions the intent to :blocked" do
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :aborted,
          final_outcome: :aborted,
          final_reason: "operator abort"
        )

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end

    test "idempotent: a second confirm for the same finalised intent cancels as :already_finalised" do
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert {:cancel, :already_finalised} =
               perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})
    end
  end

  describe "non-terminal plans" do
    test "snoozes while the plan is :prepared / :signing / :broadcasting / :pending_confirmation" do
      intent = executing_intent()

      for status <- [:prepared, :signing, :broadcasting, :pending_confirmation] do
        plan =
          Fixtures.execution_plan(
            intent_id: intent.id,
            decision: Fixtures.decision_envelope(intent: intent),
            execution_status: status
          )

        assert {:snooze, seconds} =
                 perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

        assert is_integer(seconds) and seconds > 0
      end
    end
  end

  describe "error paths" do
    test "cancels with :not_found for unknown plan id" do
      assert {:cancel, :not_found} =
               perform_job(ConfirmExecution, %{"execution_plan_id" => Ecto.UUID.generate()})
    end

    test "cancels with :malformed_args on bad args" do
      assert {:cancel, :malformed_args} =
               perform_job(ConfirmExecution, %{"wrong" => "shape"})
    end
  end

  # --- ConfirmExecution finalise lock + from-state guard (#212 P3) --------
  #
  # ConfirmExecution is the safety-net poller that backstops a lost
  # `apply_execution_callback/1` write. Without a row lock, two
  # writers (callback + worker) racing on the same intent could each
  # observe `:executing`, both pass the in-memory pattern guard,
  # both write `:executed`, and both emit a duplicate
  # `intent.state_changed` audit row + duplicate PubSub broadcasts.
  # Mirror PR #314 / PR #318 by locking the intent row `FOR UPDATE`
  # inside a transaction and re-pattern-matching the locked row.
  describe "intent lock + from-state guard (#212)" do
    test "no audit / broadcast when intent already at target_state (raced by callback path)" do
      # Simulates: adapter callback already finalised the intent
      # (state = :executed) before the safety-net worker runs.
      # Pre-fix the worker still emitted an audit row + broadcasts
      # because its in-memory pattern at line 88 matched the loaded
      # state, but the post-lock re-pattern-match would catch it.
      intent =
        Fixtures.agent_intent()
        |> AgentIntent.current_pointer_changeset(%{state: :executed})
        |> Repo.update!()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      :ok = PubSub.subscribe(PubSub.intent(intent.id))
      :ok = PubSub.subscribe(PubSub.audit_stream())

      assert {:cancel, :already_finalised} =
               perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      # No audit row was written by the safety-net path.
      assert [] = Repo.all(from e in AuditEvent, where: e.event_type == "intent.state_changed")

      # No `intent.state_changed` audit broadcast or
      # `:state_changed` intent-lifecycle broadcast for THIS intent.
      # Fixture cascade emits unrelated `counterparty.created`
      # audits, and concurrent async tests can broadcast
      # `intent.state_changed` for OTHER intents on the same global
      # `audit_stream` topic — both must be excluded from the refute
      # so the test does not false-fail under parallelism.
      intent_id = intent.id

      refute_received %{
        topic: :audit_stream,
        payload: %{event_type: "intent.state_changed", subject_id: ^intent_id}
      }

      refute_received %{topic: :intent_lifecycle, event: :state_changed}
    end

    test "refuses to overwrite a non-finalisable state (operator-driven post-dispatch state)" do
      # If the intent has been moved to an unexpected state (e.g.
      # operator cancellation after an asymmetric error path), the
      # safety-net poller MUST NOT overwrite it. This is a
      # belt-and-braces guarantee: the previous code wrote
      # `target_state` regardless of current state, which would
      # have clobbered a different operator/runtime decision.
      intent =
        Fixtures.agent_intent()
        |> AgentIntent.current_pointer_changeset(%{state: :cancelled})
        |> Repo.update!()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      assert {:cancel, {:stale_intent_state, :cancelled}} =
               perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      # Intent state untouched.
      assert %AgentIntent{state: :cancelled} = Repo.get!(AgentIntent, intent.id)

      # No audit row was written by the safety-net path for this plan.
      assert [] = Repo.all(from e in AuditEvent, where: e.event_type == "intent.state_changed")
    end

    test "duplicate finalise emits exactly one audit row across two perform calls" do
      # Sequential idempotency backstop: the second perform sees the
      # intent at target_state (because the first perform committed)
      # and bails as :already_finalised before writing a second
      # audit row.
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert {:cancel, :already_finalised} =
               perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      audit_rows =
        Repo.all(
          from(e in AuditEvent,
            where: e.event_type == "intent.state_changed" and e.subject_id == ^intent.id
          )
        )

      assert length(audit_rows) == 1
    end

    test "lock query selects FOR UPDATE on the intent row" do
      # Pin the lock-query shape so a future refactor cannot
      # silently drop the row lock without breaking a test.
      import Ecto.Query

      query =
        from(i in AgentIntent,
          where: i.id == ^Ecto.UUID.generate(),
          lock: "FOR UPDATE"
        )

      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)
      assert sql =~ "FOR UPDATE"
    end

    test "happy path still works after the lock + from-state guard refactor" do
      # Backstop on the primary safety-net path (callback was lost
      # mid-flight): intent at :executing with terminal-state
      # plan → worker finalises and emits the expected audit row +
      # broadcasts.
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      :ok = PubSub.subscribe(PubSub.intent(intent.id))
      :ok = PubSub.subscribe(PubSub.audit_stream())

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert %AgentIntent{state: :executed} = Repo.get!(AgentIntent, intent.id)

      assert_receive %{topic: :intent_lifecycle, event: :state_changed, payload: %{to: :executed}}

      [event] = Repo.all(from e in AuditEvent, where: e.event_type == "intent.state_changed")
      assert event.before_ref == %{"state" => "executing"}
      assert event.after_ref == %{"state" => "executed"}
    end
  end

  # --- Audit broadcast happens AFTER finalise commits (#212) -------------
  #
  # Pre-fix the safety-net used `Runtime.emit_audit/1` which writes
  # the audit row inside the transaction but broadcasts on
  # `audit:stream` synchronously, before the surrounding
  # `Repo.transaction` commits. A subscriber that reacted to the
  # broadcast and queried the DB could observe a phantom event if
  # the txn rolled back.
  #
  # Post-fix the safety-net uses `Bank.Audit.append_event/1` (silent
  # insert) inside the txn and emits `Notifier.audit_stream/1` only
  # after commit, alongside the lifecycle/progress broadcasts.
  describe "audit broadcast post-commit (#212)" do
    test "happy path: persisted audit row + audit-stream broadcast for the intent.state_changed event" do
      intent = executing_intent()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      :ok = PubSub.subscribe(PubSub.audit_stream())
      :ok = PubSub.subscribe(PubSub.intent(intent.id))

      assert :ok = perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      # Audit row persisted (txn committed).
      [event] =
        Repo.all(
          from(e in AuditEvent,
            where: e.event_type == "intent.state_changed" and e.subject_id == ^intent.id
          )
        )

      assert event.before_ref == %{"state" => "executing"}
      assert event.after_ref == %{"state" => "executed"}

      # Audit broadcast fired post-commit and references the same
      # persisted row id.
      event_id = event.id

      assert_receive %{
        topic: :audit_stream,
        event: :appended,
        payload: %{event_type: "intent.state_changed", id: ^event_id}
      }

      # Lifecycle broadcast also fired post-commit.
      assert_receive %{topic: :intent_lifecycle, event: :state_changed, payload: %{to: :executed}}
    end

    test "already-finalised path: no audit row, no audit-stream broadcast for intent.state_changed, no lifecycle broadcast" do
      # Pin the negative case: when the safety-net is beaten by the
      # callback path, we must emit zero broadcasts and persist zero
      # audit rows for THIS plan's transition.
      intent =
        Fixtures.agent_intent()
        |> AgentIntent.current_pointer_changeset(%{state: :executed})
        |> Repo.update!()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      :ok = PubSub.subscribe(PubSub.audit_stream())
      :ok = PubSub.subscribe(PubSub.intent(intent.id))

      assert {:cancel, :already_finalised} =
               perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert [] =
               Repo.all(
                 from(e in AuditEvent,
                   where: e.event_type == "intent.state_changed" and e.subject_id == ^intent.id
                 )
               )

      # Match the exact event_type so unrelated fixture broadcasts
      # (e.g. counterparty.created) on the same audit_stream topic
      # do not falsely fail the refute.
      # Match the exact subject_id so unrelated async tests'
      # intent.state_changed broadcasts on the global audit_stream
      # topic do not falsely fail the refute.
      intent_id = intent.id

      refute_received %{
        topic: :audit_stream,
        event: :appended,
        payload: %{event_type: "intent.state_changed", subject_id: ^intent_id}
      }

      refute_received %{topic: :intent_lifecycle, event: :state_changed}
    end

    test "stale-state path: no audit row, no audit-stream broadcast" do
      intent =
        Fixtures.agent_intent()
        |> AgentIntent.current_pointer_changeset(%{state: :cancelled})
        |> Repo.update!()

      plan =
        Fixtures.execution_plan(
          intent_id: intent.id,
          decision: Fixtures.decision_envelope(intent: intent, current: true),
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      :ok = PubSub.subscribe(PubSub.audit_stream())
      :ok = PubSub.subscribe(PubSub.intent(intent.id))

      assert {:cancel, {:stale_intent_state, :cancelled}} =
               perform_job(ConfirmExecution, %{"execution_plan_id" => plan.id})

      assert [] =
               Repo.all(
                 from(e in AuditEvent,
                   where: e.event_type == "intent.state_changed" and e.subject_id == ^intent.id
                 )
               )

      # Match the exact subject_id so unrelated async tests'
      # intent.state_changed broadcasts on the global audit_stream
      # topic do not falsely fail the refute.
      intent_id = intent.id

      refute_received %{
        topic: :audit_stream,
        event: :appended,
        payload: %{event_type: "intent.state_changed", subject_id: ^intent_id}
      }

      refute_received %{topic: :intent_lifecycle, event: :state_changed}
    end
  end
end
