defmodule Bank.Decisions.EvaluateIntentTest do
  @moduledoc """
  Pipeline-shape tests for `Bank.Decisions.evaluate_intent/2`.

  Covers the cases the worker depends on:

    * happy paths — trusted counterparty under threshold yields
      `:auto_exec`; raw unknown address yields `:approval_required` /
      `:block` depending on amount; sanctioned wallet yields `:block`.
    * idempotency — re-running the facade demotes the prior current
      rows and inserts successors with `supersedes_id` set, leaving
      replay history intact.
    * fail-closed — a degraded preview never produces `:auto_exec`
      even when trust + policy would allow it.
    * state guards — terminal / in-flight states return
      `{:wrong_state, state}` without mutation.
    * no execution dispatch — issue #136 must not enqueue
      `RunExecution` even on `:auto_exec` outcomes (#137 owns that).
  """

  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Decisions
  alias Bank.Decisions.{DecisionEnvelope, SimulationReport, TrustAssessment}
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Quotes.Preview

  defp ok_preview(intent, overrides \\ %{}) do
    Map.merge(
      %Preview{
        balance_impact: %{intent.asset => Decimal.negate(intent.amount)},
        estimated_gas: 120_000,
        estimated_fee: Decimal.new("0.00015"),
        fee_asset: "ETH",
        route: %{"type" => "erc20_transfer", "asset" => intent.asset},
        failure_conditions: ["balance falls below requested amount"],
        provider: "stub",
        provider_trace_ref: "stub-fixture",
        generated_at: DateTime.utc_now(),
        freshness_ttl_seconds: 30
      },
      overrides
    )
  end

  defp trusted_counterparty do
    cp = Fixtures.counterparty()
    _label = Fixtures.address_label(counterparty: cp, chain: "base")

    _ =
      Fixtures.trust_assertion(
        subject: cp,
        level: :trusted,
        scope: %{}
      )

    cp
  end

  defp small_trusted_intent do
    cp = trusted_counterparty()
    Fixtures.agent_intent(counterparty: cp, amount: Decimal.new("25"))
  end

  describe "happy paths" do
    test "trusted counterparty under threshold yields :auto_exec :decided" do
      intent = small_trusted_intent()

      assert {:ok, result} =
               Decisions.evaluate_intent(intent, preview: {:ok, ok_preview(intent)})

      assert result.outcome == :auto_exec
      assert result.decision.outcome == :auto_exec
      assert result.decision.risk_tier == :low
      assert result.decision.current
      assert result.decision.policy_snapshot_ref == %{"rule_ids" => []}
      assert result.decision.trust_assessment_id == result.trust.id
      assert result.decision.simulation_report_id == result.simulation.id

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :decided
      assert reloaded.current_decision_id == result.decision.id
      assert reloaded.current_simulation_id == result.simulation.id
      assert reloaded.current_trust_assessment_id == result.trust.id

      assert result.simulation.status == :completed
      assert result.simulation.provider == "stub"

      assert result.simulation.predicted_balance_changes == %{
               "items" => [%{"asset" => intent.asset, "delta" => "-25"}]
             }
    end

    test "raw unknown address under approval ceiling yields :approval_required :decided" do
      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0x" <> String.duplicate("a", 40),
          amount: Decimal.new("10")
        )

      assert {:ok, result} =
               Decisions.evaluate_intent(intent, preview: {:ok, ok_preview(intent)})

      assert result.outcome == :approval_required
      assert result.decision.outcome == :approval_required
      assert result.decision.approval_expires_at

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :decided
    end

    test "raw unknown address over approval ceiling yields :block :blocked" do
      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0x" <> String.duplicate("b", 40),
          amount: Decimal.new("500")
        )

      assert {:ok, result} =
               Decisions.evaluate_intent(intent, preview: {:ok, ok_preview(intent)})

      assert result.outcome == :block
      assert result.decision.outcome == :block
      assert result.decision.risk_tier == :severe

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :blocked
    end
  end

  describe "fail-closed" do
    test "preview unavailable holds even when trust + policy would auto" do
      intent = small_trusted_intent()

      assert {:ok, result} =
               Decisions.evaluate_intent(intent, preview: {:error, :provider_unavailable})

      assert result.outcome == :hold
      assert result.simulation.status == :failed

      assert result.simulation.failure_conditions == %{
               "items" => [
                 %{"kind" => "preview_failed", "message" => "preview provider unavailable"}
               ]
             }
    end

    test "simulation_failed produces :block" do
      intent = small_trusted_intent()

      assert {:ok, result} =
               Decisions.evaluate_intent(
                 intent,
                 preview: {:error, {:simulation_failed, "revert"}}
               )

      assert result.outcome == :block
      assert result.simulation.status == :failed

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :blocked
    end

    test "paused runtime holds the intent and never auto-execs" do
      intent = small_trusted_intent()

      assert {:ok, result} =
               Decisions.evaluate_intent(
                 intent,
                 paused?: true,
                 preview: {:ok, ok_preview(intent)}
               )

      assert result.outcome == :hold

      assert result.decision.reasons["items"] |> List.first() |> Map.fetch!("code") ==
               "runtime_paused"
    end
  end

  describe "supersession (re-evaluation)" do
    test "re-evaluation demotes prior trust / simulation / decision and chains supersedes_id" do
      intent = small_trusted_intent()

      assert {:ok, first} =
               Decisions.evaluate_intent(intent, preview: {:ok, ok_preview(intent)})

      reloaded_intent = Repo.get!(AgentIntent, intent.id)

      assert {:ok, second} =
               Decisions.evaluate_intent(reloaded_intent,
                 preview: {:ok, ok_preview(reloaded_intent)}
               )

      assert second.decision.id != first.decision.id
      assert second.decision.supersedes_id == first.decision.id
      assert second.decision.current

      assert second.trust.id != first.trust.id
      assert second.trust.supersedes_id == first.trust.id

      assert second.simulation.id != first.simulation.id
      assert second.simulation.supersedes_id == first.simulation.id

      # Prior rows are demoted, not deleted — replay relies on this.
      refute Repo.get!(DecisionEnvelope, first.decision.id).current
      refute Repo.get!(TrustAssessment, first.trust.id).current
      refute Repo.get!(SimulationReport, first.simulation.id).current
    end

    test "replay surfaces both the prior and new decision in deterministic order" do
      intent = small_trusted_intent()

      {:ok, first} = Decisions.evaluate_intent(intent, preview: {:ok, ok_preview(intent)})
      reloaded = Repo.get!(AgentIntent, intent.id)
      {:ok, second} = Decisions.evaluate_intent(reloaded, preview: {:ok, ok_preview(reloaded)})

      {:ok, bundle} = Bank.Audit.replay(intent.id)

      decision_ids = Enum.map(bundle.decisions, & &1.id)
      assert first.decision.id in decision_ids
      assert second.decision.id in decision_ids
      # Sorted by decided_at asc, id asc.
      assert Enum.find_index(decision_ids, &(&1 == first.decision.id)) <
               Enum.find_index(decision_ids, &(&1 == second.decision.id))

      trust_ids = Enum.map(bundle.trust_assessments, & &1.id)
      assert first.trust.id in trust_ids
      assert second.trust.id in trust_ids

      simulation_ids = Enum.map(bundle.simulations, & &1.id)
      assert first.simulation.id in simulation_ids
      assert second.simulation.id in simulation_ids

      audit_event_types = Enum.map(bundle.audit, & &1.event_type)
      assert "decision.decided" in audit_event_types
    end
  end

  describe "state guards" do
    for state <- [:executing, :executed, :cancelled, :expired] do
      @state state

      test "rejects evaluation for #{@state} intent without mutation" do
        intent = bump_state!(Fixtures.agent_intent(), @state)

        assert {:error, {:wrong_state, @state}} = Decisions.evaluate_intent(intent)

        # No new child rows written.
        assert [] = Repo.all(TrustAssessment)
        assert [] = Repo.all(SimulationReport)
        assert [] = Repo.all(DecisionEnvelope)

        # Intent state untouched.
        assert Repo.get!(AgentIntent, intent.id).state == @state
      end
    end

    test "returns :not_found when the id doesn't resolve" do
      assert {:error, :not_found} = Decisions.evaluate_intent(Ecto.UUID.generate())
    end
  end

  describe "auto-exec dispatch (issue #137)" do
    test "creates an active ExecutionPlan and enqueues RunExecution when one delegation is executable" do
      intent = small_trusted_intent()
      {:ok, _del} = Bank.Delegations.grant("sa-auto-1", "del-auto-1")

      assert {:ok, result} =
               Decisions.evaluate_intent(intent, preview: {:ok, ok_preview(intent)})

      assert result.outcome == :auto_exec
      assert result.dispatch == :dispatched
      assert %Bank.Decisions.ExecutionPlan{} = result.execution_plan
      assert result.execution_plan.smart_account_id == "sa-auto-1"
      assert result.execution_plan.execution_status == :prepared
      assert result.execution_plan.active == true
      assert result.execution_plan.decision_id == result.decision.id
      assert result.execution_plan.intent_id == intent.id

      assert_enqueued(
        worker: Bank.Runtime.Workers.RunExecution,
        queue: :executions_run,
        args: %{"decision_id" => result.decision.id}
      )
    end

    test "holds dispatch with :no_executable_account when no delegation exists" do
      intent = small_trusted_intent()

      assert {:ok, result} =
               Decisions.evaluate_intent(intent, preview: {:ok, ok_preview(intent)})

      assert result.outcome == :auto_exec
      assert result.dispatch == {:held, :no_executable_account}
      assert is_nil(result.execution_plan)

      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :decided

      assert audit_event_types_for_intent(intent.id)
             |> Enum.any?(&(&1 == "intent.auto_exec_held"))
    end

    test "holds dispatch with :ambiguous_executable_account when multiple delegations are active" do
      intent = small_trusted_intent()
      {:ok, _del1} = Bank.Delegations.grant("sa-amb-1", "del-amb-1")
      {:ok, _del2} = Bank.Delegations.grant("sa-amb-2", "del-amb-2")

      assert {:ok, result} =
               Decisions.evaluate_intent(intent, preview: {:ok, ok_preview(intent)})

      assert result.dispatch == {:held, :ambiguous_executable_account}
      assert is_nil(result.execution_plan)
      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
    end

    test "honours an explicit :smart_account_id opt over the resolver" do
      intent = small_trusted_intent()
      {:ok, _del1} = Bank.Delegations.grant("sa-amb-3", "del-amb-3")
      {:ok, _del2} = Bank.Delegations.grant("sa-amb-4", "del-amb-4")
      {:ok, _del3} = Bank.Delegations.grant("sa-explicit", "del-explicit")

      assert {:ok, result} =
               Decisions.evaluate_intent(
                 intent,
                 preview: {:ok, ok_preview(intent)},
                 smart_account_id: "sa-explicit"
               )

      assert result.dispatch == :dispatched
      assert result.execution_plan.smart_account_id == "sa-explicit"
    end

    test "holds dispatch when the runtime is paused, even with an executable account" do
      intent = small_trusted_intent()
      {:ok, _del} = Bank.Delegations.grant("sa-paused", "del-paused")

      assert {:ok, result} =
               Decisions.evaluate_intent(
                 intent,
                 paused?: true,
                 preview: {:ok, ok_preview(intent)}
               )

      # The autonomy router itself emits :hold under :paused?, so the
      # decision is :hold and dispatch is :not_applicable. This test
      # pins that pause is enforced upstream of dispatch.
      assert result.outcome == :hold
      assert result.dispatch == :not_applicable
      assert is_nil(result.execution_plan)
      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
    end

    test "block / hold / approval_required decisions never dispatch" do
      block_intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0x" <> String.duplicate("d", 40),
          amount: Decimal.new("500")
        )

      {:ok, _del} = Bank.Delegations.grant("sa-block-1", "del-block-1")

      assert {:ok, %{outcome: :block, dispatch: :not_applicable, execution_plan: nil}} =
               Decisions.evaluate_intent(block_intent,
                 preview: {:ok, ok_preview(block_intent)}
               )

      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
    end

    test "re-evaluation never dispatches a parallel plan while the prior is still active" do
      intent = small_trusted_intent()
      {:ok, _del} = Bank.Delegations.grant("sa-idem-1", "del-idem-1")

      assert {:ok, %{dispatch: :dispatched, execution_plan: plan_one}} =
               Decisions.evaluate_intent(intent, preview: {:ok, ok_preview(intent)})

      reloaded = Repo.get!(AgentIntent, intent.id)

      # Without the intent-level gate, this re-evaluation would
      # produce a new envelope, pass the per-decision active-plan
      # check (which is per envelope id), and dispatch a SECOND plan
      # for the same intent — racing the still-in-flight plan_one
      # against the adapter. The intent-level gate in
      # `dispatch_auto_exec/3` rejects with :active_plan_exists.
      assert {:ok, %{dispatch: {:held, :active_plan_exists}, execution_plan: nil}} =
               Decisions.evaluate_intent(reloaded, preview: {:ok, ok_preview(reloaded)})

      # The original plan is still active and untouched.
      assert Repo.get!(Bank.Decisions.ExecutionPlan, plan_one.id).active
    end

    test "approval_required decisions enqueue ExpireApproval at the envelope's expiry" do
      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0x" <> String.duplicate("c", 40),
          amount: Decimal.new("10")
        )

      assert {:ok, %{decision: envelope, outcome: :approval_required, dispatch: :not_applicable}} =
               Decisions.evaluate_intent(intent, preview: {:ok, ok_preview(intent)})

      assert envelope.approval_expires_at

      assert_enqueued(
        worker: Bank.Runtime.Workers.ExpireApproval,
        queue: :approvals_expire,
        args: %{"decision_envelope_id" => envelope.id}
      )
    end
  end

  defp audit_event_types_for_intent(intent_id) do
    import Ecto.Query

    Repo.all(
      from(e in Bank.Audit.AuditEvent,
        where: e.correlation_id == ^intent_id,
        order_by: [asc: e.ts, asc: e.id],
        select: e.event_type
      )
    )
  end

  defp bump_state!(intent, state) do
    {:ok, updated} =
      intent
      |> AgentIntent.current_pointer_changeset(%{state: state})
      |> Repo.update()

    updated
  end
end
