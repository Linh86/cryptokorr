defmodule Bank.Runtime.Workers.EvaluateIntentTest do
  @moduledoc """
  Worker-level tests for `Bank.Runtime.Workers.EvaluateIntent`.

  Covers the wiring between the worker and the live evaluation
  pipeline (issue #136). Detailed pipeline-shape coverage lives in
  `test/bank/decisions/evaluate_intent_test.exs`; this file pins the
  worker's state-routing and idempotency contract.
  """

  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Decisions.{DecisionEnvelope, SimulationReport, TrustAssessment}
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.Workers.EvaluateIntent

  describe "perform/1 happy path" do
    test "evaluates a freshly-submitted intent end-to-end" do
      intent = Fixtures.agent_intent()

      assert :ok = perform_job(EvaluateIntent, %{"intent_id" => intent.id})

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state in [:decided, :blocked]
      assert reloaded.current_decision_id
      assert reloaded.current_simulation_id
      assert reloaded.current_trust_assessment_id

      assert %DecisionEnvelope{current: true} =
               Repo.get!(DecisionEnvelope, reloaded.current_decision_id)

      assert %TrustAssessment{current: true} =
               Repo.get!(TrustAssessment, reloaded.current_trust_assessment_id)

      assert %SimulationReport{current: true} =
               Repo.get!(SimulationReport, reloaded.current_simulation_id)
    end

    test "treats :evaluating as a recoverable initial state" do
      intent = Fixtures.agent_intent() |> bump_state!(:evaluating)

      assert :ok = perform_job(EvaluateIntent, %{"intent_id" => intent.id})

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.state in [:decided, :blocked]
    end
  end

  describe "perform/1 guards" do
    test "cancels with :not_found for a missing intent id" do
      assert {:cancel, :not_found} =
               perform_job(EvaluateIntent, %{"intent_id" => Ecto.UUID.generate()})
    end

    test "cancels with {:wrong_state, state} for an already-decided intent" do
      intent = Fixtures.agent_intent() |> bump_state!(:decided)

      assert {:cancel, {:wrong_state, :decided}} =
               perform_job(EvaluateIntent, %{"intent_id" => intent.id})
    end

    test "cancels with {:wrong_state, state} for a :blocked intent" do
      intent = Fixtures.agent_intent() |> bump_state!(:blocked)

      assert {:cancel, {:wrong_state, :blocked}} =
               perform_job(EvaluateIntent, %{"intent_id" => intent.id})
    end

    test "cancels with {:wrong_state, state} for an :executing intent" do
      intent = Fixtures.agent_intent() |> bump_state!(:executing)

      assert {:cancel, {:wrong_state, :executing}} =
               perform_job(EvaluateIntent, %{"intent_id" => intent.id})
    end

    test "cancels with :malformed_args when intent_id is missing" do
      assert {:cancel, :malformed_args} = perform_job(EvaluateIntent, %{"foo" => "bar"})
    end

    test "does not enqueue execution work" do
      intent = Fixtures.agent_intent()
      assert :ok = perform_job(EvaluateIntent, %{"intent_id" => intent.id})

      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
      refute_enqueued(worker: Bank.Runtime.Workers.ConfirmExecution)
    end
  end

  describe "idempotency" do
    test "running the worker twice on the same submitted intent is safe" do
      intent = Fixtures.agent_intent()

      assert :ok = perform_job(EvaluateIntent, %{"intent_id" => intent.id})
      reloaded_first = Repo.get!(AgentIntent, intent.id)

      # Second invocation hits the wrong-state guard because the intent
      # is already `:decided` or `:blocked` — the re-eval queue handles
      # those, not this worker.
      assert {:cancel, {:wrong_state, _}} =
               perform_job(EvaluateIntent, %{"intent_id" => intent.id})

      assert Repo.get!(AgentIntent, intent.id).current_decision_id ==
               reloaded_first.current_decision_id
    end
  end

  defp bump_state!(intent, state) do
    {:ok, updated} =
      intent
      |> AgentIntent.current_pointer_changeset(%{state: state})
      |> Repo.update()

    updated
  end
end
