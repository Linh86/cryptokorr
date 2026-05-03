defmodule BankWeb.API.V1.SecurityControllerTest do
  @moduledoc """
  Tests for `/v1/security` (pause, resume, revoke_delegation).
  """

  use BankWeb.ConnCase, async: false

  setup :setup_api_key_admin

  import Ecto.Query

  alias Bank.Security
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  # --- POST /v1/security/pause -------------------------------------------

  describe "POST /v1/security/pause" do
    test "pauses the global runtime", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/pause", %{})
      body = json_response(conn, 200)

      assert body["status"] == "paused"
      assert body["scope"] == "global"
      assert Security.paused?(:global)
    end

    test "returns already_paused on double pause", %{conn: conn} do
      {:ok, :paused} = Security.pause(:global)

      conn = post(conn, ~p"/v1/security/pause", %{})
      body = json_response(conn, 200)

      assert body["status"] == "already_paused"
    end

    test "supports counterparty scope", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/pause", %{"scope" => "counterparty:cp_123"})
      body = json_response(conn, 200)

      assert body["status"] == "paused"
      assert body["scope"] == "counterparty:cp_123"
      assert Security.paused?({:counterparty, "cp_123"})
    end
  end

  # --- POST /v1/security/resume ------------------------------------------

  describe "POST /v1/security/resume" do
    test "resumes a paused runtime", %{conn: conn} do
      {:ok, :paused} = Security.pause(:global)

      conn = post(conn, ~p"/v1/security/resume", %{})
      body = json_response(conn, 200)

      assert body["status"] == "resumed"
      assert body["scope"] == "global"
      refute Security.paused?(:global)
    end

    test "returns already_running when not paused", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/resume", %{})
      body = json_response(conn, 200)

      assert body["status"] == "already_running"
    end
  end

  # --- POST /v1/security/revoke_delegation --------------------------------

  describe "POST /v1/security/revoke_delegation" do
    test "requires smart_account_id", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/revoke_delegation", %{})
      body = json_response(conn, 422)

      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["message"] =~ "smart_account_id"
    end

    test "rejects empty smart_account_id", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/security/revoke_delegation", %{"smart_account_id" => ""})

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end

    test "enqueues revoke and returns 202", %{conn: conn} do
      # The revoke enqueue goes through Oban (testing: :manual), which
      # inserts the job but doesn't execute it. Security.revoke_delegation
      # also calls Delegations.record_revoke_requested, but since there's
      # no delegation row the :not_found is swallowed.
      conn =
        post(conn, ~p"/v1/security/revoke_delegation", %{
          "smart_account_id" => "sa_test"
        })

      body = json_response(conn, 202)
      assert body["status"] == "revoke_enqueued"
      assert body["smart_account_id"] == "sa_test"
    end

    # --- Atom-creation safety on `reason` (#212 P2 patch) -----------

    test "arbitrary reason in body does NOT create a new atom and still 202s",
         %{conn: conn} do
      # Pre-#212-fix this called `String.to_atom/1` on the request body,
      # which would have minted a fresh atom for any caller-controlled
      # string. Confirm the byte sequence below was not previously a
      # known atom and STAYS unknown after the request.
      probe = "p2_atom_probe_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(probe) end

      conn =
        post(conn, ~p"/v1/security/revoke_delegation", %{
          "smart_account_id" => "sa_test_probe",
          "reason" => probe
        })

      assert json_response(conn, 202)["status"] == "revoke_enqueued"

      # Same `String.to_existing_atom/1` after the request — would not
      # raise iff the controller had created the atom.
      assert_raise ArgumentError, fn -> String.to_existing_atom(probe) end
    end

    test "known reason on the allowlist passes through (sanity)", %{conn: conn} do
      # `:agent_offboarded` is one of the documented operator-facing
      # reasons (`Bank.Runtime.enqueue_delegation_revoke/3`). The
      # controller sanitizes via `String.to_existing_atom/1` only after
      # an allowlist match, so this should still 202.
      conn =
        post(conn, ~p"/v1/security/revoke_delegation", %{
          "smart_account_id" => "sa_known_reason",
          "reason" => "agent_offboarded"
        })

      assert json_response(conn, 202)["status"] == "revoke_enqueued"
    end

    test "missing reason still defaults to operator_requested (no regression)",
         %{conn: conn} do
      conn =
        post(conn, ~p"/v1/security/revoke_delegation", %{
          "smart_account_id" => "sa_default_reason"
        })

      assert json_response(conn, 202)["status"] == "revoke_enqueued"
    end
  end

  # --- POST /v1/security/pause_agent_keys (#231-b) ------------------------

  describe "POST /v1/security/pause_agent_keys" do
    alias Bank.APIKeys
    alias Bank.Audit
    alias Bank.Workspaces.Workspace

    test "admin pauses own workspace and response carries the new state",
         %{conn: conn, workspace: ws, current_user: user} do
      conn =
        post(conn, ~p"/v1/security/pause_agent_keys", %{
          "reason" => "credential leak smoke"
        })

      body = json_response(conn, 200)

      assert %{
               "data" => %{
                 "workspace_id" => ws_id,
                 "paused" => true,
                 "agent_keys_paused_at" => paused_at,
                 "paused_by_user_id" => paused_by,
                 "reason" => "credential leak smoke"
               }
             } = body

      assert ws_id == ws.id
      assert is_binary(paused_at)
      assert paused_by == user.id

      reloaded = Bank.Repo.get!(Workspace, ws.id)
      assert %DateTime{} = reloaded.agent_keys_paused_at
      assert reloaded.agent_keys_paused_reason == "credential leak smoke"
      assert reloaded.agent_keys_paused_by_user_id == user.id

      # Audit row was emitted with the human actor_id (not the
      # api_key id).
      %{events: events} = Audit.list_events(%{event_type: "agent_keys.paused"})
      [event] = Enum.filter(events, &(&1.workspace_id == ws.id))
      assert event.actor == :user
      assert event.actor_id == user.id
    end

    test "BOOTSTRAP — second pause via HTTP fails 401 because the calling key is now paused",
         %{conn: conn, workspace: ws} do
      # First HTTP pause succeeds (current_scope.workspace was unpaused
      # at auth time).
      first = post(conn, ~p"/v1/security/pause_agent_keys", %{"reason" => "first"})
      assert json_response(first, 200)["data"]["paused"] == true

      # The same conn's API key is now in a paused workspace, so
      # `VerifyAPIKey` short-circuits BEFORE the controller. Second
      # call returns 401 — pin the bootstrap caveat documented on
      # the operation spec.
      second =
        post(conn, ~p"/v1/security/pause_agent_keys", %{"reason" => "second-different"})

      assert %{"error" => %{"code" => "invalid_credentials"}} = json_response(second, 401)

      # Workspace state still carries the FIRST call's metadata.
      reloaded = Bank.Repo.get!(Workspace, ws.id)
      assert reloaded.agent_keys_paused_reason == "first"

      # Exactly ONE `agent_keys.paused` audit row.
      %{events: events} = Audit.list_events(%{event_type: "agent_keys.paused"})
      ws_events = Enum.filter(events, &(&1.workspace_id == ws.id))
      assert length(ws_events) == 1
    end

    test "request body workspace_id is silently ignored — current_scope wins",
         %{conn: conn, workspace: ws, current_user: user, raw_api_key: _raw} do
      # Forge another workspace and try to pass it in the body.
      {:ok, other_ws} = Bank.Workspaces.create_workspace(%{slug: "ws-forge", name: "Forge"})

      conn =
        post(conn, ~p"/v1/security/pause_agent_keys", %{
          "workspace_id" => other_ws.id,
          "reason" => "smoke"
        })

      body = json_response(conn, 200)

      assert body["data"]["workspace_id"] == ws.id
      assert body["data"]["workspace_id"] != other_ws.id
      assert body["data"]["paused_by_user_id"] == user.id

      # The forged workspace is unaffected.
      reloaded_other = Bank.Repo.get!(Workspace, other_ws.id)
      refute Workspace.agent_keys_paused?(reloaded_other)
    end

    test "operator-tier key gets 403 insufficient_role when unpaused",
         %{workspace: ws, current_user: user} do
      {:ok, _, op_raw} = APIKeys.create_key(ws, user, :operator, "op-pause-attempt")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> op_raw)
        |> post(~p"/v1/security/pause_agent_keys", %{})

      assert %{"error" => %{"code" => "insufficient_role"}} = json_response(conn, 403)
    end

    test "missing auth returns 401", %{workspace: _ws} do
      conn = build_conn() |> post(~p"/v1/security/pause_agent_keys", %{})
      assert %{"error" => %{"code" => "missing_authorization"}} = json_response(conn, 401)
    end

    test "reason longer than 256 chars returns 422 invalid_reason", %{conn: conn} do
      reason = String.duplicate("x", 257)

      conn = post(conn, ~p"/v1/security/pause_agent_keys", %{"reason" => reason})

      assert %{"error" => %{"code" => "invalid_reason"}} = json_response(conn, 422)
    end

    test "audit JSON contains NO raw bearer / Authorization / secret_hash",
         %{conn: conn, raw_api_key: raw} do
      _ = post(conn, ~p"/v1/security/pause_agent_keys", %{"reason" => "smoke"})

      %{events: events} = Audit.list_events(%{event_type: "agent_keys.paused"})
      [event] = events

      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ raw
      refute json =~ "secret_hash"
      refute json =~ "Bearer "
    end
  end

  # --- POST /v1/security/resume_agent_keys (#231-b) -----------------------

  describe "POST /v1/security/resume_agent_keys" do
    alias Bank.APIKeys
    alias Bank.Audit
    alias Bank.Workspaces.Workspace

    test "BOOTSTRAP — paused workspace's API key cannot resume via /v1 (returns 401)",
         %{conn: conn, workspace: ws, current_user: user} do
      # The verify_key/1 short-circuit is the gate: a paused
      # workspace's keys never reach the controller, so resume MUST
      # come from a non-API-key path. Pin this contract.
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user, reason: "lock me out")

      conn = post(conn, ~p"/v1/security/resume_agent_keys", %{})

      assert %{"error" => %{"code" => "invalid_credentials"}} = json_response(conn, 401)

      # Resume did NOT happen.
      reloaded = Bank.Repo.get!(Workspace, ws.id)
      assert %DateTime{} = reloaded.agent_keys_paused_at
    end

    test "idempotent resume on unpaused workspace returns 200 with paused: false",
         %{conn: conn, workspace: ws} do
      conn = post(conn, ~p"/v1/security/resume_agent_keys", %{})

      body = json_response(conn, 200)

      assert body["data"]["workspace_id"] == ws.id
      assert body["data"]["paused"] == false
      assert is_nil(body["data"]["agent_keys_paused_at"])

      # No audit row emitted on a no-op resume.
      %{events: events} = Audit.list_events(%{event_type: "agent_keys.resumed"})
      assert Enum.filter(events, &(&1.workspace_id == ws.id)) == []
    end

    test "operator-tier key gets 403", %{workspace: ws, current_user: user} do
      {:ok, _, op_raw} = APIKeys.create_key(ws, user, :operator, "op-resume-attempt")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> op_raw)
        |> post(~p"/v1/security/resume_agent_keys", %{})

      assert %{"error" => %{"code" => "insufficient_role"}} = json_response(conn, 403)
    end

    test "missing auth returns 401" do
      conn = build_conn() |> post(~p"/v1/security/resume_agent_keys", %{})
      assert %{"error" => %{"code" => "missing_authorization"}} = json_response(conn, 401)
    end
  end

  # --- POST /v1/security/abort_execution (#230) ---------------------------

  describe "POST /v1/security/abort_execution" do
    alias Bank.APIKeys
    alias Bank.Decisions.ExecutionPlan
    import Bank.Fixtures

    test "admin aborts a :prepared plan in own workspace and returns 200",
         %{conn: conn, workspace: ws} do
      intent = agent_intent(state: :decided, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: ws.id)

      conn =
        post(conn, ~p"/v1/security/abort_execution", %{
          "execution_plan_id" => plan.id,
          "reason" => "stuck_pending"
        })

      body = json_response(conn, 200)

      assert body["status"] == "aborted"
      assert body["data"]["execution_plan_id"] == plan.id
      assert body["data"]["execution_status"] == "aborted"
      assert body["data"]["final_outcome"] == "aborted"
      assert body["data"]["final_reason"] == "stuck_pending"
      assert body["data"]["workspace_id"] == ws.id

      reloaded = Bank.Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :aborted
    end

    test "missing execution_plan_id returns 422 invalid_body", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/abort_execution", %{})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["message"] =~ "execution_plan_id"
    end

    test "empty execution_plan_id returns 422 invalid_body", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/security/abort_execution", %{"execution_plan_id" => ""})

      assert json_response(conn, 422)["error"]["code"] == "invalid_body"
    end

    test "cross-workspace plan returns 404 not_found",
         %{conn: conn} do
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{slug: "other-abort-controller", name: "Other"})

      Process.put(:bank_test_workspace_id, other_ws.id)
      intent = agent_intent(state: :decided, workspace_id: other_ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: other_ws.id)
      Process.put(:bank_test_workspace_id, nil)

      conn =
        post(conn, ~p"/v1/security/abort_execution", %{
          "execution_plan_id" => plan.id
        })

      assert json_response(conn, 404)["error"]["code"] == "not_found"

      reloaded = Bank.Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :prepared
    end

    test "unknown plan id returns 404 not_found", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/security/abort_execution", %{
          "execution_plan_id" => Ecto.UUID.generate()
        })

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "plan in :signing returns 409 not_safe_to_abort",
         %{conn: conn, workspace: ws} do
      intent = agent_intent(state: :executing, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)

      plan =
        execution_plan(
          decision: envelope,
          workspace_id: ws.id,
          execution_status: :signing
        )

      conn =
        post(conn, ~p"/v1/security/abort_execution", %{
          "execution_plan_id" => plan.id
        })

      body = json_response(conn, 409)
      assert body["error"]["code"] == "not_safe_to_abort"
      assert body["error"]["details"]["execution_status"] == "signing"
    end

    test "idempotent re-abort returns 200 already_terminal, no second audit row",
         %{conn: conn, workspace: ws} do
      intent = agent_intent(state: :decided, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: ws.id)

      _ =
        post(conn, ~p"/v1/security/abort_execution", %{"execution_plan_id" => plan.id})

      conn =
        post(conn, ~p"/v1/security/abort_execution", %{"execution_plan_id" => plan.id})

      body = json_response(conn, 200)
      # Top-level status now signals "no-op" so a client cannot
      # mistake an idempotent re-call for a fresh abort.
      assert body["status"] == "already_terminal"
      assert body["data"]["execution_status"] == "aborted"

      assert Bank.Repo.aggregate(
               from(e in Bank.Audit.AuditEvent,
                 where: e.event_type == "execution.aborted" and e.subject_id == ^plan.id
               ),
               :count
             ) == 1
    end

    test "already-:confirmed plan returns 200 already_terminal with execution_status: confirmed (no lie)",
         %{conn: conn, workspace: ws} do
      # Pre-fix the controller replied `{"status":"aborted",
      # "data":{"execution_status":"confirmed"}}` for an already-
      # confirmed plan, which mis-stated the top-level status. Pin
      # the corrected behavior.
      intent = agent_intent(state: :executed, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)

      plan =
        execution_plan(
          decision: envelope,
          workspace_id: ws.id,
          execution_status: :confirmed,
          final_outcome: :confirmed
        )

      conn =
        post(conn, ~p"/v1/security/abort_execution", %{"execution_plan_id" => plan.id})

      body = json_response(conn, 200)
      assert body["status"] == "already_terminal"
      assert body["data"]["execution_status"] == "confirmed"
      assert body["data"]["final_outcome"] == "confirmed"

      # No `execution.aborted` audit row from this no-op call.
      assert Bank.Repo.aggregate(
               from(e in Bank.Audit.AuditEvent,
                 where: e.event_type == "execution.aborted" and e.subject_id == ^plan.id
               ),
               :count
             ) == 0
    end

    test "operator-tier key gets 403 insufficient_role",
         %{workspace: ws, current_user: user} do
      {:ok, _, op_raw} = APIKeys.create_key(ws, user, :operator, "op-abort-attempt")

      intent = agent_intent(state: :decided, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: ws.id)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> op_raw)
        |> post(~p"/v1/security/abort_execution", %{"execution_plan_id" => plan.id})

      assert %{"error" => %{"code" => "insufficient_role"}} = json_response(conn, 403)

      reloaded = Bank.Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :prepared
    end

    test "missing auth returns 401" do
      conn =
        build_conn()
        |> post(~p"/v1/security/abort_execution", %{
          "execution_plan_id" => Ecto.UUID.generate()
        })

      assert %{"error" => %{"code" => "missing_authorization"}} = json_response(conn, 401)
    end

    test "unknown reason value silently collapses to operator_requested (allowlist)",
         %{conn: conn, workspace: ws} do
      intent = agent_intent(state: :decided, workspace_id: ws.id)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, workspace_id: ws.id)

      probe = "unknown_reason_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(probe) end

      conn =
        post(conn, ~p"/v1/security/abort_execution", %{
          "execution_plan_id" => plan.id,
          "reason" => probe
        })

      body = json_response(conn, 200)
      assert body["data"]["final_reason"] == "operator_requested"

      assert_raise ArgumentError, fn -> String.to_existing_atom(probe) end
    end
  end

  # --- POST /v1/security/pause_chain + /resume_chain (#228 phase 1) -------

  describe "POST /v1/security/pause_chain" do
    alias Bank.Audit.AuditEvent
    alias Bank.Repo

    test "admin pauses a chain in own workspace and returns 200 with safe data",
         %{conn: conn, workspace: ws, current_user: user} do
      conn =
        post(conn, ~p"/v1/security/pause_chain", %{
          "chain" => "base",
          "reason" => "rpc outage"
        })

      body = json_response(conn, 200)

      assert body["status"] == "paused"
      assert body["data"]["scope_type"] == "chain"
      assert body["data"]["scope_value"] == "base"
      assert body["data"]["workspace_id"] == ws.id
      assert body["data"]["paused_at"]
      assert body["data"]["resumed_at"] == nil
      assert body["data"]["reason"] == "rpc outage"
      assert body["data"]["created_by_user_id"] == user.id

      assert Bank.Security.paused?(ws.id, {:chain, "base"})
    end

    test "idempotent re-pause returns 200 already_paused with no second audit row",
         %{conn: conn, workspace: ws} do
      conn1 = post(conn, ~p"/v1/security/pause_chain", %{"chain" => "base"})
      assert json_response(conn1, 200)["status"] == "paused"

      conn2 = post(conn, ~p"/v1/security/pause_chain", %{"chain" => "base"})
      body = json_response(conn2, 200)

      assert body["status"] == "already_paused"
      assert body["data"]["scope_value"] == "base"
      assert body["data"]["workspace_id"] == ws.id

      assert audit_count("security.scope_paused", ws.id) == 1
    end

    test "missing chain returns 422 invalid_body", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/pause_chain", %{})
      body = json_response(conn, 422)

      assert body["error"]["code"] == "invalid_body"
    end

    test "blank chain returns 422 invalid_body", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/pause_chain", %{"chain" => "   "})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end

    test "unsupported chain returns 422 unsupported_chain (#228 Phase 1: base only)",
         %{conn: conn, workspace: ws} do
      conn = post(conn, ~p"/v1/security/pause_chain", %{"chain" => "optimism"})
      body = json_response(conn, 422)

      assert body["error"]["code"] == "unsupported_chain"
      assert body["error"]["message"] =~ "supported chains: base"

      # No pause row was created and no audit event was emitted.
      refute Bank.Security.paused?(ws.id, {:chain, "optimism"})
      assert audit_count("security.scope_paused", ws.id) == 0
    end

    test "trims whitespace and accepts ' base ' as 'base'",
         %{conn: conn, workspace: ws} do
      conn = post(conn, ~p"/v1/security/pause_chain", %{"chain" => "  base  "})
      body = json_response(conn, 200)

      assert body["status"] == "paused"
      assert body["data"]["scope_value"] == "base"
      assert Bank.Security.paused?(ws.id, {:chain, "base"})
    end

    test "reason longer than 256 returns 422 invalid_reason", %{conn: conn} do
      long = String.duplicate("x", 257)

      conn =
        post(conn, ~p"/v1/security/pause_chain", %{
          "chain" => "base",
          "reason" => long
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_reason"
    end

    test "operator (non-admin) key is rejected with 403 insufficient_role" do
      {:ok, fields} = setup_api_key_operator(%{conn: Phoenix.ConnTest.build_conn()})
      conn = post(fields[:conn], ~p"/v1/security/pause_chain", %{"chain" => "base"})

      assert json_response(conn, 403)["error"]["code"] == "insufficient_role"
    end

    test "request without auth returns 401", %{conn: _conn} do
      anon = Phoenix.ConnTest.build_conn()
      conn = post(anon, ~p"/v1/security/pause_chain", %{"chain" => "base"})

      assert json_response(conn, 401)
    end

    test "ignores body workspace_id; uses current_scope workspace",
         %{conn: conn, workspace: ws} do
      sibling_id = Ecto.UUID.generate()

      conn =
        post(conn, ~p"/v1/security/pause_chain", %{
          "chain" => "base",
          "workspace_id" => sibling_id
        })

      body = json_response(conn, 200)

      assert body["data"]["workspace_id"] == ws.id
      refute body["data"]["workspace_id"] == sibling_id
    end

    test "response carries no secret-bearing substrings", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/security/pause_chain", %{
          "chain" => "base",
          "reason" => "looks fine"
        })

      raw = response(conn, 200)

      for needle <- ["Bearer", "Authorization", "0x", "sk_", "pk_", "http"] do
        refute String.contains?(raw, needle),
               "pause_chain response must not leak #{needle}: #{inspect(raw)}"
      end
    end

    defp audit_count(event_type, workspace_id) do
      AuditEvent
      |> where([e], e.event_type == ^event_type and e.workspace_id == ^workspace_id)
      |> Repo.aggregate(:count, :id)
    end
  end

  describe "POST /v1/security/resume_chain" do
    alias Bank.Audit.AuditEvent
    alias Bank.Repo

    test "admin resumes a paused chain and returns 200 with safe data",
         %{conn: conn, workspace: ws} do
      _ = post(conn, ~p"/v1/security/pause_chain", %{"chain" => "base"})

      conn = post(conn, ~p"/v1/security/resume_chain", %{"chain" => "base"})
      body = json_response(conn, 200)

      assert body["status"] == "resumed"
      assert body["data"]["scope_value"] == "base"
      assert body["data"]["workspace_id"] == ws.id
      assert body["data"]["resumed_at"]

      refute Bank.Security.paused?(ws.id, {:chain, "base"})
    end

    test "idempotent re-resume returns 200 already_running with null data and no second audit",
         %{conn: conn, workspace: ws} do
      conn = post(conn, ~p"/v1/security/resume_chain", %{"chain" => "base"})
      body = json_response(conn, 200)

      assert body["status"] == "already_running"
      assert is_nil(body["data"])

      assert resume_audit_count(ws.id) == 0
    end

    test "missing chain returns 422 invalid_body", %{conn: conn} do
      conn = post(conn, ~p"/v1/security/resume_chain", %{})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end

    test "unsupported chain returns 422 unsupported_chain (#228 Phase 1: base only)",
         %{conn: conn} do
      conn = post(conn, ~p"/v1/security/resume_chain", %{"chain" => "optimism"})
      body = json_response(conn, 422)

      assert body["error"]["code"] == "unsupported_chain"
      assert body["error"]["message"] =~ "supported chains: base"
    end

    test "trims whitespace and accepts ' base ' as 'base'",
         %{conn: conn, workspace: ws} do
      {:ok, :paused, _} =
        Bank.Security.pause(ws.id, {:chain, "base"}, actor: :user, actor_id: nil)

      conn = post(conn, ~p"/v1/security/resume_chain", %{"chain" => "  base  "})
      body = json_response(conn, 200)

      assert body["status"] == "resumed"
      assert body["data"]["scope_value"] == "base"
      refute Bank.Security.paused?(ws.id, {:chain, "base"})
    end

    test "operator (non-admin) key is rejected with 403", %{conn: _conn} do
      operator_ctx = setup_api_key_operator(%{conn: Phoenix.ConnTest.build_conn()})
      {:ok, fields} = operator_ctx
      conn = post(fields[:conn], ~p"/v1/security/resume_chain", %{"chain" => "base"})

      assert json_response(conn, 403)["error"]["code"] == "insufficient_role"
    end

    defp resume_audit_count(workspace_id) do
      AuditEvent
      |> where([e], e.event_type == "security.scope_resumed" and e.workspace_id == ^workspace_id)
      |> Repo.aggregate(:count, :id)
    end
  end

  describe "/v1/security/pause_chain — cross-workspace isolation" do
    test "sibling workspace's paused chain does not affect this workspace",
         %{conn: conn, workspace: ws} do
      {:ok, sibling} =
        Bank.Workspaces.create_workspace(%{slug: "sibling-iso", name: "Sibling iso"})

      {:ok, sibling_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "sibling-iso-user-#{System.unique_integer([:positive])}",
          email: "sibling-iso-user@example.com",
          name: "Sibling Iso User"
        })

      {:ok, _} =
        Bank.Workspaces.create_membership(%{
          user_id: sibling_user.id,
          workspace_id: sibling.id,
          role: :admin
        })

      # Pause base in the sibling workspace via the context (bypasses HTTP).
      {:ok, :paused, _} =
        Bank.Security.pause(sibling.id, {:chain, "base"}, actor: sibling_user)

      # Caller (admin in `ws`) sees their own chain as not paused.
      assert Bank.Security.paused?(sibling.id, {:chain, "base"})
      refute Bank.Security.paused?(ws.id, {:chain, "base"})

      # Caller can pause base in their own workspace independently and the
      # response carries their workspace_id only.
      conn = post(conn, ~p"/v1/security/pause_chain", %{"chain" => "base"})
      body = json_response(conn, 200)

      assert body["status"] == "paused"
      assert body["data"]["workspace_id"] == ws.id
      refute body["data"]["workspace_id"] == sibling.id
    end
  end
end
