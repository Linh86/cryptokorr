defmodule Bank.DecisionsTest do
  @moduledoc """
  Context-level tests for `Bank.Decisions` — approval state machine
  and manual execution gates.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Ecto.Query

  import Bank.Fixtures

  alias Bank.Decisions
  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Delegations
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.Workers.RunExecution
  alias Bank.Security
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  describe "get_envelope/1" do
    test "returns envelope by id" do
      envelope = decision_envelope()

      assert {:ok, found} = Decisions.get_envelope(envelope.id)
      assert found.id == envelope.id
    end

    test "returns :not_found for missing id" do
      assert {:error, :not_found} = Decisions.get_envelope(Ecto.UUID.generate())
    end
  end

  describe "get_envelope_with_plans/1" do
    test "preloads execution plans" do
      envelope = decision_envelope()
      plan = execution_plan(decision: envelope)

      assert {:ok, found} = Decisions.get_envelope_with_plans(envelope.id)
      assert length(found.execution_plans) == 1
      assert hd(found.execution_plans).id == plan.id
    end
  end

  describe "active_plan_for/1" do
    test "returns active plan" do
      envelope = decision_envelope()
      plan = execution_plan(decision: envelope, active: true)

      assert Decisions.active_plan_for(envelope.id).id == plan.id
    end

    test "returns nil when no active plan" do
      envelope = decision_envelope()
      _plan = execution_plan(decision: envelope, active: false)

      assert is_nil(Decisions.active_plan_for(envelope.id))
    end

    test "returns nil when no plans exist" do
      envelope = decision_envelope()
      assert is_nil(Decisions.active_plan_for(envelope.id))
    end
  end

  describe "approve/2" do
    setup do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          state: :pending_decision,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      %{intent: intent, envelope: envelope}
    end

    test "happy path: writes auto_exec successor; held when no executable account", %{
      intent: intent,
      envelope: envelope
    } do
      # No delegation -> dispatch held with :no_executable_account.
      assert {:ok, successor, {:held, :no_executable_account}} =
               Decisions.approve(envelope.id, actor_id: "op-test")

      assert successor.outcome == :auto_exec
      assert successor.state == :decided
      assert successor.supersedes_id == envelope.id
      assert successor.current == true

      # Prior envelope is no longer current.
      reloaded_prior = Repo.get!(DecisionEnvelope, envelope.id)
      refute reloaded_prior.current

      # Intent points at the successor and is :decided.
      reloaded_intent = Repo.get!(AgentIntent, intent.id)
      assert reloaded_intent.current_decision_id == successor.id
      assert reloaded_intent.state == :decided

      # Held: no execution plan, no RunExecution enqueued.
      assert is_nil(Decisions.active_plan_for(successor.id))
      refute_enqueued(worker: RunExecution)
    end

    test "with one executable delegation: dispatches, creates plan, and enqueues RunExecution",
         %{envelope: envelope} do
      {:ok, _del} = Delegations.grant("sa_approval_dispatch", "del_approval_dispatch")

      assert {:ok, successor, {:dispatched, plan}} =
               Decisions.approve(envelope.id, actor_id: "op-dispatch")

      assert successor.outcome == :auto_exec
      assert plan.decision_id == successor.id
      assert plan.smart_account_id == "sa_approval_dispatch"
      assert plan.execution_status == :prepared
      assert plan.active

      assert_enqueued(
        worker: RunExecution,
        queue: :executions_run,
        args: %{"decision_id" => successor.id}
      )
    end

    test "while runtime paused: records the approval but holds dispatch with :runtime_paused",
         %{envelope: envelope} do
      {:ok, _del} = Delegations.grant("sa_paused_approval", "del_paused_approval")
      {:ok, :paused} = Security.pause(:global)

      assert {:ok, successor, {:held, :runtime_paused}} =
               Decisions.approve(envelope.id, actor_id: "op-pause")

      assert successor.outcome == :auto_exec
      assert successor.state == :decided
      assert successor.current == true

      refute_enqueued(worker: RunExecution)
      assert is_nil(Decisions.active_plan_for(successor.id))
    end

    test "ambiguous delegations -> held with :ambiguous_executable_account",
         %{envelope: envelope} do
      {:ok, _del1} = Delegations.grant("sa_amb_a", "del_amb_a")
      {:ok, _del2} = Delegations.grant("sa_amb_b", "del_amb_b")

      assert {:ok, _successor, {:held, :ambiguous_executable_account}} =
               Decisions.approve(envelope.id, actor_id: "op-amb")

      refute_enqueued(worker: RunExecution)
    end

    test "explicit :smart_account_id opt overrides the resolver",
         %{envelope: envelope} do
      {:ok, _del1} = Delegations.grant("sa_amb_c", "del_amb_c")
      {:ok, _del2} = Delegations.grant("sa_amb_d", "del_amb_d")
      {:ok, _del3} = Delegations.grant("sa_explicit_app", "del_explicit_app")

      assert {:ok, _successor, {:dispatched, plan}} =
               Decisions.approve(envelope.id,
                 actor_id: "op-explicit",
                 smart_account_id: "sa_explicit_app"
               )

      assert plan.smart_account_id == "sa_explicit_app"
    end

    test "rejects already-superseded envelope (double-approve)", %{envelope: envelope} do
      {:ok, _, _} = Decisions.approve(envelope.id, actor_id: "op-1")

      assert {:error, :already_superseded} =
               Decisions.approve(envelope.id, actor_id: "op-2")
    end

    test "rejects when outcome is not approval_required" do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      assert {:error, {:wrong_outcome, :auto_exec}} =
               Decisions.approve(envelope.id, actor_id: "op")
    end

    test "approved+held envelope is still executable via request_manual_execution", %{
      envelope: envelope
    } do
      # Held path leaves the successor in :auto_exec / :decided so the
      # operator can resolve the gate (e.g. grant a delegation) and
      # dispatch manually.
      {:ok, successor, {:held, :no_executable_account}} =
        Decisions.approve(envelope.id, actor_id: "op-test")

      {:ok, _del} = Delegations.grant("sa_handoff", "del_handoff")

      assert {:ok, plan} =
               Decisions.request_manual_execution(successor.id, "sa_handoff",
                 reason: "post_approval"
               )

      assert plan.decision_id == successor.id
      assert plan.execution_status == :prepared
      assert plan.active == true

      assert_enqueued(
        worker: RunExecution,
        queue: :executions_run,
        args: %{"decision_id" => successor.id}
      )
    end
  end

  describe "reject/2" do
    test "while runtime paused: rejection still records and blocks intent" do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          state: :pending_decision,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, :paused} = Security.pause(:global)

      assert {:ok, successor, :no_dispatch} =
               Decisions.reject(envelope.id, actor_id: "op-rej")

      assert successor.outcome == :block

      reloaded_intent = Repo.get!(AgentIntent, intent.id)
      assert reloaded_intent.state == :blocked

      # Reject never enqueues, paused or not.
      refute_enqueued(worker: RunExecution)
    end
  end

  describe "request_manual_execution/3" do
    test "happy path: creates plan and enqueues execution" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      {:ok, _del} = Delegations.grant("sa_happy", "del_happy")

      assert {:ok, plan} =
               Decisions.request_manual_execution(envelope.id, "sa_happy",
                 reason: "manual_confirm"
               )

      assert plan.decision_id == envelope.id
      assert plan.intent_id == envelope.intent_id
      assert plan.smart_account_id == "sa_happy"
      assert plan.execution_status == :prepared
      assert plan.active == true
    end

    test "stamps the new plan with the parent intent's workspace_id (#158d)" do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{slug: "exec-stamp", name: "Exec stamp"})

      intent = agent_intent(workspace_id: ws.id)

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :auto_exec,
          current: true
        )

      {:ok, _del} = Delegations.grant("sa_stamp", "del_stamp")

      assert {:ok, plan} =
               Decisions.request_manual_execution(envelope.id, "sa_stamp",
                 reason: "manual_confirm"
               )

      assert plan.workspace_id == ws.id
    end

    test "leaves plan workspace_id nil when parent intent is unscoped (legacy)" do
      intent = agent_intent(workspace_id: nil)

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :auto_exec,
          current: true
        )

      {:ok, _del} = Delegations.grant("sa_legacy", "del_legacy")

      assert {:ok, plan} =
               Decisions.request_manual_execution(envelope.id, "sa_legacy",
                 reason: "manual_confirm"
               )

      assert plan.workspace_id == nil
    end

    test "gate 1: rejects non-current envelope" do
      envelope = decision_envelope(outcome: :auto_exec, current: false)
      {:ok, _del} = Delegations.grant("sa_g1", "del_g1")

      assert {:error, :not_current} =
               Decisions.request_manual_execution(envelope.id, "sa_g1")
    end

    test "gate 1: rejects non-auto_exec outcome" do
      envelope = decision_envelope(outcome: :hold, current: true)
      {:ok, _del} = Delegations.grant("sa_g1b", "del_g1b")

      assert {:error, :outcome_is_hold} =
               Decisions.request_manual_execution(envelope.id, "sa_g1b")
    end

    test "gate 2: rejects when active plan exists" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      _existing = execution_plan(decision: envelope, active: true)
      {:ok, _del} = Delegations.grant("sa_g2", "del_g2")

      assert {:error, :active_plan_exists} =
               Decisions.request_manual_execution(envelope.id, "sa_g2")
    end

    test "gate 3: rejects stablecoin routes whose adapter dispatch is not wired" do
      envelope =
        decision_envelope(
          outcome: :auto_exec,
          current: true,
          reasons: %{
            "items" => [
              %{
                "code" => "stablecoin_route_allowed",
                "message" => "stablecoin route selected",
                "details" => %{
                  "stablecoin_route" => %{
                    "execution_state" => "requires_adapter",
                    "provider" => "zerox",
                    "route_kind" => "swap"
                  }
                }
              }
            ]
          }
        )

      {:ok, _del} = Delegations.grant("sa_stable", "del_stable")

      assert {:error, :stablecoin_adapter_not_wired} =
               Decisions.request_manual_execution(envelope.id, "sa_stable")

      refute Decisions.active_plan_for(envelope.id)
      refute_enqueued(worker: RunExecution)
    end

    test "gate 4: rejects when runtime is paused" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      {:ok, _del} = Delegations.grant("sa_g3", "del_g3")
      {:ok, :paused} = Security.pause(:global)

      assert {:error, :runtime_paused} =
               Decisions.request_manual_execution(envelope.id, "sa_g3")
    end

    test "gate 5: rejects when delegation is not active" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      # No delegation for sa_g4

      assert {:error, :delegation_not_active} =
               Decisions.request_manual_execution(envelope.id, "sa_g4")
    end

    test "gate 5: rejects when delegation is revoking" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      {:ok, _del} = Delegations.grant("sa_g4b", "del_g4b")
      {:ok, _} = Delegations.record_revoke_requested("sa_g4b")

      assert {:error, :delegation_not_active} =
               Decisions.request_manual_execution(envelope.id, "sa_g4b")
    end

    test "gate 5: rejects when delegation is expired" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)

      {:ok, _del} =
        Delegations.grant("sa_g4c", "del_g4c", %{
          expires_at: ~U[2020-01-01 00:00:00Z]
        })

      assert {:error, :delegation_not_active} =
               Decisions.request_manual_execution(envelope.id, "sa_g4c")
    end

    test "includes signing_requirements from delegation" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)

      {:ok, _del} =
        Delegations.grant("sa_sign", "del_sign", %{
          scope: %{"asset" => "USDC", "limit" => "1000"}
        })

      assert {:ok, plan} =
               Decisions.request_manual_execution(envelope.id, "sa_sign")

      assert plan.signing_requirements["delegation_id"] == "del_sign"
      assert plan.signing_requirements["scope"] == %{"asset" => "USDC", "limit" => "1000"}
    end

    test "returns :not_found for missing envelope" do
      {:ok, _del} = Delegations.grant("sa_nf", "del_nf")

      assert {:error, :not_found} =
               Decisions.request_manual_execution(Ecto.UUID.generate(), "sa_nf")
    end
  end

  describe "dispatch_auto_exec/3" do
    test "creates a plan, audits as auto_dispatched, and enqueues RunExecution" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      {:ok, _del} = Delegations.grant("sa-auto-disp", "del-auto-disp")

      assert {:ok, plan} = Decisions.dispatch_auto_exec(envelope.id, "sa-auto-disp")

      assert plan.decision_id == envelope.id
      assert plan.intent_id == envelope.intent_id
      assert plan.smart_account_id == "sa-auto-disp"
      assert plan.execution_status == :prepared
      assert plan.active

      assert_enqueued(
        worker: RunExecution,
        queue: :executions_run,
        args: %{"decision_id" => envelope.id}
      )

      assert "execution.auto_dispatched" in audit_event_types_for_subject(plan.id)
    end

    test "reuses the manual-path gates: rejects non-current envelopes" do
      envelope = decision_envelope(outcome: :auto_exec, current: false)
      {:ok, _del} = Delegations.grant("sa-auto-nc", "del-auto-nc")

      assert {:error, :not_current} =
               Decisions.dispatch_auto_exec(envelope.id, "sa-auto-nc")
    end

    test "stamps the auto-dispatched plan with the parent intent's workspace_id (#158d)" do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{slug: "auto-stamp", name: "Auto stamp"})

      intent = agent_intent(workspace_id: ws.id)

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :auto_exec,
          current: true
        )

      {:ok, _del} = Delegations.grant("sa-auto-stamp", "del-auto-stamp")

      assert {:ok, plan} = Decisions.dispatch_auto_exec(envelope.id, "sa-auto-stamp")
      assert plan.workspace_id == ws.id
    end

    test "reuses the manual-path gates: rejects when an active plan already exists" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      _existing = execution_plan(decision: envelope, active: true)
      {:ok, _del} = Delegations.grant("sa-auto-active", "del-auto-active")

      assert {:error, :active_plan_exists} =
               Decisions.dispatch_auto_exec(envelope.id, "sa-auto-active")
    end

    test "reuses the manual-path gates: rejects when paused" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      {:ok, _del} = Delegations.grant("sa-auto-pause", "del-auto-pause")
      {:ok, :paused} = Bank.Security.pause(:global)

      assert {:error, :runtime_paused} =
               Decisions.dispatch_auto_exec(envelope.id, "sa-auto-pause")
    end

    test "reuses the manual-path gates: rejects when delegation is not active" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)

      assert {:error, :delegation_not_active} =
               Decisions.dispatch_auto_exec(envelope.id, "sa-auto-missing")
    end

    test "rejects non-auto_exec envelopes with :outcome_is_*" do
      envelope = decision_envelope(outcome: :hold, current: true)
      {:ok, _del} = Delegations.grant("sa-auto-hold", "del-auto-hold")

      assert {:error, :outcome_is_hold} =
               Decisions.dispatch_auto_exec(envelope.id, "sa-auto-hold")
    end

    test "rejects when ANY plan is active for the intent (even on a prior superseded envelope)" do
      # This is the auto-path-only safety gate that the manual path
      # intentionally skips: a re-evaluation must not dispatch a
      # parallel plan while a plan from a prior decision is still
      # in flight for the same intent.
      intent = agent_intent()
      prior_envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: false)
      _prior_plan = execution_plan(decision: prior_envelope, intent_id: intent.id, active: true)

      successor_envelope =
        decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      {:ok, _del} = Delegations.grant("sa-auto-inflight", "del-auto-inflight")

      assert {:error, :active_plan_exists} =
               Decisions.dispatch_auto_exec(successor_envelope.id, "sa-auto-inflight")

      # The manual path does NOT enforce this intent-level gate; an
      # operator can still override after handling the in-flight plan.
      # The per-decision check is what gates the manual path.
      assert {:ok, _plan} =
               Decisions.request_manual_execution(successor_envelope.id, "sa-auto-inflight")
    end
  end

  describe "resolve_executable_account/0" do
    test "returns :no_executable_account when no delegations exist" do
      assert {:error, :no_executable_account} = Decisions.resolve_executable_account()
    end

    test "returns the unique smart_account_id when exactly one is executable" do
      {:ok, _del} = Delegations.grant("sa-resolve-1", "del-resolve-1")

      assert {:ok, "sa-resolve-1"} = Decisions.resolve_executable_account()
    end

    test "returns :ambiguous_executable_account when two or more are executable" do
      {:ok, _del1} = Delegations.grant("sa-resolve-2a", "del-resolve-2a")
      {:ok, _del2} = Delegations.grant("sa-resolve-2b", "del-resolve-2b")

      assert {:error, :ambiguous_executable_account} = Decisions.resolve_executable_account()
    end

    test "ignores non-executable (revoking / revoke_failed) delegations" do
      {:ok, _del1} = Delegations.grant("sa-resolve-3a", "del-resolve-3a")
      {:ok, _del2} = Delegations.grant("sa-resolve-3b", "del-resolve-3b")
      {:ok, _} = Delegations.record_revoke_requested("sa-resolve-3b")

      assert {:ok, "sa-resolve-3a"} = Decisions.resolve_executable_account()
    end
  end

  defp audit_event_types_for_subject(subject_id) do
    Bank.Repo.all(
      from(e in Bank.Audit.AuditEvent,
        where: e.subject_id == ^subject_id,
        select: e.event_type
      )
    )
  end

  # --- Bank.Decisions.abort_plan/3 (#230, #212) ---------------------------

  describe "abort_plan/3" do
    alias Bank.Audit.AuditEvent
    alias Bank.Decisions.ExecutionPlan

    setup do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "abort-#{System.unique_integer([:positive])}",
          name: "Abort"
        })

      {:ok, user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "abort-#{System.unique_integer([:positive])}",
          email: "abort-#{System.unique_integer([:positive])}@example.com",
          name: "Abort Operator"
        })

      Process.put(:bank_test_workspace_id, ws.id)
      ExUnit.Callbacks.on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

      %{workspace: ws, actor: user}
    end

    test "transitions :prepared plan to :aborted, transitions intent, emits audit",
         %{workspace: ws, actor: user} do
      intent = agent_intent(state: :decided, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: ws.id)

      assert {:ok, :aborted, aborted_plan, intent_transition} =
               Decisions.abort_plan(plan.id, ws,
                 reason: :operator_requested,
                 actor: :user,
                 actor_id: user.id
               )

      assert aborted_plan.execution_status == :aborted
      assert aborted_plan.final_outcome == :aborted
      assert aborted_plan.final_reason == "operator_requested"

      # Intent moved :decided → :blocked.
      assert {:transitioned, :decided, %AgentIntent{state: :blocked}} = intent_transition

      reloaded_intent = Bank.Repo.get!(AgentIntent, intent.id)
      assert reloaded_intent.state == :blocked
      assert reloaded_intent.current_execution_plan_id == plan.id

      # Audit rows: one execution.aborted + one intent.state_changed.
      types = audit_event_types_for_subject(plan.id)
      assert "execution.aborted" in types

      [exec_audit] =
        Bank.Repo.all(
          from(e in AuditEvent,
            where: e.subject_id == ^plan.id and e.event_type == "execution.aborted"
          )
        )

      assert exec_audit.actor == :user
      assert exec_audit.actor_id == user.id
      assert exec_audit.workspace_id == ws.id
      assert exec_audit.before_ref == %{"execution_status" => "prepared"}
      assert exec_audit.after_ref["execution_status"] == "aborted"
      assert exec_audit.after_ref["final_outcome"] == "aborted"
      # `final_reason` MUST be on `after_ref` so audit replay /
      # incident review can attribute the abort. Pre-#230 patch this
      # was missing from `Events.execution_transition/3`.
      assert exec_audit.after_ref["final_reason"] == "operator_requested"
    end

    test "is idempotent on already-terminal :aborted plan (no second audit row)",
         %{workspace: ws, actor: user} do
      intent = agent_intent(state: :decided, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: ws.id)

      assert {:ok, :aborted, _, _} = Decisions.abort_plan(plan.id, ws, actor_id: user.id)

      assert {:ok, :already_terminal, second_plan, _} =
               Decisions.abort_plan(plan.id, ws, actor_id: user.id)

      assert second_plan.execution_status == :aborted

      # Exactly one execution.aborted row.
      assert "execution.aborted" |> count_audit_for(plan.id) == 1
    end

    test "is idempotent on terminal :confirmed (no transition, no audit)",
         %{workspace: ws, actor: user} do
      intent = agent_intent(state: :executed, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)

      plan =
        execution_plan(
          decision: envelope,
          workspace_id: ws.id,
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      assert {:ok, :already_terminal, returned, intent_transition} =
               Decisions.abort_plan(plan.id, ws, actor_id: user.id)

      assert returned.execution_status == :confirmed
      assert {:no_transition, :executed} = intent_transition

      # No execution.aborted row written.
      assert "execution.aborted" |> count_audit_for(plan.id) == 0
    end

    test "rejects cross-workspace plan with :not_found (no existence leak)",
         %{workspace: ws, actor: user} do
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{slug: "other-abort", name: "Other"})

      # Plan belongs to other_ws, not the calling ws.
      Process.put(:bank_test_workspace_id, other_ws.id)
      intent = agent_intent(state: :decided, workspace_id: other_ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: other_ws.id)
      Process.put(:bank_test_workspace_id, ws.id)

      assert {:error, :not_found} =
               Decisions.abort_plan(plan.id, ws, actor_id: user.id)

      # Plan in other workspace is unchanged.
      reloaded = Bank.Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :prepared
    end

    test "rejects missing plan id with :not_found", %{workspace: ws, actor: user} do
      assert {:error, :not_found} =
               Decisions.abort_plan(Ecto.UUID.generate(), ws, actor_id: user.id)
    end

    test "rejects :signing plan with {:not_safe_to_abort, :signing}",
         %{workspace: ws, actor: user} do
      intent = agent_intent(state: :executing, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: ws.id, execution_status: :signing)

      assert {:error, {:not_safe_to_abort, :signing}} =
               Decisions.abort_plan(plan.id, ws, actor_id: user.id)

      # Plan unchanged; no audit row.
      reloaded = Bank.Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :signing
      assert "execution.aborted" |> count_audit_for(plan.id) == 0
    end

    test "rejects :broadcasting plan with {:not_safe_to_abort, :broadcasting}",
         %{workspace: ws, actor: user} do
      intent = agent_intent(state: :executing, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)

      plan =
        execution_plan(decision: envelope, workspace_id: ws.id, execution_status: :broadcasting)

      assert {:error, {:not_safe_to_abort, :broadcasting}} =
               Decisions.abort_plan(plan.id, ws, actor_id: user.id)
    end

    test "leaves intent untouched when intent is already terminal :blocked",
         %{workspace: ws, actor: user} do
      intent = agent_intent(state: :blocked, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: ws.id)

      assert {:ok, :aborted, _, intent_transition} =
               Decisions.abort_plan(plan.id, ws, actor_id: user.id)

      assert {:no_transition, :blocked} = intent_transition

      reloaded_intent = Bank.Repo.get!(AgentIntent, intent.id)
      assert reloaded_intent.state == :blocked
    end

    test "manual abort flips `active: false` so request_manual_execution can replace the plan",
         %{workspace: ws, actor: user} do
      # Same decision setup as the happy path. After abort we should
      # be able to call `request_manual_execution/3` for the same
      # decision (with all gates satisfied) and have it create a
      # fresh plan — the partial unique index
      # `execution_plans_decision_active_idx` would otherwise reject
      # the second insert because it requires `active: true` to be
      # exclusive per decision.
      intent = agent_intent(state: :decided, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent, current: true, state: :decided)
      plan = execution_plan(decision: envelope, workspace_id: ws.id)

      assert {:ok, :aborted, aborted_plan, _} =
               Decisions.abort_plan(plan.id, ws, actor_id: user.id)

      assert aborted_plan.active == false

      # `count_active_executions/1` should not include the aborted plan.
      # (The terminal-state filter and the `active: false` flag now
      # agree for manual aborts.)
      reloaded = Bank.Repo.get!(Bank.Decisions.ExecutionPlan, plan.id)
      assert reloaded.active == false
      assert reloaded.execution_status == :aborted

      # Now grant a delegation so `request_manual_execution/3`'s gates
      # pass, then attempt the retry. It should succeed and insert a
      # new active plan.
      {:ok, _del} = Bank.Delegations.grant("sa-retry-after-abort", "del-retry-after-abort")

      # Bring the intent back to :decided so the manual execution path
      # accepts it (manual abort moved the parent intent to :blocked).
      {:ok, _} =
        intent
        |> Bank.Intents.AgentIntent.current_pointer_changeset(%{state: :decided})
        |> Bank.Repo.update()

      assert {:ok, new_plan} =
               Decisions.request_manual_execution(envelope.id, "sa-retry-after-abort",
                 reason: "post_abort_retry"
               )

      assert new_plan.id != plan.id
      assert new_plan.execution_status == :prepared
      assert new_plan.active == true
    end

    test "audit JSON contains no raw bearer / secret_hash / Authorization",
         %{workspace: ws, actor: user} do
      intent = agent_intent(state: :decided, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: ws.id)

      assert {:ok, :aborted, _, _} =
               Decisions.abort_plan(plan.id, ws, actor_id: user.id, reason: :stuck_pending)

      [event] =
        Bank.Repo.all(
          from(e in AuditEvent,
            where: e.subject_id == ^plan.id and e.event_type == "execution.aborted"
          )
        )

      json = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace]) |> Jason.encode!()

      refute json =~ "secret_hash"
      refute json =~ "Bearer "
      refute json =~ "Authorization"
    end
  end

  defp count_audit_for(event_type, subject_id) do
    Bank.Repo.aggregate(
      from(e in Bank.Audit.AuditEvent,
        where: e.event_type == ^event_type and e.subject_id == ^subject_id
      ),
      :count
    )
  end
end
