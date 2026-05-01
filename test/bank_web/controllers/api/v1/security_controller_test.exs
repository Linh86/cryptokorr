defmodule BankWeb.API.V1.SecurityControllerTest do
  @moduledoc """
  Tests for `/v1/security` (pause, resume, revoke_delegation).
  """

  use BankWeb.ConnCase, async: false

  setup :setup_api_key_admin

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
end
