defmodule Bank.Audit.AuditEventTest do
  use Bank.DataCase, async: true

  alias Bank.Audit.AuditEvent

  describe "changeset/2" do
    test "requires actor, event_type, subject_type, subject_id, payload_hash" do
      changeset = AuditEvent.changeset(%AuditEvent{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)

      for field <- [:actor, :event_type, :subject_type, :subject_id, :payload_hash] do
        assert errors[field], "expected error on #{field}"
      end
    end

    test "defaults ts to now when not provided" do
      changeset =
        AuditEvent.changeset(%AuditEvent{}, %{
          actor: :runtime,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: Ecto.UUID.generate(),
          payload_hash: "c0ffee"
        })

      assert %DateTime{} = get_field(changeset, :ts)
      assert changeset.valid?
    end

    test "preserves an explicit ts" do
      fixed = DateTime.from_naive!(~N[2026-04-15 12:00:00.000000], "Etc/UTC")

      changeset =
        AuditEvent.changeset(%AuditEvent{}, %{
          ts: fixed,
          actor: :user,
          event_type: "approval.granted",
          subject_type: "decision_envelope",
          subject_id: Ecto.UUID.generate(),
          payload_hash: "f00d"
        })

      assert get_field(changeset, :ts) == fixed
    end

    test "rejects unknown actor enum value" do
      changeset =
        AuditEvent.changeset(%AuditEvent{}, %{
          actor: :cosmic_rays,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: Ecto.UUID.generate(),
          payload_hash: "beef"
        })

      refute changeset.valid?
    end
  end

  describe "insert-only posture" do
    test "the schema has no updated_at field (insert-only table)" do
      fields = AuditEvent.__schema__(:fields)
      refute :updated_at in fields
      assert :inserted_at in fields
    end
  end
end
