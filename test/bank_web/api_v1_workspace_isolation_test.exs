defmodule BankWeb.APIV1WorkspaceIsolationTest do
  @moduledoc """
  Cross-workspace isolation coverage for `/v1` controllers (#159b).

  Each test constructs two workspaces (A, B), seeds a resource in
  B, authenticates with an admin key for A, then attempts to
  read or mutate the B resource by id. The expected response is
  `404 not_found` — same shape as a genuinely-unknown id so a
  caller in A cannot probe for the existence of resources in B
  via status code or error code.

  Pairs with the per-route role-gate tests in
  `BankWeb.APIV1AuthRBACTest` (#218b).
  """

  use BankWeb.ConnCase, async: false

  import Bank.Fixtures

  alias Bank.APIKeys
  alias Bank.Workspaces

  defp setup_two_workspaces() do
    # Workspace A — caller's authenticated workspace.
    suffix_a = System.unique_integer([:positive])
    {:ok, ws_a} = Workspaces.create_workspace(%{slug: "a-#{suffix_a}", name: "WS A #{suffix_a}"})

    {:ok, user_a} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "ws-iso-a-#{suffix_a}",
        email: "ws-iso-a-#{suffix_a}@example.com",
        name: "WS A user"
      })

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user_a.id, workspace_id: ws_a.id, role: :admin})

    {:ok, _key, raw_a} = APIKeys.create_key(ws_a, user_a, :admin, "key-a")

    # Workspace B — has the resource the test will try (and fail) to reach.
    suffix_b = System.unique_integer([:positive])
    {:ok, ws_b} = Workspaces.create_workspace(%{slug: "b-#{suffix_b}", name: "WS B #{suffix_b}"})

    {:ok, user_b} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "ws-iso-b-#{suffix_b}",
        email: "ws-iso-b-#{suffix_b}@example.com",
        name: "WS B user"
      })

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user_b.id, workspace_id: ws_b.id, role: :admin})

    %{
      ws_a: ws_a,
      user_a: user_a,
      raw_a: raw_a,
      ws_b: ws_b,
      user_b: user_b
    }
  end

  defp conn_for(raw_secret, ws_id) do
    Process.put(:bank_test_workspace_id, ws_id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> raw_secret)
    |> put_req_header("content-type", "application/json")
  end

  # --- Intent show / replay / simulate / cancel ----------------------------

  describe "GET /v1/intents/:id (cross-workspace)" do
    test "returns 404 for an intent in another workspace" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()

      Process.put(:bank_test_workspace_id, ws_b.id)
      intent_b = agent_intent(workspace_id: ws_b.id)

      conn = conn_for(raw_a, ws_a.id)
      conn = get(conn, ~p"/v1/intents/#{intent_b.id}")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /v1/intents/:id/replay (cross-workspace)" do
    test "returns 404 for an intent in another workspace" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()
      Process.put(:bank_test_workspace_id, ws_b.id)
      intent_b = agent_intent(workspace_id: ws_b.id)

      conn = conn_for(raw_a, ws_a.id)
      conn = get(conn, ~p"/v1/intents/#{intent_b.id}/replay")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "POST /v1/intents/:id/simulate (cross-workspace)" do
    test "returns 404 for an intent in another workspace" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()
      Process.put(:bank_test_workspace_id, ws_b.id)
      intent_b = agent_intent(workspace_id: ws_b.id)

      conn = conn_for(raw_a, ws_a.id)

      conn =
        post(conn, ~p"/v1/intents/#{intent_b.id}/simulate", %{"reason" => "operator_inspection"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "POST /v1/intents/:id/cancel (cross-workspace)" do
    test "returns 404 for an intent in another workspace" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()
      Process.put(:bank_test_workspace_id, ws_b.id)
      intent_b = agent_intent(workspace_id: ws_b.id)

      conn = conn_for(raw_a, ws_a.id)
      conn = post(conn, ~p"/v1/intents/#{intent_b.id}/cancel", %{"reason" => "operator_test"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  # --- Decision show / execute --------------------------------------------

  describe "GET /v1/decisions/:id (cross-workspace)" do
    test "returns 404 for a decision whose intent is in another workspace" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()
      Process.put(:bank_test_workspace_id, ws_b.id)
      intent_b = agent_intent(workspace_id: ws_b.id)
      env_b = decision_envelope(intent: intent_b, current: false)

      conn = conn_for(raw_a, ws_a.id)
      conn = get(conn, ~p"/v1/decisions/#{env_b.id}")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "POST /v1/decisions/:id/execute (cross-workspace)" do
    test "returns 404 for a decision whose intent is in another workspace" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()
      Process.put(:bank_test_workspace_id, ws_b.id)
      intent_b = agent_intent(workspace_id: ws_b.id)
      env_b = decision_envelope(intent: intent_b, current: false)

      conn = conn_for(raw_a, ws_a.id)

      conn =
        post(conn, ~p"/v1/decisions/#{env_b.id}/execute", %{"smart_account_id" => "sa_iso"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  # --- Counterparty CRUD ---------------------------------------------------

  describe "PATCH /v1/counterparties/:id (cross-workspace)" do
    test "returns 404 for a counterparty in another workspace" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()
      Process.put(:bank_test_workspace_id, ws_b.id)
      cp_b = counterparty(workspace_id: ws_b.id, name: "B Corp")

      conn = conn_for(raw_a, ws_a.id)
      conn = patch(conn, ~p"/v1/counterparties/#{cp_b.id}", %{"name" => "Renamed"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

      # And the row in B remains unchanged.
      assert Bank.Repo.get!(Bank.Counterparties.Counterparty, cp_b.id).name == "B Corp"
    end
  end

  describe "POST /v1/counterparties/:id/addresses (cross-workspace)" do
    test "returns 404 for a counterparty in another workspace" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()
      Process.put(:bank_test_workspace_id, ws_b.id)
      cp_b = counterparty(workspace_id: ws_b.id)

      conn = conn_for(raw_a, ws_a.id)

      conn =
        post(conn, ~p"/v1/counterparties/#{cp_b.id}/addresses", %{
          "chain" => "base",
          "address" => "0x" <> String.duplicate("ab", 20)
        })

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  # --- Address label update ------------------------------------------------

  describe "PATCH /v1/address_labels/:id (cross-workspace)" do
    test "returns 404 for a label whose counterparty is in another workspace" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()
      Process.put(:bank_test_workspace_id, ws_b.id)
      cp_b = counterparty(workspace_id: ws_b.id)
      label_b = address_label(counterparty: cp_b)

      conn = conn_for(raw_a, ws_a.id)
      conn = patch(conn, ~p"/v1/address_labels/#{label_b.id}", %{"alias" => "renamed"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  # --- Policy revise / archive --------------------------------------------

  describe "POST /v1/policies/:id/archive (cross-workspace)" do
    test "returns 404 for a policy rule in another workspace" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()
      Process.put(:bank_test_workspace_id, ws_b.id)
      rule_b = policy_rule(workspace_id: ws_b.id)

      conn = conn_for(raw_a, ws_a.id)
      conn = post(conn, ~p"/v1/policies/#{rule_b.id}/archive", %{})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

      reloaded = Bank.Repo.get!(Bank.Policies.PolicyRule, rule_b.id)
      assert reloaded.state == :active, "cross-workspace probe must NOT archive the row"
    end
  end

  # --- Audit listing -------------------------------------------------------

  describe "GET /v1/audit (cross-workspace stamping)" do
    test "stamps workspace_id from current_scope; query-string workspace_id is ignored" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()

      # Intent + audit event in workspace B.
      Process.put(:bank_test_workspace_id, ws_b.id)
      intent_b = agent_intent(workspace_id: ws_b.id)

      {:ok, _event_b} =
        Bank.Audit.append_event(%{
          actor: :runtime,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: intent_b.id,
          correlation_id: intent_b.id,
          workspace_id: ws_b.id
        })

      conn = conn_for(raw_a, ws_a.id)

      # Even when the caller supplies `?workspace_id=<B>`, the
      # controller MUST stamp from current_scope (A) and ignore
      # the query value (#159b).
      conn = get(conn, ~p"/v1/audit?intent_id=#{intent_b.id}&workspace_id=#{ws_b.id}")

      assert %{"data" => events} = json_response(conn, 200)

      refute Enum.any?(events, &(&1["correlation_id"] == intent_b.id)),
             "audit listing for workspace A must NOT include workspace B events"
    end
  end

  # --- Intent submit body forge -------------------------------------------

  describe "POST /v1/intents body workspace_id forge attempt" do
    test "ignores `workspace_id` in request body — uses current_scope" do
      %{ws_a: ws_a, raw_a: raw_a, ws_b: ws_b} = setup_two_workspaces()

      conn = conn_for(raw_a, ws_a.id)

      body = %{
        "agent_id" => "agent-iso-#{System.unique_integer([:positive])}",
        "source" => "agent",
        "idempotency_key" => "iso-#{System.unique_integer([:positive])}",
        "kind" => "transfer",
        "asset" => "USDC",
        "chain" => "base",
        "amount" => "1.00",
        "target" => %{"raw_address" => "0x" <> String.duplicate("ab", 20)},
        # Hostile field — must be ignored in favor of current_scope.
        "workspace_id" => ws_b.id
      }

      conn = post(conn, ~p"/v1/intents", body)
      response = json_response(conn, 202)

      created_id = response["data"]["id"] || response["intent"]["id"] || response["id"]

      if created_id do
        intent = Bank.Repo.get!(Bank.Intents.AgentIntent, created_id)

        assert intent.workspace_id == ws_a.id,
               "request body workspace_id MUST NOT be honored — current_scope wins"

        refute intent.workspace_id == ws_b.id
      end
    end
  end

  # --- Public health stays public + Internal adapter callback unchanged ---

  describe "non-/v1-app routes are unaffected by #159b" do
    test "GET /v1/health remains public", %{conn: conn} do
      assert %{"status" => _} = json_response(get(conn, "/v1/health"), 200)
    end

    test "GET /health remains public", %{conn: conn} do
      assert %{"status" => "ok"} = json_response(get(conn, "/health"), 200)
    end
  end
end
