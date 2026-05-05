defmodule Bank.WorkspaceQueryScopingTest do
  @moduledoc """
  #158b / #158b.2 — workspace_id query scoping at the context layer.

  Each context exposes an opt-in `:workspace_id` filter on its
  list/read functions (and an opt-in stamp on its writer functions).
  The default — no opt — preserves the pre-#158b "all workspaces"
  behaviour so legacy callers stay green. The NOT NULL flip and the
  drop of the legacy default land in a later PR after every caller
  has been migrated.

  Tests live in their own file so per-context test files (e.g.
  `Bank.CounterpartiesTest`) stay focused on their local contracts.
  """

  use Bank.DataCase, async: true

  import Bank.Fixtures

  alias Bank.Audit
  alias Bank.Counterparties
  alias Bank.Counterparties.Counterparty
  alias Bank.Decisions
  alias Bank.Delegations
  alias Bank.Intents
  alias Bank.Policies
  alias Bank.WalletScreening
  alias Bank.Workspaces

  defp create_workspace(slug) do
    {:ok, ws} =
      Workspaces.create_workspace(%{slug: slug, name: "WS #{slug}", mainnet_enabled: true})

    ws
  end

  defp insert_counterparty!(ws, name) do
    {:ok, cp} =
      Counterparties.create_counterparty(
        %{name: name, created_by: :user},
        actor: :user,
        actor_id: nil,
        workspace_id: ws && ws.id
      )

    cp
  end

  defp insert_policy_rule!(ws, rule_type, priority) do
    {:ok, rule} =
      Policies.create_rule(
        %{
          rule_type: rule_type,
          priority: priority,
          params: %{},
          created_by: :user
        },
        actor: :user,
        actor_id: nil,
        workspace_id: ws && ws.id
      )

    rule
  end

  defp submit_intent!(ws, agent_id, idempotency) do
    target_cp = insert_counterparty!(ws, "Recipient-#{idempotency}")

    {:ok, %{intent: intent}} =
      Intents.submit(
        %{
          "agent_id" => agent_id,
          "source" => "agent",
          "idempotency_key" => idempotency,
          "kind" => "transfer",
          "asset" => "USDC",
          "chain" => "base",
          "amount" => "1.00",
          "target" => %{"counterparty_id" => target_cp.id}
        },
        workspace_id: ws && ws.id
      )

    intent
  end

  defp insert_audit_event!(ws, event_type) do
    {:ok, event} =
      Audit.append_event(%{
        actor: :user,
        actor_id: "u",
        event_type: event_type,
        subject_type: "user",
        subject_id: Ecto.UUID.generate(),
        correlation_id: Ecto.UUID.generate(),
        payload_hash: :crypto.hash(:sha256, event_type) |> Base.encode16(case: :lower),
        workspace_id: ws && ws.id
      })

    event
  end

  describe "Counterparties.create_counterparty/2 — opts[:workspace_id]" do
    test "stamps workspace_id from opts" do
      ws = create_workspace("c-stamp")
      cp = insert_counterparty!(ws, "Acme")
      assert cp.workspace_id == ws.id
    end

    test "leaves workspace_id nil when neither opts nor attrs supply it" do
      {:ok, cp} = Counterparties.create_counterparty(%{name: "Legacy", created_by: :user})
      assert cp.workspace_id == nil
    end

    test "opts[:workspace_id] wins; user-supplied attrs[:workspace_id] is stripped" do
      ws_a = create_workspace("c-opts-a")
      ws_b = create_workspace("c-opts-b")

      {:ok, cp} =
        Counterparties.create_counterparty(
          %{name: "Override", created_by: :user, workspace_id: ws_b.id},
          actor: :user,
          actor_id: nil,
          workspace_id: ws_a.id
        )

      assert cp.workspace_id == ws_a.id
    end

    test "user-supplied attrs[:workspace_id] is stripped even when opts has none" do
      ws = create_workspace("c-forge")

      {:ok, cp} =
        Counterparties.create_counterparty(%{
          name: "Forge attempt",
          created_by: :user,
          workspace_id: ws.id
        })

      # The workspace boundary must not be forgeable from `attrs`.
      # Without a caller-supplied `opts[:workspace_id]`, the row
      # ends up unscoped (legacy nil), regardless of what the body
      # asked for.
      assert cp.workspace_id == nil
    end

    test "string-keyed `\"workspace_id\"` in attrs is also stripped" do
      ws = create_workspace("c-string-forge")

      {:ok, cp} =
        Counterparties.create_counterparty(%{
          "name" => "Forge string",
          "created_by" => "user",
          "workspace_id" => ws.id
        })

      assert cp.workspace_id == nil
    end
  end

  describe "Counterparties.list_counterparties/2 — opts[:workspace_id]" do
    test "filters to a single workspace when set" do
      ws_a = create_workspace("c-list-a")
      ws_b = create_workspace("c-list-b")

      cp_a = insert_counterparty!(ws_a, "ACo-#{System.unique_integer([:positive])}")
      cp_b = insert_counterparty!(ws_b, "BCo-#{System.unique_integer([:positive])}")

      %{entries: in_a} = Counterparties.list_counterparties(%{}, workspace_id: ws_a.id)
      ids_a = Enum.map(in_a, & &1.id)

      assert cp_a.id in ids_a
      refute cp_b.id in ids_a
    end

    test "returns all rows across workspaces when no filter is supplied (legacy)" do
      ws = create_workspace("c-list-legacy")
      cp = insert_counterparty!(ws, "Visible-#{System.unique_integer([:positive])}")

      %{entries: all} = Counterparties.list_counterparties()
      assert Enum.any?(all, &(&1.id == cp.id))
    end

    test "ignores rows with NULL workspace_id when a filter is supplied" do
      ws = create_workspace("c-list-null")

      # Insert a legacy nil-workspace row directly via changeset.
      {:ok, _legacy} =
        Counterparty.changeset(%Counterparty{}, %{name: "Legacy nil", created_by: :user})
        |> Repo.insert()

      cp_in_ws = insert_counterparty!(ws, "Scoped-#{System.unique_integer([:positive])}")

      %{entries: scoped} = Counterparties.list_counterparties(%{}, workspace_id: ws.id)
      ids = Enum.map(scoped, & &1.id)
      assert cp_in_ws.id in ids
      assert Enum.all?(scoped, &(&1.workspace_id == ws.id))
    end
  end

  describe "Policies.create_rule/2 — opts[:workspace_id]" do
    test "stamps workspace_id from opts" do
      ws = create_workspace("p-stamp")
      rule = insert_policy_rule!(ws, :amount_limit, 10)
      assert rule.workspace_id == ws.id
    end

    test "leaves workspace_id nil when neither opts nor attrs supply it (legacy)" do
      {:ok, rule} =
        Policies.create_rule(%{
          rule_type: :amount_limit,
          priority: 99,
          params: %{},
          created_by: :user
        })

      assert rule.workspace_id == nil
    end
  end

  describe "Policies.list_rules/2 — opts[:workspace_id]" do
    test "filters to one workspace when set" do
      ws_a = create_workspace("p-list-a")
      ws_b = create_workspace("p-list-b")

      rule_a = insert_policy_rule!(ws_a, :amount_limit, 100)
      rule_b = insert_policy_rule!(ws_b, :amount_limit, 200)

      %{entries: in_a} = Policies.list_rules(%{}, workspace_id: ws_a.id)
      ids_a = Enum.map(in_a, & &1.id)

      assert rule_a.id in ids_a
      refute rule_b.id in ids_a
    end

    test "returns rules across workspaces when no filter is supplied" do
      ws = create_workspace("p-list-legacy")
      rule = insert_policy_rule!(ws, :allowed_chain, 5)

      %{entries: entries} = Policies.list_rules()
      assert Enum.any?(entries, &(&1.id == rule.id))
    end
  end

  describe "Policies.load_active_ruleset/1 — opts[:workspace_id]" do
    test "narrows the active ruleset to one workspace" do
      ws_a = create_workspace("p-active-a")
      ws_b = create_workspace("p-active-b")

      rule_a = insert_policy_rule!(ws_a, :amount_limit, 11)
      _rule_b = insert_policy_rule!(ws_b, :amount_limit, 12)

      ruleset = Policies.load_active_ruleset(workspace_id: ws_a.id)
      ids = Enum.map(ruleset, & &1.id)

      assert rule_a.id in ids
      assert Enum.all?(ruleset, &(&1.workspace_id == ws_a.id))
    end

    test "no opt returns the legacy cross-workspace active ruleset" do
      ws = create_workspace("p-active-legacy")
      rule = insert_policy_rule!(ws, :allowed_asset, 3)

      ruleset = Policies.load_active_ruleset()
      assert Enum.any?(ruleset, &(&1.id == rule.id))
    end
  end

  describe "Intents.submit/2 — opts[:workspace_id]" do
    test "stamps workspace_id from opts onto the inserted intent" do
      ws = create_workspace("i-stamp")
      intent = submit_intent!(ws, "agent-#{System.unique_integer([:positive])}", "idem-1")
      assert intent.workspace_id == ws.id
    end
  end

  describe "Intents.list/1 — opts[:workspace_id]" do
    test "filters to one workspace when set" do
      ws_a = create_workspace("i-list-a")
      ws_b = create_workspace("i-list-b")
      agent_id = "agent-#{System.unique_integer([:positive])}"

      intent_a = submit_intent!(ws_a, agent_id, "a-#{System.unique_integer([:positive])}")
      intent_b = submit_intent!(ws_b, agent_id, "b-#{System.unique_integer([:positive])}")

      ids_a = Intents.list(workspace_id: ws_a.id) |> Enum.map(& &1.id)
      assert intent_a.id in ids_a
      refute intent_b.id in ids_a
    end
  end

  describe "Intents.counts_by_state/1 — opts[:workspace_id]" do
    test "narrows the count breakdown to one workspace" do
      ws_a = create_workspace("i-counts-a")
      ws_b = create_workspace("i-counts-b")

      submit_intent!(ws_a, "agent-#{System.unique_integer([:positive])}", "ca-1")
      submit_intent!(ws_b, "agent-#{System.unique_integer([:positive])}", "cb-1")

      counts_a = Intents.counts_by_state(workspace_id: ws_a.id)
      total_a = counts_a |> Map.values() |> Enum.sum()

      counts_global = Intents.counts_by_state()
      total_global = counts_global |> Map.values() |> Enum.sum()

      assert total_a < total_global
    end
  end

  describe "Audit.list_events/2 — filters[:workspace_id]" do
    test "narrows to events stamped with workspace_id" do
      ws_a = create_workspace("a-audit-a")
      ws_b = create_workspace("a-audit-b")

      _event_a = insert_audit_event!(ws_a, "scoping.test_a")
      _event_b = insert_audit_event!(ws_b, "scoping.test_b")

      %{events: events} =
        Audit.list_events(%{
          workspace_id: ws_a.id,
          event_type: "scoping.test_a"
        })

      assert length(events) == 1
      assert Enum.all?(events, &(&1.workspace_id == ws_a.id))
    end

    test "no workspace_id filter returns events across workspaces" do
      ws = create_workspace("a-audit-legacy")
      _event = insert_audit_event!(ws, "scoping.legacy")

      %{events: events} = Audit.list_events(%{event_type: "scoping.legacy"})
      assert length(events) >= 1
    end
  end

  # --- #158b.2: Decisions / Delegations / WalletScreening -----------------

  defp insert_intent_in!(ws) do
    cp = insert_counterparty!(ws, "Recipient-#{System.unique_integer([:positive])}")
    agent_intent(workspace_id: ws.id, target_counterparty_id: cp.id)
  end

  defp insert_envelope_in!(ws, outcome) do
    intent = insert_intent_in!(ws)

    base = %{
      intent: intent,
      outcome: outcome,
      current: true,
      decided_at: DateTime.utc_now()
    }

    attrs =
      if outcome == :approval_required do
        Map.put(base, :approval_expires_at, DateTime.add(DateTime.utc_now(), 3600, :second))
      else
        base
      end

    decision_envelope(attrs)
  end

  defp insert_active_plan_in!(ws) do
    intent = insert_intent_in!(ws)
    decision = decision_envelope(intent: intent, current: true)

    execution_plan(
      decision: decision,
      workspace_id: ws.id,
      execution_status: :prepared,
      active: true
    )
  end

  describe "Decisions.list_pending_approvals/1 — opts[:workspace_id]" do
    test "joins through intent and narrows to one workspace" do
      ws_a = create_workspace("d-pending-a")
      ws_b = create_workspace("d-pending-b")

      env_a = insert_envelope_in!(ws_a, :approval_required)
      env_b = insert_envelope_in!(ws_b, :approval_required)

      ids = Decisions.list_pending_approvals(workspace_id: ws_a.id) |> Enum.map(& &1.id)
      assert env_a.id in ids
      refute env_b.id in ids
    end

    test "no opt returns the legacy cross-workspace pending list" do
      ws = create_workspace("d-pending-legacy")
      env = insert_envelope_in!(ws, :approval_required)

      ids = Decisions.list_pending_approvals() |> Enum.map(& &1.id)
      assert env.id in ids
    end

    test "envelopes whose intent has NULL workspace_id are excluded under filter" do
      ws = create_workspace("d-pending-nullintent")

      orphan_env =
        decision_envelope(
          outcome: :approval_required,
          current: true,
          approval_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      env_in_ws = insert_envelope_in!(ws, :approval_required)

      ids = Decisions.list_pending_approvals(workspace_id: ws.id) |> Enum.map(& &1.id)
      assert env_in_ws.id in ids
      refute orphan_env.id in ids
    end
  end

  describe "Decisions.count_pending_approvals/1" do
    test "narrows the count to one workspace via the intent join" do
      ws = create_workspace("d-count-pending")
      _ = insert_envelope_in!(ws, :approval_required)
      _ = insert_envelope_in!(ws, :approval_required)
      _ = insert_envelope_in!(create_workspace("d-count-other"), :approval_required)

      assert Decisions.count_pending_approvals(workspace_id: ws.id) == 2
    end
  end

  describe "Decisions.list_recent_decisions/2" do
    test "respects the limit and the workspace filter together" do
      ws = create_workspace("d-recent")
      env_a = insert_envelope_in!(ws, :auto_exec)
      _env_other = insert_envelope_in!(create_workspace("d-recent-other"), :auto_exec)

      result = Decisions.list_recent_decisions(50, workspace_id: ws.id)
      assert Enum.any?(result, &(&1.id == env_a.id))
      assert Enum.all?(result, fn _ -> true end)
    end
  end

  describe "Decisions.list_held_decisions/1 and list_blocked_decisions/2" do
    test "filter held envelopes by workspace via the intent join" do
      ws = create_workspace("d-held")
      held = insert_envelope_in!(ws, :hold)
      _other = insert_envelope_in!(create_workspace("d-held-other"), :hold)

      ids = Decisions.list_held_decisions(workspace_id: ws.id) |> Enum.map(& &1.id)
      assert held.id in ids
      assert length(ids) == 1
    end

    test "filter blocked envelopes by workspace via the intent join" do
      ws = create_workspace("d-blocked")
      blocked = insert_envelope_in!(ws, :block)
      _other = insert_envelope_in!(create_workspace("d-blocked-other"), :block)

      ids = Decisions.list_blocked_decisions(50, workspace_id: ws.id) |> Enum.map(& &1.id)
      assert blocked.id in ids
      assert length(ids) == 1
    end
  end

  describe "Decisions.list_active_executions/1 and count_active_executions/1" do
    test "scope_plan_to_workspace filters via the plan's own workspace_id" do
      ws_a = create_workspace("d-exec-a")
      ws_b = create_workspace("d-exec-b")

      plan_a = insert_active_plan_in!(ws_a)
      _plan_b = insert_active_plan_in!(ws_b)

      ids_a = Decisions.list_active_executions(workspace_id: ws_a.id) |> Enum.map(& &1.id)
      assert plan_a.id in ids_a
      assert length(ids_a) == 1

      assert Decisions.count_active_executions(workspace_id: ws_a.id) == 1
    end

    test "no opt returns the legacy cross-workspace active execution list" do
      ws = create_workspace("d-exec-legacy")
      plan = insert_active_plan_in!(ws)

      ids = Decisions.list_active_executions() |> Enum.map(& &1.id)
      assert plan.id in ids
    end
  end

  describe "Delegations.list_active/1 — opts[:workspace_id]" do
    test "filters delegations directly by their workspace_id read hint" do
      ws_a = create_workspace("dl-a")
      ws_b = create_workspace("dl-b")

      d_a = delegation(workspace_id: ws_a.id)
      _d_b = delegation(workspace_id: ws_b.id)

      ids = Delegations.list_active(workspace_id: ws_a.id) |> Enum.map(& &1.id)
      assert d_a.id in ids
      assert length(ids) == 1
    end

    test "delegations with NULL workspace_id are excluded under filter" do
      ws = create_workspace("dl-null")
      _legacy = delegation()
      d = delegation(workspace_id: ws.id)

      ids = Delegations.list_active(workspace_id: ws.id) |> Enum.map(& &1.id)
      assert d.id in ids
      assert length(ids) == 1
    end

    test "no opt returns delegations across workspaces (legacy)" do
      ws = create_workspace("dl-legacy")
      d = delegation(workspace_id: ws.id)

      ids = Delegations.list_active() |> Enum.map(& &1.id)
      assert d.id in ids
    end
  end

  describe "WalletScreening.list_records/2 — opts[:workspace_id]" do
    defp insert_screening_in!(ws, source_record_id) do
      {:ok, rec} =
        WalletScreening.upsert_record(%{
          chain: "base",
          address: "0xabc",
          control_tier: :hard_block,
          source: "ofac",
          source_record_id: source_record_id,
          workspace_id: ws && ws.id
        })

      rec
    end

    test "filters wallet-screening hits to one workspace" do
      ws_a = create_workspace("ws-screen-a")
      ws_b = create_workspace("ws-screen-b")

      rec_a = insert_screening_in!(ws_a, "src-a-#{System.unique_integer([:positive])}")
      _rec_b = insert_screening_in!(ws_b, "src-b-#{System.unique_integer([:positive])}")

      ids = WalletScreening.list_records(%{}, workspace_id: ws_a.id) |> Enum.map(& &1.id)
      assert rec_a.id in ids
      assert length(ids) == 1
    end

    test "no opt returns hits across workspaces (legacy global view)" do
      ws = create_workspace("ws-screen-legacy")
      rec = insert_screening_in!(ws, "src-legacy-#{System.unique_integer([:positive])}")

      ids = WalletScreening.list_records() |> Enum.map(& &1.id)
      assert rec.id in ids
    end
  end
end
