defmodule Bank.DecisionsTest do
  @moduledoc """
  Context-level tests for `Bank.Decisions` — manual execution gates.
  """

  use Bank.DataCase, async: false

  import Bank.Fixtures

  alias Bank.Decisions
  alias Bank.Delegations
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

    test "gate 3: rejects when runtime is paused" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      {:ok, _del} = Delegations.grant("sa_g3", "del_g3")
      {:ok, :paused} = Security.pause(:global)

      assert {:error, :runtime_paused} =
               Decisions.request_manual_execution(envelope.id, "sa_g3")
    end

    test "gate 4: rejects when delegation is not active" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      # No delegation for sa_g4

      assert {:error, :delegation_not_active} =
               Decisions.request_manual_execution(envelope.id, "sa_g4")
    end

    test "gate 4: rejects when delegation is revoking" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      {:ok, _del} = Delegations.grant("sa_g4b", "del_g4b")
      {:ok, _} = Delegations.record_revoke_requested("sa_g4b")

      assert {:error, :delegation_not_active} =
               Decisions.request_manual_execution(envelope.id, "sa_g4b")
    end

    test "gate 4: rejects when delegation is expired" do
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
