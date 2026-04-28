defmodule Bank.Runtime.Workers.GrantDelegationTest do
  @moduledoc """
  Tests for the GrantDelegation worker (#58 grant flow).

  The worker forwards a browser-initiated connect request to the
  adapter's `POST /dispatch/grant_delegation`. The adapter does
  the on-chain install and posts the `granted` callback back; this
  worker only owns the dispatch leg. Tests pin:

    - happy path emits audit + dispatches with the right payload
    - transient adapter failures bubble through Oban retry
    - deterministic adapter rejections cancel
    - malformed args cancel without dispatching
  """

  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Runtime.Workers.GrantDelegation

  @smart_account_id "sa_grant_test"
  @account "0xabc000000000000000000000000000000000dead"
  @chain_id 84_532

  defp args(extra \\ %{}) do
    Map.merge(
      %{
        "smart_account_id" => @smart_account_id,
        "chain_id" => @chain_id,
        "account" => @account
      },
      extra
    )
  end

  defp stub_adapter(status, body) do
    Req.Test.stub(Bank.AdapterClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  describe "happy path" do
    test "emits audit, dispatches grant, returns :ok" do
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
               perform_job(
                 GrantDelegation,
                 args(%{
                   "delegation_payload" => %{"sig" => "0xdead"},
                   "scope" => %{"asset" => "USDC"}
                 })
               )

      assert_received {:dispatch_body, body}
      assert body["action"] == "grant_delegation"
      assert body["smart_account_id"] == @smart_account_id
      assert body["chain_id"] == @chain_id
      assert body["account"] == @account
      assert body["scope"] == %{"asset" => "USDC"}
      assert body["delegation_payload"] == %{"sig" => "0xdead"}
      assert body["correlation_id"] == nil
      assert is_binary(body["emitted_at"])
      # The dispatch echoes the contract version pin used by every
      # other Phoenix → adapter call. Bumping it would be a wire
      # break; pinning here forces deliberate review.
      assert body["contract_version"] == 1

      assert [%AuditEvent{event_type: "security.grant_requested", subject_id: @smart_account_id}] =
               Repo.all(AuditEvent)
    end
  end

  describe "transient adapter failures" do
    test "transport error returns {:error, :adapter_unavailable}" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :adapter_unavailable} = perform_job(GrantDelegation, args())

      # Audit row still landed BEFORE the dispatch; operator sees
      # the request even on retry storms.
      assert [%AuditEvent{}] = Repo.all(AuditEvent)
    end

    test "5xx returns {:error, {:adapter_error, status}} so Oban retries" do
      stub_adapter(503, %{"error" => "upstream unavailable"})
      assert {:error, {:adapter_error, 503}} = perform_job(GrantDelegation, args())
    end
  end

  describe "deterministic adapter failures" do
    test "4xx cancels with {:adapter_rejected, status}" do
      stub_adapter(422, %{"error" => %{"code" => "unsupported_chain"}})

      assert {:cancel, {:adapter_rejected, 422}} = perform_job(GrantDelegation, args())
    end

    test "2xx with unexpected body cancels with :invalid_response" do
      stub_adapter(202, %{"something" => "else"})

      assert {:cancel, :invalid_response} = perform_job(GrantDelegation, args())
    end
  end

  describe "malformed args" do
    test "missing smart_account_id cancels without dispatching" do
      # Stub deliberately raises if called — proves no dispatch happened.
      Req.Test.stub(Bank.AdapterClient, fn _conn ->
        flunk("adapter should not be called on malformed args")
      end)

      assert {:cancel, :malformed_args} =
               perform_job(GrantDelegation, %{
                 "chain_id" => @chain_id,
                 "account" => @account
               })
    end

    test "non-integer chain_id cancels" do
      Req.Test.stub(Bank.AdapterClient, fn _conn ->
        flunk("adapter should not be called on malformed args")
      end)

      assert {:cancel, :malformed_args} =
               perform_job(GrantDelegation, %{
                 "smart_account_id" => @smart_account_id,
                 "chain_id" => "84532",
                 "account" => @account
               })
    end
  end
end
