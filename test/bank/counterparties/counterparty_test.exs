defmodule Bank.Counterparties.CounterpartyTest do
  use Bank.DataCase, async: true

  alias Bank.Counterparties.Counterparty
  alias Bank.Fixtures

  describe "changeset/2" do
    test "requires name and created_by" do
      changeset = Counterparty.changeset(%Counterparty{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.created_by
    end

    test "accepts a minimal valid payload" do
      changeset = Counterparty.changeset(%Counterparty{}, %{name: "Acme", created_by: :user})
      assert changeset.valid?
    end

    test "rejects names longer than 255 chars" do
      long = String.duplicate("a", 256)

      changeset =
        Counterparty.changeset(%Counterparty{}, %{name: long, created_by: :user})

      refute changeset.valid?
      assert errors_on(changeset).name != []
    end

    test "rejects unknown trust levels and actors" do
      changeset =
        Counterparty.changeset(%Counterparty{}, %{
          name: "Acme",
          created_by: :god,
          current_trust_level: :platinum
        })

      refute changeset.valid?
      assert errors_on(changeset).created_by != []
      assert errors_on(changeset).current_trust_level != []
    end
  end

  describe "associations" do
    test "has many address labels, evidence artifacts, trust assertions" do
      cp = Fixtures.counterparty()
      label = Fixtures.address_label(counterparty: cp)
      evidence = Fixtures.evidence_artifact(subject: cp)
      assertion = Fixtures.trust_assertion(subject: cp)

      loaded = Repo.preload(cp, [:address_labels, :evidence_artifacts, :trust_assertions])

      assert Enum.map(loaded.address_labels, & &1.id) == [label.id]
      assert Enum.map(loaded.evidence_artifacts, & &1.id) == [evidence.id]
      assert Enum.map(loaded.trust_assertions, & &1.id) == [assertion.id]
    end

    test "evidence and trust associations filter on subject_type" do
      cp = Fixtures.counterparty()
      label = Fixtures.address_label(counterparty: cp)

      # Attach one of each kind of artifact/assertion to the label —
      # the counterparty's assoc should NOT include them.
      Fixtures.evidence_artifact(subject: label)
      Fixtures.trust_assertion(subject: label)

      loaded = Repo.preload(cp, [:evidence_artifacts, :trust_assertions])

      assert loaded.evidence_artifacts == []
      assert loaded.trust_assertions == []
    end
  end
end
