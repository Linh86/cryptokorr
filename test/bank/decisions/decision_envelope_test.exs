defmodule Bank.Decisions.DecisionEnvelopeTest do
  use Bank.DataCase, async: true

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Fixtures

  describe "approval_expires_at validation" do
    test "required when outcome == :approval_required" do
      intent = Fixtures.agent_intent()

      changeset =
        DecisionEnvelope.changeset(%DecisionEnvelope{}, %{
          intent_id: intent.id,
          outcome: :approval_required,
          risk_tier: :elevated,
          decided_at: DateTime.utc_now(),
          decided_by: :runtime
        })

      refute changeset.valid?
      assert errors_on(changeset).approval_expires_at != []
    end

    test "must be nil unless outcome == :approval_required" do
      intent = Fixtures.agent_intent()

      changeset =
        DecisionEnvelope.changeset(%DecisionEnvelope{}, %{
          intent_id: intent.id,
          outcome: :auto_exec,
          risk_tier: :low,
          decided_at: DateTime.utc_now(),
          decided_by: :runtime,
          approval_expires_at: DateTime.utc_now()
        })

      refute changeset.valid?
      assert errors_on(changeset).approval_expires_at != []
    end

    test "accepts a paired approval outcome and expiry" do
      intent = Fixtures.agent_intent()

      changeset =
        DecisionEnvelope.changeset(%DecisionEnvelope{}, %{
          intent_id: intent.id,
          outcome: :approval_required,
          risk_tier: :elevated,
          decided_at: DateTime.utc_now(),
          decided_by: :runtime,
          approval_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert changeset.valid?
    end
  end

  describe "policy snapshot" do
    test "rejects a shape other than %{\"rule_ids\" => [..]}" do
      intent = Fixtures.agent_intent()

      changeset =
        DecisionEnvelope.changeset(%DecisionEnvelope{}, %{
          intent_id: intent.id,
          outcome: :auto_exec,
          risk_tier: :low,
          decided_at: DateTime.utc_now(),
          decided_by: :runtime,
          policy_snapshot_ref: %{"wrong_key" => []}
        })

      refute changeset.valid?
      assert errors_on(changeset).policy_snapshot_ref != []
    end

    test "snapshot_rule_ids/1 returns the captured rule uuids" do
      id_a = Ecto.UUID.generate()
      id_b = Ecto.UUID.generate()

      envelope = %DecisionEnvelope{
        policy_snapshot_ref: %{"rule_ids" => [id_a, id_b]}
      }

      assert DecisionEnvelope.snapshot_rule_ids(envelope) == [id_a, id_b]
    end

    test "snapshot_rule_ids/1 is safe on missing data" do
      assert DecisionEnvelope.snapshot_rule_ids(%DecisionEnvelope{policy_snapshot_ref: nil}) ==
               []
    end
  end

  describe "current invariant" do
    test "one current envelope per intent" do
      intent = Fixtures.agent_intent()
      _first = Fixtures.decision_envelope(intent: intent, current: true)

      {:error, changeset} =
        %DecisionEnvelope{}
        |> DecisionEnvelope.changeset(%{
          intent_id: intent.id,
          outcome: :hold,
          risk_tier: :moderate,
          decided_at: DateTime.utc_now(),
          decided_by: :runtime,
          current: true
        })
        |> Repo.insert()

      refute changeset.valid?

      assert errors_on(changeset)[:intent_id] == [
               "another current decision already exists for this intent"
             ]
    end
  end
end
