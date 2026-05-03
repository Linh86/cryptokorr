defmodule BankWeb.API.V1.ConnectControllerTest do
  @moduledoc """
  Tests for `POST /v1/connect/smart_account`.

  The endpoint is v1.1 (#58 grant-flow follow-up). It accepts a
  browser-supplied connect request, writes an audit event, and
  enqueues `Bank.Runtime.Workers.GrantDelegation` to dispatch the
  grant to the adapter. The actual on-chain install + delegation
  row creation happens asynchronously via the
  `delegation.state_changed{state: "granted"}` callback path.
  """

  use BankWeb.ConnCase, async: true

  setup :setup_api_key_admin
  use Oban.Testing, repo: Bank.Repo

  alias Bank.APIKeys
  alias Bank.Audit.AuditEvent
  alias Bank.Repo
  alias Bank.Runtime.Workers.GrantDelegation
  alias Bank.Workspaces.Workspace
  alias BankWeb.API.V1.ConnectController

  import Ecto.Query
  import Plug.Conn, only: [assign: 3]

  describe "POST /v1/connect/smart_account" do
    test "accepts a valid payload, audits, and enqueues the grant worker", %{conn: conn} do
      payload = %{
        "smart_account_id" => "sa_demo_01",
        "account" => "0xabc000000000000000000000000000000000dead",
        "chain_id" => 84_532
      }

      conn = post(conn, ~p"/v1/connect/smart_account", payload)
      body = json_response(conn, 202)

      assert body["status"] == "accepted"
      assert body["smart_account_id"] == "sa_demo_01"
      # The note tells the operator the row arrives later via the
      # callback path — pin the language so a future re-stub
      # fails loudly.
      assert body["note"] =~ "Observe the delegation.state_changed"

      [event] =
        Repo.all(
          from e in AuditEvent,
            where: e.event_type == "delegation.connect_requested",
            order_by: [desc: e.inserted_at]
        )

      assert event.subject_type == "smart_account"
      assert event.subject_id == "sa_demo_01"
      assert event.after_ref["chain_id"] == 84_532
      assert event.after_ref["source"] == "browser_wallet"

      assert_enqueued(
        worker: GrantDelegation,
        args: %{
          "smart_account_id" => "sa_demo_01",
          "chain_id" => 84_532,
          "account" => "0xabc000000000000000000000000000000000dead"
        }
      )
    end

    test "broadcasts delegation.connect_requested on audit_stream after the request commits",
         %{conn: conn} do
      # Pre-fix `Delegations.write_intent_audit/3` called
      # `Bank.Audit.append_event/1` (silent insert) without a
      # follow-up `Notifier.audit_stream/1` broadcast, so
      # `BankWeb.AuditLive`'s real-time tail silently dropped every
      # `delegation.connect_requested` event. Post-fix the helper
      # uses `Bank.Runtime.emit_audit/1`, which writes + broadcasts.
      :ok = Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())

      payload = %{
        "smart_account_id" => "sa_broadcast_connect",
        "account" => "0xabc000000000000000000000000000000000dead",
        "chain_id" => 84_532
      }

      conn = post(conn, ~p"/v1/connect/smart_account", payload)
      assert json_response(conn, 202)

      assert_receive %{
        topic: :audit_stream,
        event: :appended,
        payload: %{
          event_type: "delegation.connect_requested",
          subject_id: "sa_broadcast_connect"
        }
      }
    end

    test "no delegation.connect_requested broadcast when validation rejects the payload",
         %{conn: conn} do
      # Unsupported chain_id rejects BEFORE `write_intent_audit/3`
      # runs (chain validation is the first `with` step). No audit
      # row is persisted, so no broadcast must fire either.
      :ok = Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())

      conn =
        post(conn, ~p"/v1/connect/smart_account", %{
          "smart_account_id" => "sa_no_broadcast",
          "account" => "0xabc000000000000000000000000000000000dead",
          "chain_id" => 1
        })

      assert json_response(conn, 422)

      refute_received %{
        topic: :audit_stream,
        event: :appended,
        payload: %{
          event_type: "delegation.connect_requested",
          subject_id: "sa_no_broadcast"
        }
      }
    end

    test "rejects missing smart_account_id", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/connect/smart_account", %{
          "account" => "0xabc",
          "chain_id" => 84_532
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["message"] =~ "smart_account_id"
    end

    test "rejects an unsupported chain_id", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/connect/smart_account", %{
          "smart_account_id" => "sa_demo_01",
          "account" => "0xabc",
          "chain_id" => 1
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unsupported_chain"
    end

    test "rejects a non-integer chain_id", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/connect/smart_account", %{
          "smart_account_id" => "sa_demo_01",
          "account" => "0xabc",
          "chain_id" => "84532"
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["message"] =~ "chain_id"
    end

    # --- #231-d block-new-grants gate -----------------------------------

    test "BLOCKED — paused workspace returns 422 workspace_paused via the in-flight race",
         %{workspace: %Workspace{} = ws, current_user: user} do
      # The auth pipeline rejects API keys for paused workspaces with
      # 401, so a pure-HTTP test for THIS controller-level gate is
      # structurally unreachable: VerifyAPIKey's preload sees the
      # paused state and short-circuits before the controller runs.
      # The gate exists for the narrow race where auth's preload
      # happened BEFORE the pause landed but the controller runs AFTER.
      # We synthesize that race here by directly invoking the
      # controller with an unpaused stale `current_scope.workspace`
      # while the DB row is paused — pins the freshness reload.
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user, reason: "block-new-grants test")

      stale_unpaused = %{ws | agent_keys_paused_at: nil, agent_keys_paused_reason: nil}

      conn =
        build_conn()
        |> assign(:current_scope, %{workspace: stale_unpaused})
        |> ConnectController.request(%{
          "smart_account_id" => "sa_blocked",
          "account" => "0xabc000000000000000000000000000000000dead",
          "chain_id" => 84_532
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "workspace_paused"
      assert body["error"]["message"] =~ "agent keys are paused"

      # No `delegation.connect_requested` audit row emitted — the gate
      # runs before `Delegations.request_connect/1`.
      audit_rows =
        Repo.all(
          from e in AuditEvent,
            where:
              e.event_type == "delegation.connect_requested" and
                e.subject_id == "sa_blocked"
        )

      assert audit_rows == []

      # No GrantDelegation worker enqueued either.
      refute_enqueued(worker: GrantDelegation, args: %{"smart_account_id" => "sa_blocked"})
    end

    test "fresh-load gate is load-bearing: paused state in DB blocks even an unpaused scope",
         %{workspace: %Workspace{} = ws, current_user: user} do
      # Tighter version of the previous test: the synthesized scope is
      # explicitly unpaused, but the DB row is paused. Without the
      # `Repo.get(Workspace, ws_id)` reload inside `request/2`, this
      # request would proceed.
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user, reason: "freshness pin")

      stale = %{ws | agent_keys_paused_at: nil}

      conn =
        build_conn()
        |> assign(:current_scope, %{workspace: stale})
        |> ConnectController.request(%{
          "smart_account_id" => "sa_freshness",
          "account" => "0xabc000000000000000000000000000000000dead",
          "chain_id" => 84_532
        })

      assert json_response(conn, 422)["error"]["code"] == "workspace_paused"
    end

    test "accepts a re-connect after a prior grant_failed callback", %{conn: conn} do
      # PR #130 contract: a `state: "grant_failed"` callback does
      # NOT create an active delegation row. That means a follow-up
      # connect request for the same smart account must be allowed
      # — the operator (or the user via the JS hook) needs to be
      # able to retry after fixing the underlying failure
      # (operator key missing, chain mismatch, install reverted).
      # If a grant_failed left a non-terminal row behind, this test
      # would surface that regression because re-enqueueing would
      # be silently blocked or the audit trail would diverge.
      Bank.Delegations.apply_callback(%{
        "smart_account_id" => "sa_retry_after_failure",
        "delegation_id" => "grant_failed_legacy",
        "state" => "grant_failed",
        "reason" => "operator_key_missing"
      })

      payload = %{
        "smart_account_id" => "sa_retry_after_failure",
        "account" => "0xabc000000000000000000000000000000000dead",
        "chain_id" => 84_532
      }

      conn = post(conn, ~p"/v1/connect/smart_account", payload)
      assert json_response(conn, 202)["status"] == "accepted"

      assert_enqueued(
        worker: GrantDelegation,
        args: %{
          "smart_account_id" => "sa_retry_after_failure",
          "chain_id" => 84_532,
          "account" => "0xabc000000000000000000000000000000000dead"
        }
      )
    end
  end
end
