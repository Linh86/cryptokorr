defmodule Bank.Decisions.ExecutionPlanTest do
  use Bank.DataCase, async: true

  alias Bank.Decisions.ExecutionPlan
  alias Bank.Fixtures

  describe "active invariant" do
    test "allows one active plan per decision" do
      decision = Fixtures.decision_envelope()
      plan = Fixtures.execution_plan(decision: decision)
      assert plan.active
    end

    test "rejects a second active plan for the same decision" do
      decision = Fixtures.decision_envelope()
      _first = Fixtures.execution_plan(decision: decision)

      {:error, changeset} =
        %ExecutionPlan{}
        |> ExecutionPlan.changeset(%{
          decision_id: decision.id,
          intent_id: decision.intent_id,
          chain: "base",
          asset: "USDC",
          smart_account_id: "sa-x",
          execution_status: :prepared,
          active: true
        })
        |> Repo.insert()

      refute changeset.valid?

      assert errors_on(changeset)[:decision_id] == [
               "another active plan already exists for this decision"
             ]
    end

    test "a deactivated plan lets the next plan insert" do
      decision = Fixtures.decision_envelope()
      first = Fixtures.execution_plan(decision: decision)

      {:ok, _} =
        first
        |> ExecutionPlan.deactivate()
        |> Repo.update()

      second =
        Fixtures.execution_plan(decision: decision, smart_account_id: "sa-second")

      assert second.id
      refute second.id == first.id
    end
  end

  describe "final_outcome/execution_status alignment" do
    test "rejects confirmed status with a mismatched final_outcome" do
      decision = Fixtures.decision_envelope()

      changeset =
        %ExecutionPlan{}
        |> ExecutionPlan.changeset(%{
          decision_id: decision.id,
          intent_id: decision.intent_id,
          chain: "base",
          asset: "USDC",
          smart_account_id: "sa-x",
          execution_status: :confirmed,
          final_outcome: :reverted
        })

      refute changeset.valid?
      assert errors_on(changeset).final_outcome != []
    end

    test "accepts matched status/outcome" do
      decision = Fixtures.decision_envelope()

      changeset =
        %ExecutionPlan{}
        |> ExecutionPlan.changeset(%{
          decision_id: decision.id,
          intent_id: decision.intent_id,
          chain: "base",
          asset: "USDC",
          smart_account_id: "sa-x",
          execution_status: :confirmed,
          final_outcome: :confirmed
        })

      assert changeset.valid?
    end
  end

  describe "progress_changeset/2" do
    test "advances status and tx_refs without touching the plan body" do
      plan = Fixtures.execution_plan()

      {:ok, updated} =
        plan
        |> ExecutionPlan.progress_changeset(%{
          execution_status: :broadcasting,
          tx_refs: ["0xhash1"]
        })
        |> Repo.update()

      assert updated.execution_status == :broadcasting
      assert updated.tx_refs == ["0xhash1"]
      # Unchanged
      assert updated.smart_account_id == plan.smart_account_id
    end
  end
end
