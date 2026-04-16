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

      assert {"authorization", "Bearer test-adapter-secret"} in headers

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
end
