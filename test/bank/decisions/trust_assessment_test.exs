defmodule Bank.Decisions.TrustAssessmentTest do
  use Bank.DataCase, async: true

  alias Bank.Decisions.TrustAssessment
  alias Bank.Fixtures

  describe "current invariant (partial unique index)" do
    test "allows one current claim per intent" do
      intent = Fixtures.agent_intent()
      claim = Fixtures.trust_assessment(intent: intent, current: true)
      assert claim.current
    end

    test "rejects a second current claim for the same intent" do
      intent = Fixtures.agent_intent()
      _first = Fixtures.trust_assessment(intent: intent, current: true)

      {:error, changeset} =
        %TrustAssessment{}
        |> TrustAssessment.changeset(%{
          intent_id: intent.id,
          derived_trust: :sensitive,
          confidence: :medium,
          generated_at: DateTime.utc_now(),
          generated_by: :runtime,
          current: true
        })
        |> Repo.insert()

      refute changeset.valid?

      assert errors_on(changeset)[:intent_id] == [
               "another current claim already exists for this intent"
             ]
    end

    test "a non-current claim can coexist with a current one" do
      intent = Fixtures.agent_intent()
      _current = Fixtures.trust_assessment(intent: intent, current: true)
      historical = Fixtures.trust_assessment(intent: intent, current: false)
      assert historical.id
    end
  end

  describe "supersession" do
    test "supersede/2 carries intent_id forward" do
      intent = Fixtures.agent_intent()
      prior = Fixtures.trust_assessment(intent: intent, current: false)

      {:ok, successor} =
        prior
        |> TrustAssessment.supersede(%{
          derived_trust: :trusted,
          confidence: :high,
          generated_at: DateTime.utc_now(),
          generated_by: :runtime
        })
        |> Repo.insert()

      assert successor.intent_id == intent.id
      assert successor.supersedes_id == prior.id
    end

    test "mark_not_current/1 flips the flag without touching other fields" do
      intent = Fixtures.agent_intent()
      claim = Fixtures.trust_assessment(intent: intent, current: true)

      {:ok, flipped} =
        claim
        |> TrustAssessment.mark_not_current()
        |> Repo.update()

      refute flipped.current
      assert flipped.derived_trust == claim.derived_trust
    end
  end
end
