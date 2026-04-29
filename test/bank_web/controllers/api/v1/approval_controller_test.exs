defmodule BankWeb.API.V1.ApprovalControllerTest do
  use BankWeb.ConnCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Bank.Fixtures

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Delegations
  alias Bank.Repo
  alias Bank.Runtime.Workers.{ExpireApproval, RunExecution}
  alias Bank.Security
  alias Bank.Security.PauseState
  alias Bank.WalletScreening

  import Ecto.Query

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

  describe "POST /v1/approvals/:id/approve — dispatched path" do
    test "produces auto_exec successor + ExecutionPlan + RunExecution job when one delegation is executable",
         %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, _del} = Delegations.grant("sa-approval-1", "del-approval-1")

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-linh"})

      body = json_response(conn, 200)
      assert body["decision"]["outcome"] == "auto_exec"
      assert body["dispatch"] == "dispatched"
      assert body["execution_plan"]["smart_account_id"] == "sa-approval-1"
      assert body["execution_plan"]["execution_status"] == "prepared"
      refute Map.has_key?(body, "next_step")
      refute Map.has_key?(body, "held_reason")

      successor = Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true)
      assert successor.outcome == :auto_exec
      assert successor.supersedes_id == envelope.id

      assert %ExecutionPlan{} = Decisions.active_plan_for(successor.id)

      assert_enqueued(
        worker: RunExecution,
        queue: :executions_run,
        args: %{"decision_id" => successor.id}
      )
    end
  end

  describe "POST /v1/approvals/:id/approve — held path" do
    test "no delegation -> dispatch held with :no_executable_account, no plan", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-linh"})

      body = json_response(conn, 200)
      assert body["decision"]["outcome"] == "auto_exec"
      assert body["dispatch"] == "held"
      assert body["held_reason"] == "no_executable_account"

      assert %{"endpoint" => endpoint, "message" => message} = body["next_step"]
      assert endpoint =~ "/v1/decisions/"
      assert endpoint =~ "/execute"
      assert message =~ "no_executable_account"
      assert message =~ "smart_account_id"

      successor = Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true)
      assert successor.outcome == :auto_exec
      assert is_nil(Decisions.active_plan_for(successor.id))
      refute_enqueued(worker: RunExecution)

      # `intent.auto_exec_held` is written symmetrically with the
      # evaluation-driven held path so replay shows the same row
      # regardless of which path produced the held state (issue #151).
      assert_held_audit(intent.id, successor.id, "no_executable_account")
    end

    test "ambiguous delegations -> dispatch held with :ambiguous_executable_account",
         %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, _del1} = Delegations.grant("sa-amb-1", "del-amb-1")
      {:ok, _del2} = Delegations.grant("sa-amb-2", "del-amb-2")

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-linh"})

      body = json_response(conn, 200)
      assert body["dispatch"] == "held"
      assert body["held_reason"] == "ambiguous_executable_account"
      refute_enqueued(worker: RunExecution)
    end

    test "paused runtime -> approval recorded but dispatch held with :runtime_paused",
         %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, _del} = Delegations.grant("sa-paused", "del-paused")
      {:ok, :paused} = Security.pause(:global)

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-paused"})

      body = json_response(conn, 200)
      assert body["decision"]["outcome"] == "auto_exec"
      assert body["dispatch"] == "held"
      assert body["held_reason"] == "runtime_paused"

      refute_enqueued(worker: RunExecution)
      successor = Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true)
      assert is_nil(Decisions.active_plan_for(successor.id))
    end

    test "non-active delegation (revoking) -> dispatch held with :delegation_not_active",
         %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, _del} = Delegations.grant("sa-revoking", "del-revoking")
      {:ok, _} = Delegations.record_revoke_requested("sa-revoking")

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-linh"})

      body = json_response(conn, 200)
      assert body["dispatch"] == "held"
      assert body["held_reason"] == "no_executable_account"
      refute_enqueued(worker: RunExecution)
    end

    test "explicit smart_account_id opt overrides the resolver", %{conn: conn} do
      # The HTTP endpoint does not currently accept smart_account_id in
      # the body, but the underlying facade does — this pins that
      # facade-level override path so future endpoint additions can
      # rely on it. Test calls Bank.Decisions.approve/2 directly.
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, _del1} = Delegations.grant("sa-amb-3", "del-amb-3")
      {:ok, _del2} = Delegations.grant("sa-amb-4", "del-amb-4")
      {:ok, _del3} = Delegations.grant("sa-explicit", "del-explicit")

      assert {:ok, _successor, {:dispatched, plan}} =
               Decisions.approve(envelope.id,
                 actor_id: "op-explicit",
                 smart_account_id: "sa-explicit"
               )

      assert plan.smart_account_id == "sa-explicit"
      _ = conn
    end
  end

  describe "POST /v1/approvals/:id/approve — held audit symmetry (issue #151)" do
    test "ambiguous-account held writes intent.auto_exec_held{ambiguous_executable_account}", %{
      conn: conn
    } do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, _} = Delegations.grant("sa-held-amb-1", "del-held-amb-1")
      {:ok, _} = Delegations.grant("sa-held-amb-2", "del-held-amb-2")

      post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-amb"})

      successor = Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true)
      assert_held_audit(intent.id, successor.id, "ambiguous_executable_account")
    end

    test "paused-runtime held writes intent.auto_exec_held{runtime_paused}", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      # One executable delegation so resolution succeeds; the paused
      # check inside dispatch_auto_exec/3 is what trips.
      {:ok, _} = Delegations.grant("sa-held-paused", "del-held-paused")
      {:ok, :paused} = Security.pause(:global)

      post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-paused"})

      successor = Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true)
      assert_held_audit(intent.id, successor.id, "runtime_paused")
    end

    test "replay surfaces the held audit row for an approval-driven held intent", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      # No delegation seeded -> dispatch held.
      post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-replay"})

      replay = json_response(get(build_conn(), ~p"/v1/intents/#{intent.id}/replay"), 200)
      audit_event_types = Enum.map(replay["audit"], & &1["event_type"])

      assert "intent.auto_exec_held" in audit_event_types
      assert "approval.granted" in audit_event_types
    end

    test "dispatched approval does NOT write intent.auto_exec_held", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, _del} = Delegations.grant("sa-dispatched-no-held", "del-dispatched-no-held")

      post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-d"})

      refute held_audit_written?(intent.id),
             "intent.auto_exec_held must not be written when dispatch succeeds"
    end

    test "rejected approval does NOT write intent.auto_exec_held even with delegation present",
         %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      # Even with an executable delegation, reject must not auto_exec_held.
      {:ok, _del} = Delegations.grant("sa-reject-no-held", "del-reject-no-held")

      post(conn, ~p"/v1/approvals/#{envelope.id}/reject", %{
        "actor_id" => "op-r",
        "reason" => "duplicate"
      })

      refute held_audit_written?(intent.id),
             "intent.auto_exec_held must not be written on the reject path"
    end
  end

  describe "POST /v1/approvals/:id/approve — guards" do
    test "double-approve returns 409 already_superseded on the second call", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      conn1 = post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-1"})
      assert json_response(conn1, 200)

      conn2 = post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op-2"})
      body = json_response(conn2, 409)
      assert body["error"]["code"] == "already_superseded"
    end

    test "approving an expired-and-already-superseded envelope returns 409", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          # Past expiry so ExpireApproval will accept the job below.
          approval_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      # Run the expiry worker — supersedes prior with :block, intent → :blocked.
      assert :ok =
               perform_job(ExpireApproval, %{"decision_envelope_id" => envelope.id})

      # Confirm the prior is no longer current and there is now a :block successor.
      refute Repo.get!(DecisionEnvelope, envelope.id).current

      block_successor = Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true)
      assert block_successor.outcome == :block

      # Operator tries to approve the (now non-current) original envelope.
      conn = post(conn, ~p"/v1/approvals/#{envelope.id}/approve", %{"actor_id" => "op"})
      body = json_response(conn, 409)
      assert body["error"]["code"] == "already_superseded"
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
    test "rejects, blocks intent, never dispatches", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      # Even with an executable delegation present, reject must NOT
      # dispatch — the operator chose to block.
      {:ok, _del} = Delegations.grant("sa-reject", "del-reject")

      conn =
        post(conn, ~p"/v1/approvals/#{envelope.id}/reject", %{
          "actor_id" => "op-linh",
          "reason" => "duplicate"
        })

      body = json_response(conn, 200)
      assert body["decision"]["outcome"] == "block"
      assert body["dispatch"] == "no_dispatch"
      refute Map.has_key?(body, "execution_plan")
      refute Map.has_key?(body, "held_reason")

      successor = Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true)
      assert successor.outcome == :block

      updated_intent = Repo.get!(Bank.Intents.AgentIntent, intent.id)
      assert updated_intent.state == :blocked

      refute_enqueued(worker: RunExecution)
      assert is_nil(Decisions.active_plan_for(successor.id))
    end

    test "double-reject returns 409 already_superseded", %{conn: conn} do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      conn1 = post(conn, ~p"/v1/approvals/#{envelope.id}/reject", %{"actor_id" => "op-1"})
      assert json_response(conn1, 200)

      conn2 = post(conn, ~p"/v1/approvals/#{envelope.id}/reject", %{"actor_id" => "op-2"})
      body = json_response(conn2, 409)
      assert body["error"]["code"] == "already_superseded"
    end
  end

  # --- Held-audit helpers (issue #151) ---------------------------------------

  defp assert_held_audit(intent_id, envelope_id, expected_reason) do
    rows =
      Repo.all(
        from e in AuditEvent,
          where: e.event_type == "intent.auto_exec_held" and e.correlation_id == ^intent_id,
          order_by: [desc: e.ts, desc: e.id]
      )

    assert [%AuditEvent{} = row | _] = rows,
           "expected an intent.auto_exec_held audit row for intent #{intent_id}; got: #{inspect(rows)}"

    assert row.subject_type == "agent_intent"
    assert row.subject_id == intent_id
    assert row.after_ref["decision_envelope_id"] == envelope_id
    assert row.after_ref["held_reason"] == expected_reason
    assert row.actor in [:runtime, "runtime"]
  end

  defp held_audit_written?(intent_id) do
    Repo.exists?(
      from e in AuditEvent,
        where: e.event_type == "intent.auto_exec_held" and e.correlation_id == ^intent_id
    )
  end
end
