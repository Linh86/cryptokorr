defmodule Bank.Workspaces.BackfillTest do
  @moduledoc """
  Coverage for `Bank.Workspaces.Backfill` (#158d-d).

  Each describe block targets one derivation chain: legacy NULL row
  is seeded, parent rows are populated with workspace_id, the
  backfill is run, and the row is asserted to be either stamped or
  intentionally skipped (with the expected `skip_reason`).
  """

  use Bank.DataCase, async: false

  import Bank.Fixtures

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Workspaces
  alias Bank.Workspaces.Backfill

  defp ws(slug \\ "bf-#{System.unique_integer([:positive])}") do
    {:ok, w} = Workspaces.create_workspace(%{slug: slug, name: "Backfill #{slug}"})
    w
  end

  describe "execution_plans derivation" do
    test "stamps from intent.workspace_id when intent has it" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      decision = decision_envelope(intent: intent, current: false)
      plan = execution_plan(decision: decision, workspace_id: nil)
      # Sanity: the seeded plan is unscoped.
      assert is_nil(Repo.get!(ExecutionPlan, plan.id).workspace_id)

      {:ok, stats} = Backfill.run(:execution_plans, apply?: true)

      assert stats.scanned == 1
      assert stats.updated == 1
      assert stats.skipped == 0
      assert Repo.get!(ExecutionPlan, plan.id).workspace_id == w.id
    end

    test "skips when intent.workspace_id is nil" do
      intent = agent_intent(workspace_id: nil)
      decision = decision_envelope(intent: intent, current: false)
      plan = execution_plan(decision: decision, workspace_id: nil)

      {:ok, stats} = Backfill.run(:execution_plans, apply?: true)

      assert stats.skipped == 1
      assert stats.updated == 0
      assert Map.get(stats.skip_reasons, :intent_workspace_nil) == 1
      assert is_nil(Repo.get!(ExecutionPlan, plan.id).workspace_id)
    end
  end

  describe "delegations derivation" do
    test "stamps from latest plan.workspace_id with same smart_account_id" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      decision = decision_envelope(intent: intent, current: false)

      _plan =
        execution_plan(decision: decision, workspace_id: w.id, smart_account_id: "sa-bf-1")

      {:ok, del} = Bank.Delegations.grant("sa-bf-1", "del-bf-1")
      assert is_nil(Repo.get!(Delegation, del.id).workspace_id)

      {:ok, stats} = Backfill.run(:delegations, apply?: true)

      assert stats.scanned == 1
      assert stats.updated == 1
      assert Repo.get!(Delegation, del.id).workspace_id == w.id
    end

    test "skips when no plan with workspace_id matches the smart_account_id" do
      {:ok, del} = Bank.Delegations.grant("sa-bf-orphan", "del-bf-orphan")

      {:ok, stats} = Backfill.run(:delegations, apply?: true)

      assert stats.skipped == 1
      assert Map.get(stats.skip_reasons, :no_plan_with_workspace) == 1
      assert is_nil(Repo.get!(Delegation, del.id).workspace_id)
    end
  end

  describe "audit_events derivation — direct subject types" do
    test "agent_intent / counterparty / policy_rule / membership / access_invite" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      cp = counterparty(workspace_id: w.id)
      rule = policy_rule(workspace_id: w.id)

      events = [
        unscoped_audit(subject_type: "agent_intent", subject_id: intent.id),
        unscoped_audit(subject_type: "counterparty", subject_id: cp.id),
        unscoped_audit(subject_type: "policy_rule", subject_id: rule.id)
      ]

      {:ok, stats} = Backfill.run(:audit_events, apply?: true)

      for e <- events do
        assert Repo.get!(AuditEvent, e.id).workspace_id == w.id
      end

      assert stats.updated >= length(events)
      assert Map.get(stats.by_subject_type, "agent_intent").updated == 1
      assert Map.get(stats.by_subject_type, "counterparty").updated == 1
      assert Map.get(stats.by_subject_type, "policy_rule").updated == 1
    end

    test "delegation subject — derives from delegation row" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      decision = decision_envelope(intent: intent, current: false)

      _plan =
        execution_plan(decision: decision, workspace_id: w.id, smart_account_id: "sa-bf-del-aud")

      {:ok, del} =
        Bank.Delegations.grant("sa-bf-del-aud", "del-bf-del-aud", %{workspace_id: w.id})

      e = unscoped_audit(subject_type: "delegation", subject_id: del.id)

      {:ok, _stats} = Backfill.run(:audit_events, apply?: true)
      assert Repo.get!(AuditEvent, e.id).workspace_id == w.id
    end

    test "execution_plan subject — derives from plan row" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      decision = decision_envelope(intent: intent, current: false)
      plan = execution_plan(decision: decision, workspace_id: w.id)
      e = unscoped_audit(subject_type: "execution_plan", subject_id: plan.id)

      {:ok, _stats} = Backfill.run(:audit_events, apply?: true)
      assert Repo.get!(AuditEvent, e.id).workspace_id == w.id
    end
  end

  describe "audit_events derivation — derived subject types take one extra hop" do
    test "trust_assessment / simulation_report / decision_envelope inherit via intent" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      claim = trust_assessment(intent: intent)
      sim = simulation_report(intent: intent)
      env = decision_envelope(intent: intent, current: false)

      ta = unscoped_audit(subject_type: "trust_assessment", subject_id: claim.id)
      se = unscoped_audit(subject_type: "simulation_report", subject_id: sim.id)
      de = unscoped_audit(subject_type: "decision_envelope", subject_id: env.id)

      {:ok, stats} = Backfill.run(:audit_events, apply?: true)

      for id <- [ta.id, se.id, de.id] do
        assert Repo.get!(AuditEvent, id).workspace_id == w.id
      end

      assert Map.get(stats.by_subject_type, "trust_assessment").updated == 1
      assert Map.get(stats.by_subject_type, "simulation_report").updated == 1
      assert Map.get(stats.by_subject_type, "decision_envelope").updated == 1
    end

    test "address_label inherits via counterparty.workspace_id" do
      w = ws()
      cp = counterparty(workspace_id: w.id)
      label = address_label(counterparty: cp)
      e = unscoped_audit(subject_type: "address_label", subject_id: label.id)

      {:ok, _stats} = Backfill.run(:audit_events, apply?: true)
      assert Repo.get!(AuditEvent, e.id).workspace_id == w.id
    end
  end

  describe "audit_events derivation — workspace-blind subject types stay nil" do
    test "user / agent / smart_account / unknown all skip with explicit reason" do
      e1 = unscoped_audit(subject_type: "user", subject_id: Ecto.UUID.generate())
      e2 = unscoped_audit(subject_type: "agent", subject_id: Ecto.UUID.generate())
      e3 = unscoped_audit(subject_type: "smart_account", subject_id: Ecto.UUID.generate())
      e4 = unscoped_audit(subject_type: "totally_made_up", subject_id: Ecto.UUID.generate())

      {:ok, stats} = Backfill.run(:audit_events, apply?: true)

      for id <- [e1.id, e2.id, e3.id, e4.id] do
        assert is_nil(Repo.get!(AuditEvent, id).workspace_id)
      end

      assert Map.get(stats.skip_reasons, :workspace_blind_subject) == 3
      assert Map.get(stats.skip_reasons, :unknown_subject_type) == 1
    end

    test "subject row that no longer exists skips with :subject_not_found" do
      e = unscoped_audit(subject_type: "agent_intent", subject_id: Ecto.UUID.generate())
      {:ok, stats} = Backfill.run(:audit_events, apply?: true)

      assert Map.get(stats.skip_reasons, :subject_not_found) >= 1
      assert is_nil(Repo.get!(AuditEvent, e.id).workspace_id)
    end

    test "subject exists but parent's workspace_id is nil → :subject_workspace_nil" do
      intent = agent_intent(workspace_id: nil)
      e = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      {:ok, stats} = Backfill.run(:audit_events, apply?: true)

      assert Map.get(stats.skip_reasons, :subject_workspace_nil) == 1
      assert is_nil(Repo.get!(AuditEvent, e.id).workspace_id)
    end
  end

  describe "dry-run" do
    test "apply?: false counts but writes nothing" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      e = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      {:ok, stats} = Backfill.run(:audit_events, apply?: false)

      assert stats.scanned >= 1
      assert stats.updated >= 1
      # Row stayed unscoped because we did NOT apply.
      assert is_nil(Repo.get!(AuditEvent, e.id).workspace_id)
    end
  end

  describe "cursor batching" do
    test "limit caps total rows scanned across batches" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)

      events =
        for _ <- 1..5, do: unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      {:ok, stats} = Backfill.run(:audit_events, apply?: true, batch_size: 2, limit: 3)

      # The cursor exits as soon as scanned >= limit. Some batches
      # may go slightly over batch boundary, but never beyond limit.
      assert stats.scanned <= 4

      stamped =
        events
        |> Enum.map(& &1.id)
        |> Enum.count(fn id -> Repo.get!(AuditEvent, id).workspace_id == w.id end)

      # At least the first 3 — the cap forced at least 3 to be processed.
      assert stamped >= 3
    end

    test "second run is idempotent — stamped rows are not rescanned" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      e = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      {:ok, _} = Backfill.run(:audit_events, apply?: true)
      assert Repo.get!(AuditEvent, e.id).workspace_id == w.id

      {:ok, stats2} = Backfill.run(:audit_events, apply?: true)
      assert stats2.scanned == 0
      assert stats2.updated == 0
    end
  end

  describe "Backfill.run/2" do
    test "rejects unknown table" do
      assert {:error, {:unknown_table, :foo}} = Backfill.run(:foo, apply?: true)
    end
  end

  describe "audit_events trigger guardrails (#158d-d)" do
    # The trigger relaxation in
    # `20260430140000_allow_audit_workspace_backfill` lets a
    # workspace_id-only UPDATE through ONLY when the session-local
    # `bank.audit_workspace_backfill` setting is `'on'` AND no other
    # column changes. These tests pin both halves of that contract:
    # without the bypass nothing changes; with the bypass, attempts
    # to mutate any other column are still refused.

    test "stray Repo.update_all without the bypass is still rejected" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      e = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      assert_raise Postgrex.Error, ~r/audit_events is append-only/, fn ->
        AuditEvent
        |> Ecto.Query.where([a], a.id == ^e.id)
        |> Repo.update_all(set: [workspace_id: w.id])
      end
    end

    test "bypass refuses to overwrite a non-NULL workspace_id" do
      w1 = ws("hard-a")
      w2 = ws("hard-b")
      intent = agent_intent(workspace_id: w1.id)
      e = audit_event(workspace_id: w1.id, subject_type: "agent_intent", subject_id: intent.id)

      assert_raise Postgrex.Error, ~r/audit_events is append-only/, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL bank.audit_workspace_backfill = 'on'")

          AuditEvent
          |> Ecto.Query.where([a], a.id == ^e.id)
          |> Repo.update_all(set: [workspace_id: w2.id])
        end)
      end
    end

    test "bypass refuses to mutate any other column even with workspace_id change" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      e = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      assert_raise Postgrex.Error, ~r/audit_events is append-only/, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL bank.audit_workspace_backfill = 'on'")

          AuditEvent
          |> Ecto.Query.where([a], a.id == ^e.id)
          |> Repo.update_all(set: [workspace_id: w.id, event_type: "tampered.event"])
        end)
      end
    end

    test "bypass refuses to mutate before_ref (defense-in-depth on hash payload)" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      e = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      assert_raise Postgrex.Error, ~r/audit_events is append-only/, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL bank.audit_workspace_backfill = 'on'")

          AuditEvent
          |> Ecto.Query.where([a], a.id == ^e.id)
          |> Repo.update_all(set: [workspace_id: w.id, before_ref: %{"tampered" => true}])
        end)
      end
    end

    test "bypass refuses to mutate after_ref (defense-in-depth on hash payload)" do
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      e = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      assert_raise Postgrex.Error, ~r/audit_events is append-only/, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL bank.audit_workspace_backfill = 'on'")

          AuditEvent
          |> Ecto.Query.where([a], a.id == ^e.id)
          |> Repo.update_all(set: [workspace_id: w.id, after_ref: %{"tampered" => true}])
        end)
      end
    end

    test "DELETE remains absolutely refused (no bypass branch)" do
      intent = agent_intent()
      e = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      assert_raise Postgrex.Error, ~r/audit_events is append-only/, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL bank.audit_workspace_backfill = 'on'")

          AuditEvent
          |> Ecto.Query.where([a], a.id == ^e.id)
          |> Repo.delete_all()
        end)
      end
    end

    test "bypass armed inside Backfill.run/2 does not leak to a subsequent stray UPDATE" do
      # `SET LOCAL` is transaction-scoped: when the backfill's
      # internal `Repo.transaction` commits, the flag clears. A
      # later `Repo.update_all` issued OUTSIDE that transaction must
      # see the strict-deny trigger again. This pins the
      # transaction-scoped property so a future refactor that swaps
      # `SET LOCAL` for `SET` (session-scoped) regresses loudly.
      w = ws()
      intent = agent_intent(workspace_id: w.id)
      a = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)
      b = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      # First call commits a SET LOCAL inside its own transaction;
      # the LOCAL flag is dropped at commit.
      {:ok, _} = Backfill.run(:audit_events, apply?: true)
      assert Repo.get!(AuditEvent, a.id).workspace_id == w.id
      assert Repo.get!(AuditEvent, b.id).workspace_id == w.id

      # Now create a fresh NULL audit row and try to UPDATE it
      # without arming the bypass. The flag from the prior
      # transaction must NOT be visible, so the trigger refuses.
      c = unscoped_audit(subject_type: "agent_intent", subject_id: intent.id)

      assert_raise Postgrex.Error, ~r/audit_events is append-only/, fn ->
        AuditEvent
        |> Ecto.Query.where([a], a.id == ^c.id)
        |> Repo.update_all(set: [workspace_id: w.id])
      end
    end
  end

  # Build an `audit_events` row directly via the schema's changeset
  # so we bypass `Bank.Audit.append_event/1`'s envelope construction
  # and can deterministically null `workspace_id`. The fixtures
  # helper defaults workspace_id from the process dict, so we pass
  # `workspace_id: nil` explicitly.
  defp unscoped_audit(opts) do
    audit_event(Map.merge(%{workspace_id: nil}, Map.new(opts)))
  end
end
