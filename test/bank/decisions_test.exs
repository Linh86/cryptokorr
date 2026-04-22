defmodule Bank.DecisionsTest do
  @moduledoc """
  Context-level tests for `Bank.Decisions` — approval state machine
  and manual execution gates.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

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

    test "happy path: writes auto_exec successor and does NOT enqueue execution", %{
      intent: intent,
      envelope: envelope
    } do
      assert {:ok, successor, :recorded} =
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

      # No execution plan was implicitly created.
      assert is_nil(Decisions.active_plan_for(successor.id))

      # No RunExecution job was enqueued. Operator must follow up with
      # POST /v1/decisions/{id}/execute.
      refute_enqueued(worker: RunExecution)
    end

    test "while runtime paused: still records the approval (paused does not block decisions)",
         %{
           envelope: envelope
         } do
      {:ok, :paused} = Security.pause(:global)

      assert {:ok, successor, :recorded} =
               Decisions.approve(envelope.id, actor_id: "op-pause")

      assert successor.outcome == :auto_exec
      assert successor.state == :decided
      assert successor.current == true

      # Approval no longer attempts dispatch, so pause has no extra
      # effect on its side.
      refute_enqueued(worker: RunExecution)
      assert is_nil(Decisions.active_plan_for(successor.id))
    end

    test "rejects already-superseded envelope", %{envelope: envelope} do
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

    test "approved envelope is executable via request_manual_execution", %{
      envelope: envelope
    } do
      {:ok, successor, :recorded} =
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
end
