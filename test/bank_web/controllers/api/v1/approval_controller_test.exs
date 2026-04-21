defmodule BankWeb.API.V1.ApprovalControllerTest do
  use BankWeb.ConnCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Bank.Fixtures

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Repo
  alias Bank.Runtime.Workers.RunExecution
  alias Bank.Security
  alias Bank.Security.PauseState
  alias Bank.WalletScreening

  setup do
    PauseState.reset()
    :ok
  end

  describe "GET /v1/approvals" do
    test "returns pending approvals list", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      conn = get(conn, ~p"/v1/approvals")
      body = json_response(conn, 200)

      assert [%{"id" => id}] = body["decisions"]
      assert id == envelope.id
    end

    test "includes screening evidence for pending approvals", %{conn: conn} do
      target = "0xQueueScreeningEvidence001"

      intent =
        agent_intent(
          target_counterparty_id: nil,
          target_raw_address: target,
          chain: "ethereum"
        )

      {:ok, _record} =
        WalletScreening.upsert_record(%{
          chain: "ethereum",
          address: target,
          control_tier: :challenge,
          source: "scamsniffer",
          source_record_id: "queue-ss-001",
          category: "phishing",
          reason: "ScamSniffer: queue evidence"
        })

      _envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      conn = get(conn, ~p"/v1/approvals")
      body = json_response(conn, 200)

      assert [%{"screening_evidence" => evidence}] = body["decisions"]
      assert evidence["outcome"] == "challenge"
      assert evidence["winning_tier"] == "challenge"
      assert evidence["screened_address"] == target
      assert [%{"control_tier" => "challenge", "source" => "scamsniffer"}] = evidence["records"]
    end
  end

  describe "POST /v1/approvals/:id/approve" do
    test "approves and produces auto_exec successor", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{
          "actor_id" => "op-linh"
        })

      body = json_response(conn, 200)
      assert body["decision"]["outcome"] == "auto_exec"
      assert body["dispatch"] == "recorded"

      assert %{"endpoint" => endpoint, "message" => message} = body["next_step"]
      assert endpoint =~ "/v1/decisions/"
      assert endpoint =~ "/execute"
      assert message =~ "smart_account_id"

      successor =
        Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true)

      assert successor.id != envelope.id
      assert successor.outcome == :auto_exec
      assert successor.supersedes_id == envelope.id

      # Approval is now record-only — no plan, no enqueue. Operator
      # must follow up with POST /v1/decisions/{id}/execute.
      refute_enqueued(worker: RunExecution)
      assert is_nil(Bank.Decisions.active_plan_for(successor.id))
    end

    test "approve while paused still records (paused does not block decisions)", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, :paused} = Security.pause(:global)

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{
          "actor_id" => "op-paused"
        })

      body = json_response(conn, 200)
      assert body["decision"]["outcome"] == "auto_exec"
      assert body["dispatch"] == "recorded"

      refute_enqueued(worker: RunExecution)
    end

    test "reject response carries no_dispatch", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/reject", %{"actor_id" => "op"})

      body = json_response(conn, 200)
      assert body["dispatch"] == "no_dispatch"
      refute_enqueued(worker: RunExecution)
    end

    test "requires actor_id", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      conn = post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_request"
    end

    test "404 when decision does not exist", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/approvals/#{Ecto.UUID.generate()}/approve", %{"actor_id" => "op"})

      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "409 when decision is not approval_required", %{conn: conn} do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op"})

      body = json_response(conn, 409)
      assert body["error"]["code"] == "wrong_outcome"
    end
  end

  describe "POST /v1/approvals/:id/reject" do
    test "rejects and blocks the intent", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/reject", %{
          "actor_id" => "op-linh",
          "reason" => "duplicate"
        })

      body = json_response(conn, 200)
      assert body["decision"]["outcome"] == "block"

      successor =
        Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true)

      assert successor.outcome == :block
      updated_intent = Repo.get!(Bank.Intents.AgentIntent, intent.id)
      assert updated_intent.state == :blocked
    end
  end
end
