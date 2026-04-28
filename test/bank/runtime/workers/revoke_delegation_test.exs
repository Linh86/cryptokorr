defmodule Bank.Runtime.Workers.RevokeDelegationTest do
  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Delegations
  alias Bank.Runtime.PubSub
  alias Bank.Runtime.Workers.RevokeDelegation

  @smart_account_id "sa-xyz"
  @delegation_id "del_primary"

  defp stub_adapter(status, body) do
    Req.Test.stub(Bank.AdapterClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  # Happy/failure tests all need a delegation row for the worker to
  # read `delegation_id` off before dispatching. Tests that exercise
  # the missing-row branch set this up themselves.
  defp grant_delegation!(opts \\ []) do
    sa = Keyword.get(opts, :smart_account_id, @smart_account_id)
    did = Keyword.get(opts, :delegation_id, @delegation_id)
    {:ok, delegation} = Delegations.grant(sa, did)
    delegation
  end

  describe "happy path" do
    test "dispatches to adapter, emits broadcast + audit, and returns :ok" do
      :ok = PubSub.subscribe(PubSub.security_events())
      :ok = PubSub.subscribe(PubSub.audit_stream())
      grant_delegation!()

      test_pid = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "smart_account_id" => @smart_account_id})
        )
      end)

      assert :ok =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => @smart_account_id,
                 "reason" => "operator_requested"
               })

      assert_received {:dispatch_body, dispatch_body}
      assert dispatch_body["smart_account_id"] == @smart_account_id
      assert dispatch_body["delegation_id"] == @delegation_id
      assert dispatch_body["reason"] == "operator_requested"
      assert dispatch_body["action"] == "revoke_delegation"

      assert_receive %{
        topic: :security_events,
        event: :delegation_revoke_requested,
        payload: %{smart_account_id: @smart_account_id, reason: "operator_requested"}
      }

      assert_receive %{
        topic: :audit_stream,
        event: :appended,
        payload: %{event_type: "security.revoke_requested", subject_type: "smart_account"}
      }

      assert [%AuditEvent{subject_id: @smart_account_id, correlation_id: nil}] =
               Repo.all(AuditEvent)
    end

    test "threads any opaque delegation_id end-to-end" do
      # `delegation_id` is opaque on the wire — Phoenix and the
      # adapter must agree on its encoding eventually (4-byte
      # ZeroDev permissionId, 21-byte Kernel validationId, or a
      # serialized plugin blob — see
      # docs/zerodev-permissions-integration.md), but the dispatch
      # path itself does not parse it. This test pins that any
      # non-empty string flows through unchanged so the encoding
      # decision can land later without changing the dispatch
      # contract again.
      opaque_id = "del-zerodev-pending-" <> Ecto.UUID.generate()

      grant_delegation!(delegation_id: opaque_id)

      test_pid = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "smart_account_id" => @smart_account_id})
        )
      end)

      assert :ok =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => @smart_account_id,
                 "reason" => "operator_requested"
               })

      assert_received {:dispatch_body, %{"delegation_id" => ^opaque_id}}
    end
  end

  describe "transient adapter failures" do
    test "transport error returns {:error, :adapter_unavailable}" do
      grant_delegation!()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :adapter_unavailable} =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => @smart_account_id,
                 "reason" => "operator_requested"
               })

      # Audit + broadcast still happened before dispatch; the retry
      # will re-emit on each attempt, which is acceptable (ops sees
      # the request.)
      assert [%AuditEvent{}] = Repo.all(AuditEvent)
    end

    test "5xx returns {:error, {:adapter_error, status}}" do
      grant_delegation!()
      stub_adapter(503, %{"error" => "upstream unavailable"})

      assert {:error, {:adapter_error, 503}} =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => @smart_account_id,
                 "reason" => "operator_requested"
               })
    end
  end

  describe "deterministic adapter failures" do
    test "4xx cancels with {:adapter_rejected, status}" do
      grant_delegation!()
      stub_adapter(422, %{"error" => %{"code" => "no_such_delegation"}})

      assert {:cancel, {:adapter_rejected, 422}} =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => @smart_account_id,
                 "reason" => "operator_requested"
               })
    end

    test "2xx with unexpected body cancels with :invalid_response" do
      grant_delegation!()
      stub_adapter(202, %{"something" => "else"})

      assert {:cancel, :invalid_response} =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => @smart_account_id,
                 "reason" => "operator_requested"
               })
    end
  end

  describe "missing delegation row" do
    test "cancels with :no_such_delegation and never calls the adapter" do
      # Deliberately refuse to stub the adapter: any attempt to dispatch
      # would raise because Req.Test is wired up in test_helper but has
      # no stub registered.
      assert {:cancel, :no_such_delegation} =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => "sa-no-grant",
                 "reason" => "operator_requested"
               })

      # The pre-dispatch audit + security broadcast still fire: the
      # operator's intent to revoke is recorded even though the adapter
      # never gets called.
      assert [%AuditEvent{subject_id: "sa-no-grant", event_type: "security.revoke_requested"}] =
               Repo.all(AuditEvent)
    end

    test "cancels with :no_such_delegation when the delegation is already terminal" do
      grant_delegation!()

      # Simulate the revoke already landed: transition the row all the
      # way to :revoked so `Delegations.get/1` (which only returns
      # non-terminal rows) returns nil.
      {:ok, _} =
        Delegations.record_revoke_requested(@smart_account_id, %{last_reason: "prior attempt"})

      {:ok, _} =
        Delegations.record_revoked(@smart_account_id, %{last_reason: "prior success"})

      assert {:cancel, :no_such_delegation} =
               perform_job(RevokeDelegation, %{
                 "smart_account_id" => @smart_account_id,
                 "reason" => "operator_requested"
               })
    end
  end

  test "cancels with :malformed_args when smart_account_id is missing" do
    assert {:cancel, :malformed_args} =
             perform_job(RevokeDelegation, %{"reason" => "x"})
  end
end
