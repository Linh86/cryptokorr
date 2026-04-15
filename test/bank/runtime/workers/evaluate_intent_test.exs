defmodule Bank.Runtime.Workers.EvaluateIntentTest do
  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.Workers.EvaluateIntent

  test "cancels with :engines_pending for a freshly-submitted intent" do
    intent = Fixtures.agent_intent()

    assert {:cancel, :engines_pending} =
             perform_job(EvaluateIntent, %{"intent_id" => intent.id})

    # No state change — the intent is still :submitted
    assert %AgentIntent{state: :submitted} = Repo.get!(AgentIntent, intent.id)
  end

  test "cancels with :not_found for a missing intent id" do
    assert {:cancel, :not_found} =
             perform_job(EvaluateIntent, %{"intent_id" => Ecto.UUID.generate()})
  end

  test "cancels with {:wrong_state, state} when the intent has moved past :submitted" do
    intent = Fixtures.agent_intent()

    {:ok, _} =
      intent
      |> AgentIntent.current_pointer_changeset(%{state: :evaluating})
      |> Repo.update()

    assert {:cancel, {:wrong_state, :evaluating}} =
             perform_job(EvaluateIntent, %{"intent_id" => intent.id})
  end

  test "cancels with :malformed_args when intent_id is missing" do
    assert {:cancel, :malformed_args} = perform_job(EvaluateIntent, %{"foo" => "bar"})
  end
end
