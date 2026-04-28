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
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Repo
  alias Bank.Runtime.Workers.GrantDelegation

  import Ecto.Query

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
