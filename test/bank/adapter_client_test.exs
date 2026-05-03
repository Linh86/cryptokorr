defmodule Bank.AdapterClientTest do
  use Bank.DataCase, async: true

  alias Bank.AdapterClient
  alias Bank.Fixtures

  # Build a plan whose target address label resolves cleanly, so error-
  # mapping tests exercise the HTTP branch rather than short-circuiting
  # in the target resolver.
  defp resolvable_plan do
    counterparty = Fixtures.counterparty()
    label = Fixtures.address_label(counterparty: counterparty, chain: "base")

    intent =
      Fixtures.agent_intent(
        counterparty: counterparty,
        target_address_label_id: label.id
      )

    decision = Fixtures.decision_envelope(intent: intent)
    Fixtures.execution_plan(decision: decision, intent_id: intent.id)
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "dispatch_transfer/2 — happy path" do
    test "shapes the contract payload from plan + intent and returns :ok on HTTP 202" do
      counterparty = Fixtures.counterparty()
      label = Fixtures.address_label(counterparty: counterparty, chain: "base")

      intent =
        Fixtures.agent_intent(
          counterparty: counterparty,
          target_address_label_id: label.id,
          amount: Decimal.new("50")
        )

      decision = Fixtures.decision_envelope(intent: intent)

      plan =
        Fixtures.execution_plan(
          decision: decision,
          intent_id: intent.id,
          chain: "base",
          asset: "USDC",
          smart_account_id: "sa_test",
          signing_requirements: %{
            "delegation_id" => "del_primary",
            "scope" => %{"asset" => "USDC"}
          }
        )

      test_pid = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        send(
          test_pid,
          {:dispatch, payload, conn.method, conn.request_path, conn.req_headers}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "execution_plan_id" => plan.id})
        )
      end)

      assert {:ok, result} = AdapterClient.dispatch_transfer(plan)
      assert result.accepted == true
      assert result.execution_plan_id == plan.id

      assert_received {:dispatch, payload, "POST", "/dispatch/transfer", headers}

      assert {"authorization", "Bearer test-adapter-dispatch-secret"} in headers

      assert payload["contract_version"] == 1
      assert payload["action"] == "transfer"
      assert payload["execution_plan_id"] == plan.id
      assert payload["intent_id"] == intent.id
      assert payload["smart_account_id"] == "sa_test"
      assert payload["chain"] == "base"
      assert payload["asset"] == "USDC"
      assert payload["amount"] == "50"
      assert payload["target"]["address"] == label.address
      assert payload["target"]["counterparty_id"] == label.counterparty_id
      assert payload["signing_requirements"]["delegation_id"] == "del_primary"
      assert payload["correlation_id"] == intent.id
      assert is_binary(payload["emitted_at"])
    end

    test "resolves a raw-address target when no counterparty is set" do
      raw_address = "0x" <> String.duplicate("ab", 20)

      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: raw_address
        )

      decision = Fixtures.decision_envelope(intent: intent)
      plan = Fixtures.execution_plan(decision: decision, intent_id: intent.id)

      test_pid = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:payload, Jason.decode!(body)})

        json_resp(conn, 202, %{"accepted" => true, "execution_plan_id" => plan.id})
      end)

      assert {:ok, _} = AdapterClient.dispatch_transfer(plan)
      assert_received {:payload, payload}
      assert payload["target"]["address"] == raw_address
      assert payload["target"]["counterparty_id"] == nil
    end
  end

  describe "dispatch_transfer/2 — error mapping" do
    test "HTTP 4xx maps to :adapter_rejected" do
      plan = resolvable_plan()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        json_resp(conn, 422, %{"error" => %{"code" => "unsupported_chain"}})
      end)

      assert {:error, {:adapter_rejected, 422, %{"error" => %{"code" => "unsupported_chain"}}}} =
               AdapterClient.dispatch_transfer(plan)
    end

    test "HTTP 5xx maps to :adapter_error" do
      plan = resolvable_plan()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Plug.Conn.resp(conn, 503, "upstream unavailable")
      end)

      assert {:error, {:adapter_error, 503, "upstream unavailable"}} =
               AdapterClient.dispatch_transfer(plan)
    end

    test "transport errors map to :adapter_unavailable" do
      plan = resolvable_plan()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :adapter_unavailable} = AdapterClient.dispatch_transfer(plan)
    end

    test "2xx with an unexpected body shape maps to :invalid_response" do
      plan = resolvable_plan()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        json_resp(conn, 200, %{"something" => "else"})
      end)

      assert {:error, :invalid_response} = AdapterClient.dispatch_transfer(plan)
    end

    test "counterparty without a matching label → {:target_not_resolvable, :no_label}" do
      # Counterparty exists but has no active label on the intent's chain.
      counterparty = Fixtures.counterparty()

      intent =
        Fixtures.agent_intent(
          counterparty: counterparty,
          chain: "base"
        )

      decision = Fixtures.decision_envelope(intent: intent)
      plan = Fixtures.execution_plan(decision: decision, intent_id: intent.id)

      # No HTTP stub — the client should never reach the network.
      assert {:error, {:target_not_resolvable, :no_label}} =
               AdapterClient.dispatch_transfer(plan)
    end
  end

  describe "dispatch_revoke_delegation/2 — payload shape" do
    test "threads smart_account_id, delegation_id, and reason into the adapter body" do
      test_pid = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        send(
          test_pid,
          {:dispatch, payload, conn.method, conn.request_path, conn.req_headers}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "smart_account_id" => "sa_test"})
        )
      end)

      assert {:ok, result} =
               AdapterClient.dispatch_revoke_delegation(%{
                 smart_account_id: "sa_test",
                 delegation_id: "del_primary",
                 reason: "operator_requested"
               })

      assert result.accepted == true
      assert result.smart_account_id == "sa_test"

      assert_received {:dispatch, payload, "POST", "/dispatch/revoke_delegation", headers}

      assert {"authorization", "Bearer test-adapter-dispatch-secret"} in headers

      assert payload["contract_version"] == 1
      assert payload["action"] == "revoke_delegation"
      assert payload["smart_account_id"] == "sa_test"
      assert payload["delegation_id"] == "del_primary"
      assert payload["reason"] == "operator_requested"
      assert payload["correlation_id"] == nil
      assert is_binary(payload["emitted_at"])
    end

    test "raises FunctionClauseError when delegation_id is missing" do
      # Required by contract — the adapter needs an id to carry into the
      # cryptographic disable body once #58 swaps the inner call. If
      # Phoenix forgets to thread it through, that's a programming
      # bug, not a retryable transport failure.
      assert_raise FunctionClauseError, fn ->
        AdapterClient.dispatch_revoke_delegation(%{
          smart_account_id: "sa_test",
          reason: "operator_requested"
        })
      end
    end

    test "omits :permission key when not provided (sentinel path is unchanged)" do
      # Backwards-compatibility guarantee: legacy delegations whose
      # rows have NULL permission_blob continue to dispatch without
      # any `permission` key, matching the v1 wire shape the
      # adapter's sentinel path expects.
      test_pid = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:payload, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "smart_account_id" => "sa_legacy"})
        )
      end)

      assert {:ok, _} =
               AdapterClient.dispatch_revoke_delegation(%{
                 smart_account_id: "sa_legacy",
                 delegation_id: "del_legacy",
                 reason: "operator_requested"
               })

      assert_received {:payload, payload}
      refute Map.has_key?(payload, "permission")
    end

    test "threads :permission block verbatim into the adapter body when present" do
      # When the worker includes a `:permission` block (because the row
      # is `cryptographically_revocable?/1`), the adapter receives the
      # full block under the `permission` key and the legacy fields
      # alongside it. The adapter consumes the block to build the
      # cryptographic uninstallValidation UserOp; the block fails
      # closed if the adapter cannot honor it (no operator key, blob
      # mismatch, etc.).
      test_pid = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:payload, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "smart_account_id" => "sa_crypto"})
        )
      end)

      perm_block = %{
        blob: "eyJzZXJpYWxpemVkUGVybWlzc2lvbkFjY291bnQiOiJ0ZXN0In0=",
        permission_id: "0xa1b2c3d4",
        validation_id: "0x02a1b2c3d400000000000000000000000000000000",
        kernel_version: "0.3.1",
        package_version: "5.6.3",
        session_signer_address: "0x" <> String.duplicate("11", 20)
      }

      assert {:ok, _} =
               AdapterClient.dispatch_revoke_delegation(%{
                 smart_account_id: "sa_crypto",
                 delegation_id: "0xa1b2c3d4",
                 reason: "operator_requested",
                 permission: perm_block
               })

      assert_received {:payload, payload}
      assert payload["permission"]["blob"] == perm_block.blob
      assert payload["permission"]["permission_id"] == perm_block.permission_id
      assert payload["permission"]["validation_id"] == perm_block.validation_id
      assert payload["permission"]["kernel_version"] == "0.3.1"
      assert payload["permission"]["package_version"] == "5.6.3"

      assert payload["permission"]["session_signer_address"] ==
               perm_block.session_signer_address
    end
  end

  describe "dispatch_grant_delegation/2 — payload shape (#58 grant flow)" do
    test "threads smart_account_id, chain_id, account, scope, and delegation_payload into the adapter body" do
      test_pid = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        send(test_pid, {:dispatch, payload, conn.method, conn.request_path, conn.req_headers})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "smart_account_id" => "sa_grant"})
        )
      end)

      assert {:ok, result} =
               AdapterClient.dispatch_grant_delegation(%{
                 smart_account_id: "sa_grant",
                 chain_id: 84_532,
                 account: "0xabc000000000000000000000000000000000dead",
                 scope: %{"asset" => "USDC"},
                 delegation_payload: %{"sig" => "0xdeadbeef"}
               })

      assert result.accepted == true
      assert result.smart_account_id == "sa_grant"

      assert_received {:dispatch, payload, "POST", "/dispatch/grant_delegation", headers}

      assert {"authorization", "Bearer test-adapter-dispatch-secret"} in headers

      assert payload["contract_version"] == 1
      assert payload["action"] == "grant_delegation"
      assert payload["smart_account_id"] == "sa_grant"
      assert payload["chain_id"] == 84_532
      assert payload["account"] == "0xabc000000000000000000000000000000000dead"
      assert payload["scope"] == %{"asset" => "USDC"}
      assert payload["delegation_payload"] == %{"sig" => "0xdeadbeef"}
      assert payload["correlation_id"] == nil
      assert is_binary(payload["emitted_at"])
    end

    test "raises FunctionClauseError when smart_account_id is missing" do
      assert_raise FunctionClauseError, fn ->
        AdapterClient.dispatch_grant_delegation(%{
          chain_id: 84_532,
          account: "0xabc"
        })
      end
    end

    test "raises FunctionClauseError when chain_id is not an integer" do
      assert_raise FunctionClauseError, fn ->
        AdapterClient.dispatch_grant_delegation(%{
          smart_account_id: "sa",
          chain_id: "84532",
          account: "0xabc"
        })
      end
    end

    test "maps adapter 4xx onto :adapter_rejected" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(422, Jason.encode!(%{"error" => "unsupported_chain"}))
      end)

      assert {:error, {:adapter_rejected, 422, _}} =
               AdapterClient.dispatch_grant_delegation(%{
                 smart_account_id: "sa",
                 chain_id: 1,
                 account: "0xabc"
               })
    end

    test "maps adapter 5xx onto :adapter_error" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"error" => "upstream"}))
      end)

      assert {:error, {:adapter_error, 503, _}} =
               AdapterClient.dispatch_grant_delegation(%{
                 smart_account_id: "sa",
                 chain_id: 84_532,
                 account: "0xabc"
               })
    end
  end

  # --- #255 structured telemetry + redaction --------------------------------

  describe "dispatch_transfer/2 — telemetry + redaction (#255)" do
    setup do
      handler_id = "test-adapter-dispatch-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:bank, :adapter, :dispatch],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "accepted dispatch emits :accepted telemetry with execution_plan_id correlation" do
      plan = resolvable_plan()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        json_resp(conn, 202, %{"accepted" => true, "execution_plan_id" => plan.id})
      end)

      assert {:ok, _} = AdapterClient.dispatch_transfer(plan)

      assert_receive {:telemetry, [:bank, :adapter, :dispatch], %{count: 1},
                      %{
                        path: "/dispatch/transfer",
                        outcome: :accepted,
                        status: 202,
                        execution_plan_id: plan_id
                      }}

      assert plan_id == plan.id
    end

    test "rejected dispatch emits :rejected telemetry with status" do
      plan = resolvable_plan()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        json_resp(conn, 422, %{"error" => %{"code" => "unsupported_chain"}})
      end)

      assert {:error, {:adapter_rejected, 422, _body}} = AdapterClient.dispatch_transfer(plan)

      assert_receive {:telemetry, [:bank, :adapter, :dispatch], %{count: 1},
                      %{path: "/dispatch/transfer", outcome: :rejected, status: 422}}
    end

    test "5xx dispatch emits :error telemetry with status" do
      plan = resolvable_plan()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Plug.Conn.resp(conn, 503, "upstream")
      end)

      assert {:error, {:adapter_error, 503, _}} = AdapterClient.dispatch_transfer(plan)

      assert_receive {:telemetry, [:bank, :adapter, :dispatch], %{count: 1},
                      %{path: "/dispatch/transfer", outcome: :error, status: 503}}
    end

    test "transport error emits :unavailable telemetry — no status, no raw reason" do
      plan = resolvable_plan()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :adapter_unavailable} = AdapterClient.dispatch_transfer(plan)

      assert_receive {:telemetry, [:bank, :adapter, :dispatch], %{count: 1},
                      %{path: "/dispatch/transfer", outcome: :unavailable} = meta}

      # No raw `:reason`, `:url`, or transport struct in metadata.
      refute Map.has_key?(meta, :reason)
      refute Map.has_key?(meta, :url)
      assert is_nil(meta[:status])
    end

    test "transport error log is sanitized — does not echo raw Req error or URL" do
      plan = resolvable_plan()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        # Force the URL on the underlying request to look credentialed
        # so a leaked `inspect/1` would surface it. We can't replace
        # the URL the client sends, but `transport_error` reasons are
        # raw atoms in this stub; the test asserts the controlled-shape
        # log entry, which never echoes URL/struct.
        Req.Test.transport_error(conn, :econnrefused)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :adapter_unavailable} = AdapterClient.dispatch_transfer(plan)
        end)

      assert log =~ "Bank.AdapterClient /dispatch/transfer unavailable"
      assert log =~ "category=econnrefused"

      # Substrings that an `inspect/1` of the Req error or request
      # could surface — none of them must reach the log.
      for needle <- [
            "Req.TransportError",
            "Req.Request",
            "Bearer",
            "Authorization",
            "https://",
            "http://",
            "secret@",
            "sk_",
            "private_key",
            "BEGIN ",
            "transport_options"
          ] do
        refute log =~ needle,
               "transport-error log must not leak #{needle}: #{inspect(log)}"
      end
    end

    test "unexpected 2xx body log is sanitized — only top-level shape, never values" do
      plan = resolvable_plan()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        json_resp(conn, 200, %{
          "secret" => "Bearer sk_live_4242",
          "Authorization" => "Bearer xxx",
          "url" => "https://[email protected]/healthz",
          "private_key" => "0xabc"
        })
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_response} = AdapterClient.dispatch_transfer(plan)
        end)

      assert log =~ "Bank.AdapterClient: unexpected 2xx body"
      # Shape descriptor is allowed: it carries only the (operator-known)
      # adapter contract key names, no values, no host names, no tokens.
      assert log =~ "shape=map(keys=["

      for needle <- [
            "Bearer",
            "sk_live",
            "sk_",
            "secret@",
            "https://",
            "private_key=0x",
            "0xabc",
            "leak"
          ] do
        refute log =~ needle,
               "invalid-response log must not leak #{needle}: #{inspect(log)}"
      end

      # Telemetry should also fire :invalid_response for this branch
      # so a dashboard alert can pick it up without parsing logs.
      assert_receive {:telemetry, [:bank, :adapter, :dispatch], %{count: 1},
                      %{path: "/dispatch/transfer", outcome: :invalid_response, status: 200}}
    end
  end
end
