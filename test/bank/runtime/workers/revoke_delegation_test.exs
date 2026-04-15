defmodule Bank.Runtime.Workers.RevokeDelegationTest do
  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Runtime.PubSub
  alias Bank.Runtime.Workers.RevokeDelegation

  test "broadcasts on security:events and writes a runtime audit event before cancelling" do
    :ok = PubSub.subscribe(PubSub.security_events())
    :ok = PubSub.subscribe(PubSub.audit_stream())

    assert {:cancel, :adapter_pending} =
             perform_job(RevokeDelegation, %{
               "smart_account_id" => "sa-xyz",
               "reason" => "operator_requested"
             })

    # security event broadcast
    assert_receive %{
      topic: :security_events,
      event: :delegation_revoke_requested,
      payload: %{smart_account_id: "sa-xyz", reason: "operator_requested"}
    }

    # audit stream broadcast
    assert_receive %{
      topic: :audit_stream,
      event: :appended,
      payload: %{event_type: "security.revoke_requested", subject_type: "smart_account"}
    }

    # and the row is actually persisted
    assert [%AuditEvent{subject_id: "sa-xyz", correlation_id: nil}] =
             Repo.all(AuditEvent)
  end

  test "cancels with :malformed_args when smart_account_id is missing" do
    assert {:cancel, :malformed_args} =
             perform_job(RevokeDelegation, %{"reason" => "x"})
  end
end
