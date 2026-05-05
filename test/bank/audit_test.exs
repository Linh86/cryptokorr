defmodule Bank.AuditTest do
  use Bank.DataCase, async: true

  alias Bank.Audit
  alias Bank.Audit.AuditEvent
  alias Bank.Fixtures

  describe "append_event/1" do
    test "writes an event with a canonical payload hash" do
      intent = Fixtures.agent_intent()

      {:ok, event} =
        Audit.append_event(%{
          actor: :runtime,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: intent.id,
          correlation_id: intent.id
        })

      assert event.id
      assert event.payload_hash
      assert String.length(event.payload_hash) == 64
      assert event.schema_version == "1"
      assert %DateTime{} = event.ts
    end

    test "returns changeset error on missing envelope fields" do
      {:error, {:missing_fields, missing}} =
        Audit.append_event(%{actor: :runtime, event_type: "x.y"})

      assert :subject_type in missing
    end
  end

  describe "append_events/1" do
    test "inserts multiple events atomically" do
      intent = Fixtures.agent_intent()

      {:ok, events} =
        Audit.append_events([
          %{
            actor: :runtime,
            event_type: "intent.submitted",
            subject_type: "agent_intent",
            subject_id: intent.id,
            correlation_id: intent.id
          },
          %{
            actor: :runtime,
            event_type: "intent.state_changed",
            subject_type: "agent_intent",
            subject_id: intent.id,
            correlation_id: intent.id,
            before_ref: %{state: "submitted"},
            after_ref: %{state: "evaluating"}
          }
        ])

      assert length(events) == 2
      assert Enum.all?(events, &match?(%AuditEvent{}, &1))
    end

    test "rolls back all writes when any event fails" do
      intent = Fixtures.agent_intent()

      {:error, _} =
        Audit.append_events([
          %{
            actor: :runtime,
            event_type: "intent.submitted",
            subject_type: "agent_intent",
            subject_id: intent.id,
            correlation_id: intent.id
          },
          # missing required field
          %{actor: :runtime}
        ])

      assert Repo.aggregate(AuditEvent, :count) == 0
    end
  end

  describe "append-only posture" do
    test "the public API exposes no update or delete function" do
      mutators =
        Audit.__info__(:functions)
        |> Enum.filter(fn {name, _arity} ->
          s = Atom.to_string(name)
          String.contains?(s, "update") or String.contains?(s, "delete")
        end)

      assert mutators == []
    end

    test "DB trigger rejects an UPDATE on audit_events" do
      event = insert_event()

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(
          from(e in AuditEvent, where: e.id == ^event.id),
          set: [actor: :user]
        )
      end
    end

    test "DB trigger rejects a DELETE on audit_events" do
      event = insert_event()

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete(event)
      end
    end
  end

  describe "list_events/2 filters" do
    setup do
      intent_a = Fixtures.agent_intent()
      intent_b = Fixtures.agent_intent()

      a1 =
        emit!(%{
          actor: :runtime,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: intent_a.id,
          correlation_id: intent_a.id
        })

      a2 =
        emit!(%{
          actor: :runtime,
          event_type: "decision.decided",
          subject_type: "decision_envelope",
          subject_id: Ecto.UUID.generate(),
          correlation_id: intent_a.id
        })

      b1 =
        emit!(%{
          actor: :runtime,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: intent_b.id,
          correlation_id: intent_b.id
        })

      %{intent_a: intent_a, intent_b: intent_b, a1: a1, a2: a2, b1: b1}
    end

    test "by correlation_id", %{intent_a: ia, a1: a1, a2: a2} do
      %{events: events, next_cursor: nil} =
        Audit.list_events(%{correlation_id: ia.id})

      ids = Enum.map(events, & &1.id)
      assert a1.id in ids
      assert a2.id in ids
      assert length(ids) == 2
    end

    test "by event_type", %{a1: a1, b1: b1} do
      %{events: events} = Audit.list_events(%{event_type: "intent.submitted"})
      ids = Enum.map(events, & &1.id)
      assert a1.id in ids
      assert b1.id in ids
      refute Enum.any?(events, &(&1.event_type != "intent.submitted"))
    end

    test "by subject_type + subject_id", %{intent_a: ia, a1: a1} do
      %{events: events} =
        Audit.list_events(%{subject_type: "agent_intent", subject_id: ia.id})

      assert [e] = events
      assert e.id == a1.id
    end

    test "by time range", %{intent_a: ia} do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      %{events: in_range} =
        Audit.list_events(%{correlation_id: ia.id, from: past, to: future})

      assert length(in_range) == 2

      stale = DateTime.add(DateTime.utc_now(), -7200, :second)

      %{events: before} =
        Audit.list_events(%{correlation_id: ia.id, to: stale})

      assert before == []
    end

    test "ordering defaults to ascending, ties break on id", %{intent_a: ia, a1: a1, a2: a2} do
      %{events: events} = Audit.list_events(%{correlation_id: ia.id})
      assert Enum.map(events, & &1.id) == [a1.id, a2.id]
    end

    test "pagination returns a cursor and next page", %{intent_a: ia} do
      # Write extras so the page overflows.
      for _ <- 1..3 do
        emit!(%{
          actor: :runtime,
          event_type: "execution.prepared",
          subject_type: "execution_plan",
          subject_id: Ecto.UUID.generate(),
          correlation_id: ia.id
        })
      end

      %{events: page1, next_cursor: c1} =
        Audit.list_events(%{correlation_id: ia.id}, limit: 2)

      assert length(page1) == 2
      assert is_binary(c1)

      %{events: page2, next_cursor: c2} =
        Audit.list_events(%{correlation_id: ia.id}, limit: 2, cursor: c1)

      # No overlap with page1
      assert MapSet.disjoint?(
               MapSet.new(Enum.map(page1, & &1.id)),
               MapSet.new(Enum.map(page2, & &1.id))
             )

      %{events: page3, next_cursor: c3} =
        Audit.list_events(%{correlation_id: ia.id}, limit: 2, cursor: c2 || c1)

      assert c3 == nil
      assert length(page1) + length(page2) + length(page3) == 5
    end

    test "cursor decode failure on garbage returns everything from the top" do
      # Not a supported contract, but we want to confirm we don't crash.
      %{events: events} = Audit.list_events(%{}, cursor: "@@@not_a_cursor@@@")
      assert is_list(events)
    end
  end

  describe "replay/1" do
    test "returns :not_found for unknown intent" do
      assert {:error, :not_found} = Audit.replay(Ecto.UUID.generate())
    end

    test "assembles a bundle with every child collection ordered oldest-first" do
      intent = Fixtures.agent_intent()
      rule = Fixtures.policy_rule()

      # Two claims in supersession order
      claim1 = Fixtures.trust_assessment(intent: intent, current: false)
      claim2 = Fixtures.trust_assessment(intent: intent, current: true)

      # Two decisions, second captures the rule in its policy snapshot
      dec1 = Fixtures.decision_envelope(intent: intent, current: false)

      dec2 =
        Fixtures.decision_envelope(
          intent: intent,
          current: true,
          policy_snapshot_ref: %{"rule_ids" => [rule.id]}
        )

      sim = Fixtures.simulation_report(intent: intent, current: true)
      plan = Fixtures.execution_plan(decision: dec2)

      emit!(%{
        actor: :runtime,
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id
      })

      emit!(%{
        actor: :runtime,
        event_type: "decision.decided",
        subject_type: "decision_envelope",
        subject_id: dec1.id,
        correlation_id: intent.id
      })

      {:ok, bundle} = Audit.replay(intent.id)

      assert bundle.intent.id == intent.id
      assert Enum.map(bundle.trust_assessments, & &1.id) == [claim1.id, claim2.id]
      assert Enum.map(bundle.simulations, & &1.id) == [sim.id]
      assert Enum.map(bundle.decisions, & &1.id) == [dec1.id, dec2.id]
      assert Enum.map(bundle.plans, & &1.id) == [plan.id]
      assert Enum.map(bundle.policy_snapshot, & &1.id) == [rule.id]
      assert length(bundle.audit) == 2
      assert Enum.all?(bundle.audit, &(&1.correlation_id == intent.id))
    end

    test "audit events are ordered by ts, then id" do
      intent = Fixtures.agent_intent()

      t0 = DateTime.from_naive!(~N[2026-04-15 12:00:00.000000], "Etc/UTC")
      t1 = DateTime.from_naive!(~N[2026-04-15 12:00:01.000000], "Etc/UTC")

      emit!(%{
        ts: t1,
        actor: :runtime,
        event_type: "decision.decided",
        subject_type: "decision_envelope",
        subject_id: Ecto.UUID.generate(),
        correlation_id: intent.id
      })

      emit!(%{
        ts: t0,
        actor: :runtime,
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id
      })

      {:ok, bundle} = Audit.replay(intent.id)
      ts_list = Enum.map(bundle.audit, & &1.ts)
      assert ts_list == Enum.sort(ts_list, DateTime)
    end

    test "bundle includes :matched_activities key (#246) — empty by default, populated when imported activity matches a plan tx_ref" do
      # Reconciliation surface (#246): the replay bundle should carry a
      # `:matched_activities` list whose entries link an imported
      # chain activity row to the execution plan whose `tx_refs`
      # cite the same `tx_hash`. Workspace-scoped, chain-scoped.
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "audit-recon-#{System.unique_integer([:positive])}",
          name: "Audit Recon",
          mainnet_enabled: true
        })

      intent = Fixtures.agent_intent(workspace_id: ws.id)
      decision = Fixtures.decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      tx_hash = "0xreplay" <> String.duplicate("a", 38)

      plan =
        Fixtures.execution_plan(
          decision: decision,
          intent_id: intent.id,
          workspace_id: ws.id,
          execution_status: :confirmed,
          final_outcome: :confirmed,
          tx_refs: [tx_hash],
          chain: intent.chain
        )

      # An imported activity in the same workspace + chain that
      # cites the same tx_hash.
      {:ok, :inserted, activity} =
        Bank.Activity.create_imported_activity(%{
          workspace_id: ws.id,
          source_type: :wallet_chain,
          source_ref: "wallet:replay",
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
          asset: "USDC",
          chain: intent.chain,
          amount: Decimal.new("100"),
          direction: :inbound,
          status: :confirmed,
          confidence: :high,
          tx_hash: tx_hash
        })

      {:ok, bundle} = Audit.replay(intent.id)

      assert Map.has_key?(bundle, :matched_activities)
      assert [match] = bundle.matched_activities
      assert match.activity.id == activity.id
      assert match.plan_id == plan.id
      assert match.tx_hash == tx_hash
    end

    test "bundle :matched_activities is empty when no plan cites a known tx_hash" do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "audit-recon-empty-#{System.unique_integer([:positive])}",
          name: "Audit Recon Empty",
          mainnet_enabled: true
        })

      intent = Fixtures.agent_intent(workspace_id: ws.id)
      _decision = Fixtures.decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      {:ok, bundle} = Audit.replay(intent.id)
      assert bundle.matched_activities == []
    end

    test "ignores cached current_*_id pointers on the intent" do
      # The bundle must come from the child tables, not the cached
      # pointer columns. Set a bogus pointer and verify replay still
      # returns the actual persisted claim.
      intent = Fixtures.agent_intent()
      claim = Fixtures.trust_assessment(intent: intent, current: true)

      {:ok, _} =
        intent
        |> Ecto.Changeset.change(current_trust_assessment_id: Ecto.UUID.generate())
        |> Repo.update()

      {:ok, bundle} = Audit.replay(intent.id)
      assert Enum.map(bundle.trust_assessments, & &1.id) == [claim.id]
    end
  end

  describe "cursor round-trip" do
    test "encodes and decodes without data loss" do
      event = insert_event()
      cursor = Audit.cursor(event)
      assert {:ok, {ts, id}} = Audit.decode_cursor(cursor)
      assert ts == event.ts
      assert id == event.id
    end

    test "decode returns :error on garbage" do
      assert :error = Audit.decode_cursor("not base64")
      assert :error = Audit.decode_cursor(Base.url_encode64("{}", padding: false))
    end
  end

  defp emit!(attrs) do
    {:ok, event} = Audit.append_event(attrs)
    event
  end

  defp insert_event do
    emit!(%{
      actor: :runtime,
      event_type: "intent.submitted",
      subject_type: "agent_intent",
      subject_id: Ecto.UUID.generate(),
      correlation_id: Ecto.UUID.generate()
    })
  end
end
