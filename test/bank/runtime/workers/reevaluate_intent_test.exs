defmodule Bank.Runtime.Workers.ReevaluateIntentTest do
  @moduledoc """
  Worker-level tests for `Bank.Runtime.Workers.ReevaluateIntent`.

  Pins the state-routing contract for re-evaluation: only intents
  that already have at least one decision (`:decided` or `:blocked`)
  are valid targets; everything else cancels without mutation. The
  pipeline shape (supersession of prior trust / simulation /
  decision rows, replay history) is covered in the facade tests at
  `test/bank/decisions/evaluate_intent_test.exs`.
  """

  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.Workers.ReevaluateIntent

  describe "perform/1 happy paths" do
    test "re-evaluates a :decided intent and supersedes the prior current decision" do
      intent = Fixtures.agent_intent()

      # Initial evaluation establishes a current decision.
      {:ok, %{decision: prior_decision}} = Bank.Decisions.evaluate_intent(intent)
      reloaded_after_first = Repo.get!(AgentIntent, intent.id)
      assert reloaded_after_first.state in [:decided, :blocked]

      assert :ok =
               perform_job(ReevaluateIntent, %{
                 "intent_id" => intent.id,
                 "reason" => "policy_changed"
               })

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.current_decision_id != prior_decision.id

      successor = Repo.get!(DecisionEnvelope, reloaded.current_decision_id)
      assert successor.current
      assert successor.supersedes_id == prior_decision.id

      demoted = Repo.get!(DecisionEnvelope, prior_decision.id)
      refute demoted.current
    end

    test "re-evaluates a :blocked intent" do
      intent = Fixtures.agent_intent() |> bump_state!(:blocked)

      assert :ok =
               perform_job(ReevaluateIntent, %{
                 "intent_id" => intent.id,
                 "reason" => "trust_changed"
               })

      reloaded = Repo.get!(AgentIntent, intent.id)
      assert reloaded.current_decision_id
    end
  end

  describe "perform/1 guards" do
    test "cancels with {:wrong_state, state} for an :executing intent" do
      intent = Fixtures.agent_intent() |> bump_state!(:executing)

      assert {:cancel, {:wrong_state, :executing}} =
               perform_job(ReevaluateIntent, %{
                 "intent_id" => intent.id,
                 "reason" => "policy_changed"
               })
    end

    test "cancels with {:wrong_state, state} for a :submitted intent (use EvaluateIntent)" do
      intent = Fixtures.agent_intent()

      assert {:cancel, {:wrong_state, :submitted}} =
               perform_job(ReevaluateIntent, %{
                 "intent_id" => intent.id,
                 "reason" => "policy_changed"
               })
    end

    test "cancels with :not_found for unknown id" do
      assert {:cancel, :not_found} =
               perform_job(ReevaluateIntent, %{
                 "intent_id" => Ecto.UUID.generate(),
                 "reason" => "anything"
               })
    end

    test "cancels with :malformed_args when intent_id is missing" do
      assert {:cancel, :malformed_args} = perform_job(ReevaluateIntent, %{"foo" => "bar"})
    end

    test "does not enqueue execution work" do
      intent = Fixtures.agent_intent()
      {:ok, _} = Bank.Decisions.evaluate_intent(intent)

      assert :ok =
               perform_job(ReevaluateIntent, %{
                 "intent_id" => intent.id,
                 "reason" => "policy_changed"
               })

      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
      refute_enqueued(worker: Bank.Runtime.Workers.ConfirmExecution)
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
