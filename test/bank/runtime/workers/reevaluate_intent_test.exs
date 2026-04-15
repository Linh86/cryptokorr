defmodule Bank.Runtime.Workers.ReevaluateIntentTest do
  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.Workers.ReevaluateIntent

  defp bump_state!(intent, state) do
    {:ok, updated} =
      intent
      |> AgentIntent.current_pointer_changeset(%{state: state})
      |> Repo.update()

    updated
  end

  test "cancels with :engines_pending for a :decided intent" do
    intent = Fixtures.agent_intent() |> bump_state!(:decided)

    assert {:cancel, :engines_pending} =
             perform_job(ReevaluateIntent, %{
               "intent_id" => intent.id,
               "reason" => "policy_changed"
             })
  end

  test "cancels with :engines_pending for a :blocked intent (policy-change driven reeval)" do
    intent = Fixtures.agent_intent() |> bump_state!(:blocked)

    assert {:cancel, :engines_pending} =
             perform_job(ReevaluateIntent, %{
               "intent_id" => intent.id,
               "reason" => "trust_changed"
             })
  end

  test "cancels with {:wrong_state, state} for an :executing intent" do
    intent = Fixtures.agent_intent() |> bump_state!(:executing)

    assert {:cancel, {:wrong_state, :executing}} =
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
end
