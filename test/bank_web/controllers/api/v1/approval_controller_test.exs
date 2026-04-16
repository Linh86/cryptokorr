defmodule BankWeb.API.V1.ApprovalControllerTest do
  use BankWeb.ConnCase, async: false

  import Bank.Fixtures

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Repo
  alias Bank.Security.PauseState

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

      successor =
        Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true)

      assert successor.id != envelope.id
      assert successor.outcome == :auto_exec
      assert successor.supersedes_id == envelope.id
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
