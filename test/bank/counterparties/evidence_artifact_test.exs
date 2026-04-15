defmodule Bank.Counterparties.EvidenceArtifactTest do
  use Bank.DataCase, async: true

  alias Bank.Counterparties.EvidenceArtifact
  alias Bank.Fixtures

  describe "changeset/2" do
    test "requires polymorphic subject and capture fields" do
      changeset = EvidenceArtifact.changeset(%EvidenceArtifact{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)

      for field <- [
            :subject_type,
            :subject_id,
            :kind,
            :content_uri,
            :payload_hash,
            :captured_at,
            :captured_by
          ] do
        assert errors[field], "expected error on #{field}"
      end
    end

    test "rejects subject_type outside the allowed set at the changeset layer" do
      changeset =
        EvidenceArtifact.changeset(%EvidenceArtifact{}, %{
          subject_type: "random_thing",
          subject_id: Ecto.UUID.generate(),
          kind: :user_note,
          content_uri: "mem://note",
          payload_hash: "deadbeef",
          captured_at: DateTime.utc_now(),
          captured_by: :user
        })

      refute changeset.valid?
      assert errors_on(changeset).subject_type != []
    end

    test "rejects an unknown evidence kind" do
      cp = Fixtures.counterparty()

      changeset =
        EvidenceArtifact.changeset(%EvidenceArtifact{}, %{
          subject_type: "counterparty",
          subject_id: cp.id,
          kind: :whispered_rumor,
          content_uri: "mem://note",
          payload_hash: "deadbeef",
          captured_at: DateTime.utc_now(),
          captured_by: :user
        })

      refute changeset.valid?
    end
  end

  describe "supersede/2" do
    test "builds a successor carrying the polymorphic subject forward" do
      cp = Fixtures.counterparty()
      prior = Fixtures.evidence_artifact(subject: cp)

      changeset =
        EvidenceArtifact.supersede(prior, %{
          kind: :external_lookup,
          content_uri: "mem://note-2",
          payload_hash: "cafebabe",
          captured_at: DateTime.utc_now(),
          captured_by: :runtime
        })

      {:ok, successor} = Repo.insert(changeset)

      assert successor.subject_type == prior.subject_type
      assert successor.subject_id == prior.subject_id
      assert successor.supersedes_id == prior.id
      # Attempting to re-parent under a different subject is ignored —
      # supersede/2 clobbers any subject in attrs with the prior's.
    end

    test "ignores attempts to change subject via attrs" do
      cp = Fixtures.counterparty()
      prior = Fixtures.evidence_artifact(subject: cp)
      other = Fixtures.counterparty()

      changeset =
        EvidenceArtifact.supersede(prior, %{
          subject_type: "counterparty",
          subject_id: other.id,
          kind: :user_note,
          content_uri: "mem://note-3",
          payload_hash: "c0ffee",
          captured_at: DateTime.utc_now(),
          captured_by: :runtime
        })

      {:ok, successor} = Repo.insert(changeset)
      assert successor.subject_id == prior.subject_id
    end
  end
end
