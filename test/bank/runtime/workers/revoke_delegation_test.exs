defmodule Bank.Runtime.Workers.RevokeDelegationTest do
  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Runtime.PubSub
  alias Bank.Runtime.Workers.RevokeDelegation

  defp stub_adapter(status, body) do
    Req.Test.stub(Bank.AdapterClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  describe "happy path" do
    test "dispatches to adapter, emits broadcast + audit, and returns :ok" do
      :ok = PubSub.subscribe(PubSub.security_events())
      :ok = PubSub.subscribe(PubSub.audit_stream())

      stub_adapter(202, %{"accepted" => true, "smart_account_id" => "sa-xyz"})

      assert :ok =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => "sa-xyz",
                 "reason" => "operator_requested"
               })

      assert_receive %{
        topic: :security_events,
        event: :delegation_revoke_requested,
        payload: %{smart_account_id: "sa-xyz", reason: "operator_requested"}
      }

      assert_receive %{
        topic: :audit_stream,
        event: :appended,
        payload: %{event_type: "security.revoke_requested", subject_type: "smart_account"}
      }

      assert [%AuditEvent{subject_id: "sa-xyz", correlation_id: nil}] =
               Repo.all(AuditEvent)
    end
  end

  describe "transient adapter failures" do
    test "transport error returns {:error, :adapter_unavailable}" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :adapter_unavailable} =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => "sa-xyz",
                 "reason" => "operator_requested"
               })

      # Audit + broadcast still happened before dispatch; the retry
      # will re-emit on each attempt, which is acceptable (ops sees
      # the request.)
      assert [%AuditEvent{}] = Repo.all(AuditEvent)
    end

    test "5xx returns {:error, {:adapter_error, status}}" do
      stub_adapter(503, %{"error" => "upstream unavailable"})

      assert {:error, {:adapter_error, 503}} =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => "sa-xyz",
                 "reason" => "operator_requested"
               })
    end
  end

  describe "deterministic adapter failures" do
    test "4xx cancels with {:adapter_rejected, status}" do
      stub_adapter(422, %{"error" => %{"code" => "no_such_delegation"}})

      assert {:cancel, {:adapter_rejected, 422}} =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => "sa-xyz",
                 "reason" => "operator_requested"
               })
    end

    test "2xx with unexpected body cancels with :invalid_response" do
      stub_adapter(202, %{"something" => "else"})

      assert {:cancel, :invalid_response} =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => "sa-xyz",
                 "reason" => "operator_requested"
               })
    end
  end

  test "cancels with :malformed_args when smart_account_id is missing" do
    assert {:cancel, :malformed_args} =
             perform_job(RevokeDelegation, %{"reason" => "x"})
  end
end
