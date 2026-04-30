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
end
