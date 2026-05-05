defmodule Bank.CrossAccountIsolationTest do
  @moduledoc """
  Cross-workspace isolation regression suite for issue #187 (last
  issue in epic #167 — multi-account routing).

  ## Scope

  v0.1 reality is workspace-scoped, single-active-delegation per
  smart account. The richer multi-account model is deferred to
  #183-#186. This suite is the audit pin that catches a regression
  the future multi-account refactor would introduce if any of the
  workspace-scoped surfaces accidentally leaked across workspaces.

  ## What this suite proves

  Each describe block targets one of the five workspace-scoped
  surfaces (intents, decision envelopes, execution plans,
  delegations, audit events) plus two defense-in-depth pins:

    * **Intents** — `Bank.Intents.list/1` and
      `Bank.Intents.get_in_workspace/2` refuse cross-workspace
      reads.
    * **Decisions** — every list helper that joins through the
      intent (`list_recent_decisions/2`, `list_pending_approvals/1`,
      `list_held_decisions/1`, `list_blocked_decisions/2`) honors
      `:workspace_id`.
    * **Execution plans** — `Bank.Decisions.list_active_executions/1`
      and `count_active_executions/1` honor the plan's own
      `workspace_id` read hint.
    * **Delegations** — `Bank.Delegations.list_active/1` honors the
      delegation's `workspace_id` read hint.
    * **Audit events** — `Bank.Audit.list_events/2` honors the
      `:workspace_id` filter.
    * **Cross-workspace dispatch refusal** — a plan in workspace A
      whose `smart_account_id` does not match any executable
      delegation (because the only executable delegation is in
      workspace B with a different SA id) must NOT dispatch. The
      worker matches by `smart_account_id`, and the partial unique
      index on `delegations` makes cross-workspace SA reuse
      structurally impossible — but if a future bug allowed it,
      this test pins the dispatch-side defense.
    * **Single-active-delegation pin** — `Bank.Delegations.grant/3`
      refuses to create a parallel non-terminal row for the same
      `smart_account_id` regardless of workspace. Once the prior
      row reaches a terminal state (`:revoked` or `:expired`), a
      fresh grant succeeds.

  Mirrors the cross-workspace test pattern set by
  `Bank.MainnetGateTest` — workspace fixture helpers, no auth
  surface, no chain HTTP.
  """

  use Bank.DataCase, async: false

  import Bank.Fixtures

  alias Bank.Audit
  alias Bank.Decisions
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Delegations
  alias Bank.Delegations.Delegation
  alias Bank.Intents
  alias Bank.Repo
  alias Bank.Runtime.Workers.RunExecution
  alias Bank.Security.PauseState
  alias Bank.Workspaces

  # Reset the global PauseState before each test so a leaked pause
  # from a prior test file (e.g. `:global` pause set in a security
  # / control-LiveView / swap-dispatch-safety test that finished
  # without explicit cleanup) cannot turn the dispatch-refusal
  # assertions in this file into a `:runtime_paused` flake.
  setup do
    PauseState.reset()
    :ok
  end

  defp workspace(slug_prefix) do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Workspaces.create_workspace(%{
        slug: "#{slug_prefix}-#{suffix}",
        name: "Workspace #{slug_prefix} #{suffix}",
        mainnet_enabled: true
      })

    ws
  end

  defp counterparty_in!(%Bank.Workspaces.Workspace{} = ws, name) do
    counterparty(workspace_id: ws.id, name: "#{name}-#{System.unique_integer([:positive])}")
  end

  defp submit_intent!(%Bank.Workspaces.Workspace{} = ws) do
    suffix = System.unique_integer([:positive])
    cp = counterparty_in!(ws, "recipient")

    {:ok, %{intent: intent}} =
      Intents.submit(
        %{
          "agent_id" => "agent-#{suffix}",
          "source" => "agent",
          "idempotency_key" => "iso-#{suffix}",
          "kind" => "transfer",
          "asset" => "USDC",
          "chain" => "base",
          "amount" => "1.00",
          "target" => %{"counterparty_id" => cp.id}
        },
        workspace_id: ws.id
      )

    intent
  end

  defp insert_pending_envelope!(%Bank.Workspaces.Workspace{} = ws) do
    intent = agent_intent(workspace_id: ws.id)

    decision_envelope(
      intent: intent,
      outcome: :approval_required,
      current: true,
      approval_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    )
  end

  defp insert_recent_envelope!(%Bank.Workspaces.Workspace{} = ws, outcome) do
    intent = agent_intent(workspace_id: ws.id)
    decision_envelope(intent: intent, outcome: outcome, current: true)
  end

  defp insert_active_plan!(%Bank.Workspaces.Workspace{} = ws) do
    intent = agent_intent(workspace_id: ws.id)
    decision = decision_envelope(intent: intent, current: true)

    execution_plan(
      decision: decision,
      workspace_id: ws.id,
      execution_status: :prepared,
      active: true
    )
  end

  describe "intents are workspace-scoped" do
    test "Intents.list/1 with :workspace_id excludes another workspace's rows" do
      ws_a = workspace("intents-a")
      ws_b = workspace("intents-b")

      intent_a = submit_intent!(ws_a)
      intent_b = submit_intent!(ws_b)

      ids_a = Intents.list(workspace_id: ws_a.id) |> Enum.map(& &1.id)

      assert intent_a.id in ids_a
      refute intent_b.id in ids_a, "workspace A leaked intent #{intent_b.id} from workspace B"
    end

    test "Intents.get_in_workspace/2 returns nil for an intent that belongs to another workspace" do
      ws_a = workspace("intents-get-a")
      ws_b = workspace("intents-get-b")

      intent_b = submit_intent!(ws_b)

      assert nil == Intents.get_in_workspace(intent_b.id, ws_a.id),
             "workspace A could read intent #{intent_b.id} from workspace B"

      # Sanity: the intent IS visible from its own workspace.
      assert %_{id: intent_b_id} = Intents.get_in_workspace(intent_b.id, ws_b.id)
      assert intent_b_id == intent_b.id
    end

    test "Intents.counts_by_state/1 narrows to the requested workspace" do
      ws_a = workspace("intents-counts-a")
      ws_b = workspace("intents-counts-b")

      submit_intent!(ws_a)
      submit_intent!(ws_b)
      submit_intent!(ws_b)

      counts_a = Intents.counts_by_state(workspace_id: ws_a.id)
      counts_b = Intents.counts_by_state(workspace_id: ws_b.id)

      total_a = counts_a |> Map.values() |> Enum.sum()
      total_b = counts_b |> Map.values() |> Enum.sum()

      assert total_a == 1
      assert total_b == 2
    end
  end

  describe "decision envelopes are workspace-scoped" do
    test "list_pending_approvals/1 excludes another workspace's pending envelopes" do
      ws_a = workspace("dec-pending-a")
      ws_b = workspace("dec-pending-b")

      env_a = insert_pending_envelope!(ws_a)
      env_b = insert_pending_envelope!(ws_b)

      ids_a = Decisions.list_pending_approvals(workspace_id: ws_a.id) |> Enum.map(& &1.id)

      assert env_a.id in ids_a
      refute env_b.id in ids_a, "workspace A leaked pending envelope from workspace B"
    end

    test "list_recent_decisions/2 excludes another workspace's recent envelopes" do
      ws_a = workspace("dec-recent-a")
      ws_b = workspace("dec-recent-b")

      env_a = insert_recent_envelope!(ws_a, :auto_exec)
      env_b = insert_recent_envelope!(ws_b, :auto_exec)

      ids_a = Decisions.list_recent_decisions(50, workspace_id: ws_a.id) |> Enum.map(& &1.id)

      assert env_a.id in ids_a
      refute env_b.id in ids_a, "workspace A leaked recent envelope from workspace B"
    end

    test "list_held_decisions/1 excludes another workspace's held envelopes" do
      ws_a = workspace("dec-held-a")
      ws_b = workspace("dec-held-b")

      env_a = insert_recent_envelope!(ws_a, :hold)
      env_b = insert_recent_envelope!(ws_b, :hold)

      ids_a = Decisions.list_held_decisions(workspace_id: ws_a.id) |> Enum.map(& &1.id)

      assert env_a.id in ids_a
      refute env_b.id in ids_a, "workspace A leaked held envelope from workspace B"
    end

    test "list_blocked_decisions/2 excludes another workspace's blocked envelopes" do
      ws_a = workspace("dec-blocked-a")
      ws_b = workspace("dec-blocked-b")

      env_a = insert_recent_envelope!(ws_a, :block)
      env_b = insert_recent_envelope!(ws_b, :block)

      ids_a = Decisions.list_blocked_decisions(50, workspace_id: ws_a.id) |> Enum.map(& &1.id)

      assert env_a.id in ids_a
      refute env_b.id in ids_a, "workspace A leaked blocked envelope from workspace B"
    end

    test "count_pending_approvals/1 narrows the count via the intent join" do
      ws_a = workspace("dec-count-a")
      ws_b = workspace("dec-count-b")

      _ = insert_pending_envelope!(ws_a)
      _ = insert_pending_envelope!(ws_a)
      _ = insert_pending_envelope!(ws_b)

      assert Decisions.count_pending_approvals(workspace_id: ws_a.id) == 2
      assert Decisions.count_pending_approvals(workspace_id: ws_b.id) == 1
    end
  end

  describe "execution plans are workspace-scoped" do
    test "list_active_executions/1 excludes another workspace's active plans" do
      ws_a = workspace("plan-a")
      ws_b = workspace("plan-b")

      plan_a = insert_active_plan!(ws_a)
      plan_b = insert_active_plan!(ws_b)

      ids_a = Decisions.list_active_executions(workspace_id: ws_a.id) |> Enum.map(& &1.id)

      assert plan_a.id in ids_a
      refute plan_b.id in ids_a, "workspace A leaked execution plan from workspace B"
    end

    test "count_active_executions/1 narrows the count" do
      ws_a = workspace("plan-count-a")
      ws_b = workspace("plan-count-b")

      _ = insert_active_plan!(ws_a)
      _ = insert_active_plan!(ws_a)
      _ = insert_active_plan!(ws_b)

      assert Decisions.count_active_executions(workspace_id: ws_a.id) == 2
      assert Decisions.count_active_executions(workspace_id: ws_b.id) == 1
    end
  end

  describe "delegations are workspace-scoped" do
    test "Delegations.list_active/1 excludes another workspace's delegations" do
      ws_a = workspace("del-list-a")
      ws_b = workspace("del-list-b")

      d_a = delegation(workspace_id: ws_a.id)
      d_b = delegation(workspace_id: ws_b.id)

      ids_a = Delegations.list_active(workspace_id: ws_a.id) |> Enum.map(& &1.id)

      assert d_a.id in ids_a
      refute d_b.id in ids_a, "workspace A leaked delegation from workspace B"
    end
  end

  describe "audit events are workspace-scoped" do
    test "Audit.list_events/2 with :workspace_id filter excludes another workspace's events" do
      ws_a = workspace("audit-a")
      ws_b = workspace("audit-b")

      event_a =
        audit_event(
          workspace_id: ws_a.id,
          event_type: "isolation.cross.a.#{System.unique_integer([:positive])}"
        )

      event_b =
        audit_event(
          workspace_id: ws_b.id,
          event_type: "isolation.cross.b.#{System.unique_integer([:positive])}"
        )

      %{events: events_a} = Audit.list_events(%{workspace_id: ws_a.id})
      ids_a = Enum.map(events_a, & &1.id)

      assert event_a.id in ids_a
      refute event_b.id in ids_a, "workspace A leaked audit event from workspace B"

      # Every returned event must belong to workspace A.
      assert Enum.all?(events_a, &(&1.workspace_id == ws_a.id)),
             "workspace A audit slice contained foreign rows"
    end

    test "Audit.list_events/2 with :workspace_id filter excludes legacy workspace_id IS NULL rows" do
      ws = workspace("audit-null-exclusion")

      legacy_event =
        audit_event(
          workspace_id: nil,
          event_type: "isolation.legacy.#{System.unique_integer([:positive])}"
        )

      scoped_event =
        audit_event(
          workspace_id: ws.id,
          event_type: "isolation.scoped.#{System.unique_integer([:positive])}"
        )

      %{events: events} = Audit.list_events(%{workspace_id: ws.id})
      ids = Enum.map(events, & &1.id)

      assert scoped_event.id in ids

      refute legacy_event.id in ids,
             "workspace filter pulled in a legacy workspace_id IS NULL row"
    end
  end

  describe "cross-workspace dispatch refusal" do
    # Synchronous-gate variant. `Decisions.request_manual_execution/3`
    # validates the delegation exists + is active BEFORE writing any
    # plan row. So a workspace-A operator who tries to dispatch
    # through `sa_a` (no delegation) while only workspace B has a
    # live delegation for `sa_b` cannot even create the plan: the
    # call returns `{:error, :delegation_not_active}` and no
    # ExecutionPlan row is written.
    test "request_manual_execution refuses to create a plan when the SA has no executable delegation" do
      ws_a = workspace("dispatch-sync-a")
      ws_b = workspace("dispatch-sync-b")

      sa_a = "sa-disp-sync-a-#{System.unique_integer([:positive])}"
      sa_b = "sa-disp-sync-b-#{System.unique_integer([:positive])}"

      intent = agent_intent(workspace_id: ws_a.id, state: :decided)
      envelope = decision_envelope(intent: intent, current: true, outcome: :auto_exec)

      # Only workspace B has a live delegation, and it's for a
      # different SA. Workspace A's attempt to dispatch through
      # `sa_a` finds no executable delegation.
      {:ok, _} = Delegations.grant(sa_b, "del-disp-sync-b", %{workspace_id: ws_b.id})
      assert Delegations.executable?(sa_b)
      refute Delegations.executable?(sa_a)

      assert {:error, :delegation_not_active} =
               Decisions.request_manual_execution(envelope.id, sa_a)

      # Critically: no plan row was written for this decision.
      query = from p in ExecutionPlan, where: p.decision_id == ^envelope.id
      assert Repo.aggregate(query, :count) == 0
    end

    test "RunExecution refuses to dispatch a plan whose delegation row was revoked mid-flight" do
      # Revoke-mid-flight is the canonical "the operator pulled the
      # rug between plan creation and dispatch" case. It is not
      # cross-workspace per se, but the runbook's failure-modes
      # table calls it out, and the dispatch worker's behaviour is
      # the same defense-in-depth that protects against
      # cross-workspace leaks: match by smart_account_id, fail
      # closed if the delegation is non-active.
      ws = workspace("revoke-mid-flight")
      sa = "sa-revoke-mid-#{System.unique_integer([:positive])}"

      intent = agent_intent(workspace_id: ws.id, state: :decided)
      envelope = decision_envelope(intent: intent, current: true, outcome: :auto_exec)

      {:ok, _} =
        Delegations.grant(sa, "del-revoke-mid-#{System.unique_integer([:positive])}", %{
          workspace_id: ws.id
        })

      {:ok, plan} = Decisions.request_manual_execution(envelope.id, sa)

      # Race: operator (or adapter callback) flips the delegation
      # to :revoking before the worker runs.
      {:ok, _} = Delegations.record_revoke_requested(sa)
      refute Delegations.executable?(sa)

      parent = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        send(parent, :adapter_was_called)
        Req.Test.json(conn, %{accepted: true})
      end)

      assert {:cancel, :delegation_not_active} =
               RunExecution.perform(%Oban.Job{args: %{"decision_id" => envelope.id}})

      refute_receive :adapter_was_called, 50

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :aborted
      assert reloaded.final_reason == "delegation_not_active"
    end
  end

  describe "single-active-delegation pin (v0.1)" do
    # The v0.1 reality: the partial unique index
    # `delegations_smart_account_active_idx` on `delegations` keeps
    # at most one non-terminal row per `smart_account_id`,
    # regardless of `workspace_id`. A second `grant/3` for the same
    # SA while a non-terminal row exists fails closed; a fresh
    # grant succeeds only after the prior row reaches a terminal
    # state.
    #
    # This pins the v0.1 single-active reality so a future
    # multi-account refactor that lifted the unique constraint to
    # include workspace_id would fail this test first.
    test "a second grant for the same SA while a non-terminal one exists is refused" do
      ws_a = workspace("single-active-a")
      ws_b = workspace("single-active-b")
      sa = "sa-single-#{System.unique_integer([:positive])}"

      {:ok, first} = Delegations.grant(sa, "del-1", %{workspace_id: ws_a.id})
      assert first.workspace_id == ws_a.id
      assert first.state == :active

      assert {:error, :already_exists} =
               Delegations.grant(sa, "del-2", %{workspace_id: ws_a.id}),
             "v0.1 should refuse a parallel grant in the same workspace"

      # Same SA, different workspace — also refused. The unique
      # index is on `smart_account_id` alone, not
      # (workspace_id, smart_account_id).
      assert {:error, :already_exists} =
               Delegations.grant(sa, "del-3", %{workspace_id: ws_b.id}),
             "v0.1 should refuse a parallel grant from a different workspace"

      # Exactly one non-terminal row exists for this SA across the
      # whole table.
      query =
        from d in Delegation,
          where:
            d.smart_account_id == ^sa and
              d.state in [:pending, :active, :revoking, :revoke_failed]

      assert Repo.aggregate(query, :count) == 1,
             "more than one non-terminal delegation for the same SA"
    end

    test "a fresh grant for the same SA succeeds only after the prior row reaches a terminal state" do
      ws = workspace("single-active-revoke")
      sa = "sa-single-revoke-#{System.unique_integer([:positive])}"

      {:ok, _first} = Delegations.grant(sa, "del-init", %{workspace_id: ws.id})

      # Walk the prior row to a terminal state so a fresh grant is
      # allowed: :active -> :revoking -> :revoked.
      {:ok, _} = Delegations.record_revoke_requested(sa)
      {:ok, %Delegation{state: :revoked}} = Delegations.record_revoked(sa)

      # Now a fresh grant succeeds — and lands as a NEW row, not a
      # mutation of the prior one.
      assert {:ok, %Delegation{state: :active} = fresh} =
               Delegations.grant(sa, "del-fresh", %{workspace_id: ws.id})

      # The terminal predecessor is still in the table; the fresh
      # row is a new id.
      total =
        Repo.aggregate(
          from(d in Delegation, where: d.smart_account_id == ^sa),
          :count
        )

      assert total == 2

      assert fresh.workspace_id == ws.id
    end
  end
end
