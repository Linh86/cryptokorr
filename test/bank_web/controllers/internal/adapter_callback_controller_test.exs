defmodule BankWeb.Internal.AdapterCallbackControllerTest do
  @moduledoc """
  Tests for `POST /internal/adapter/callback`.
  """

  use BankWeb.ConnCase, async: true

  import Ecto.Query
  import Plug.Conn, only: [put_req_header: 3]

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Delegations
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime.PubSub

  setup %{conn: conn} do
    secret = Application.fetch_env!(:bank, Bank.AdapterClient) |> Keyword.fetch!(:auth_secret)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> secret)}
  end

  # Build an in-flight plan at `status` with the owning intent at
  # `:executing`, mirroring the state after RunExecution has dispatched.
  defp in_flight_plan(status) do
    counterparty = Fixtures.counterparty()
    label = Fixtures.address_label(counterparty: counterparty, chain: "base")

    intent =
      Fixtures.agent_intent(
        counterparty: counterparty,
        target_address_label_id: label.id
      )

    {:ok, intent} =
      intent
      |> AgentIntent.current_pointer_changeset(%{state: :executing})
      |> Repo.update()

    decision = Fixtures.decision_envelope(intent: intent, current: true)

    plan =
      Fixtures.execution_plan(
        decision: decision,
        intent_id: intent.id,
        execution_status: status
      )

    %{intent: intent, plan: plan}
  end

  describe "POST /internal/adapter/callback — delegation.state_changed" do
    test "granted creates delegation and returns accepted", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "delegation.state_changed",
          "smart_account_id" => "sa_new",
          "delegation_id" => "del_new",
          "state" => "granted",
          "reason" => "initial_grant",
          "scope" => %{"asset" => "USDC"}
        })

      body = json_response(conn, 200)
      assert body["status"] == "accepted"
      assert body["kind"] == "delegation.state_changed"

      d = Delegations.get("sa_new")
      assert d.state == :active
      assert d.delegation_id == "del_new"
    end

    test "revoking transitions active delegation", %{conn: conn} do
      delegation("sa_rev", "del_rev")

      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "delegation.state_changed",
          "smart_account_id" => "sa_rev",
          "delegation_id" => "del_rev",
          "state" => "revoking",
          "reason" => "operator_requested"
        })

      body = json_response(conn, 200)
      assert body["status"] == "accepted"

      d = Delegations.get("sa_rev")
      assert d.state == :revoking
    end

    test "invalid transition returns accepted_with_warning", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "delegation.state_changed",
          "smart_account_id" => "sa_missing",
          "delegation_id" => "del_missing",
          "state" => "revoking",
          "reason" => "no_such_account"
        })

      body = json_response(conn, 200)
      assert body["status"] == "accepted_with_warning"
    end

    test "revoked with tx_refs records the on-chain hash and emits audit+broadcast",
         %{conn: conn} do
      delegation("sa_done", "del_done")
      {:ok, _} = Delegations.record_revoke_requested("sa_done")

      :ok = PubSub.subscribe(PubSub.security_events())
      :ok = PubSub.subscribe(PubSub.audit_stream())

      tx_hash = "0x" <> String.duplicate("f1", 32)

      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "delegation.state_changed",
          "smart_account_id" => "sa_done",
          "delegation_id" => "del_done",
          "state" => "revoked",
          "reason" => "operator_requested",
          "tx_refs" => [
            %{
              "chain" => "base",
              "hash" => tx_hash,
              "block_number" => 42_424_242,
              "status" => "success"
            }
          ]
        })

      assert json_response(conn, 200)["status"] == "accepted"

      d = Repo.get_by(Bank.Delegations.Delegation, smart_account_id: "sa_done")
      assert d.state == :revoked
      assert d.last_tx_hash == tx_hash

      assert_receive %{
        topic: :security_events,
        event: :delegation_state_changed,
        payload: %{state: :revoked, smart_account_id: "sa_done"}
      }

      assert_receive %{topic: :audit_stream, event: :appended}

      [event] =
        Repo.all(
          from e in AuditEvent,
            where: e.subject_type == "delegation" and e.event_type == "delegation.state_changed"
        )

      assert event.actor == :adapter
      assert event.after_ref["last_tx_hash"] == tx_hash
      assert event.after_ref["state"] == "revoked"
    end

    test "duplicate revoked callback returns accepted_with_warning without side effects",
         %{conn: conn} do
      delegation("sa_idemp", "del_idemp")
      {:ok, _} = Delegations.record_revoke_requested("sa_idemp")

      payload = %{
        "contract_version" => 1,
        "kind" => "delegation.state_changed",
        "smart_account_id" => "sa_idemp",
        "delegation_id" => "del_idemp",
        "state" => "revoked",
        "reason" => "operator_requested"
      }

      first = post(conn, "/internal/adapter/callback", payload)
      assert json_response(first, 200)["status"] == "accepted"

      second = post(conn, "/internal/adapter/callback", payload)
      body = json_response(second, 200)
      assert body["status"] == "accepted_with_warning"

      # Only one delegation.state_changed audit event from the first callback.
      events =
        Repo.all(
          from e in AuditEvent,
            where:
              e.event_type == "delegation.state_changed" and
                fragment("?->>'smart_account_id' = ?", e.after_ref, "sa_idemp")
        )

      assert length(events) == 1
    end
  end

  describe "POST /internal/adapter/callback — execution.broadcast" do
    test "advances the plan to :broadcasting and records tx_refs", %{conn: conn} do
      %{intent: intent, plan: plan} = in_flight_plan(:signing)

      :ok = PubSub.subscribe(PubSub.intent(intent.id))
      :ok = PubSub.subscribe(PubSub.audit_stream())

      tx_hash = "0x" <> String.duplicate("ab", 32)

      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.broadcast",
          "execution_plan_id" => plan.id,
          "tx_refs" => [%{"hash" => tx_hash, "nonce" => 7}]
        })

      body = json_response(conn, 200)
      assert body["status"] == "accepted"
      assert body["kind"] == "execution.broadcast"

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :broadcasting
      assert reloaded.tx_refs == [tx_hash]
      assert reloaded.nonce == 7

      # Intent stays :executing on a broadcast callback (no terminal yet).
      assert %AgentIntent{state: :executing} = Repo.get!(AgentIntent, intent.id)

      assert_receive %{
        topic: :intent_lifecycle,
        event: :execution_updated,
        payload: %{execution_status: :broadcasting}
      }

      assert_receive %{topic: :audit_stream, event: :appended}

      [event] = Repo.all(from e in AuditEvent, where: e.event_type == "execution.broadcasting")
      assert event.actor == :adapter
    end
  end

  describe "POST /internal/adapter/callback — execution.confirmed" do
    test "moves plan to :confirmed and intent to :executed", %{conn: conn} do
      %{intent: intent, plan: plan} = in_flight_plan(:pending_confirmation)

      :ok = PubSub.subscribe(PubSub.intent(intent.id))

      tx_hash = "0x" <> String.duplicate("cd", 32)

      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.confirmed",
          "execution_plan_id" => plan.id,
          "tx_refs" => [%{"hash" => tx_hash}]
        })

      assert json_response(conn, 200)["status"] == "accepted"

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :confirmed
      assert reloaded.final_outcome == :confirmed
      assert reloaded.tx_refs == [tx_hash]

      assert %AgentIntent{state: :executed} = Repo.get!(AgentIntent, intent.id)

      assert_receive %{
        topic: :intent_lifecycle,
        event: :execution_updated,
        payload: %{execution_status: :confirmed}
      }

      assert_receive %{
        topic: :intent_lifecycle,
        event: :state_changed,
        payload: %{from: :executing, to: :executed}
      }

      intent_events =
        Repo.all(from e in AuditEvent, where: e.event_type == "intent.state_changed")

      assert length(intent_events) == 1
      assert hd(intent_events).actor == :adapter
    end

    test "second confirmed callback is idempotent (no double transition)", %{conn: conn} do
      %{intent: intent, plan: plan} = in_flight_plan(:pending_confirmation)

      _ =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.confirmed",
          "execution_plan_id" => plan.id
        })

      _ =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.confirmed",
          "execution_plan_id" => plan.id
        })

      assert %AgentIntent{state: :executed} = Repo.get!(AgentIntent, intent.id)

      # Only one intent.state_changed audit event, not two.
      events = Repo.all(from e in AuditEvent, where: e.event_type == "intent.state_changed")
      assert length(events) == 1
    end
  end

  describe "POST /internal/adapter/callback — ERC-4337 v0.7 AA-shaped tx_refs (issue #32)" do
    # The adapter's AA path carries BOTH `userop_hash` (EntryPoint
    # identity) and `hash` (chain-level tx hash) on confirmed receipts,
    # plus `bundler` + hex-string `nonce`. Phoenix's `tx_refs` column is
    # `{:array, :string}` — the handler flattens each ref into both
    # hashes (userop first, then tx hash) so the control tower and
    # audit trail can link either identifier. The plan's `nonce`
    # column is `:integer` and does NOT fit AA 2D nonces, so we leave
    # it nil and rely on `tx_refs` for the full hex fidelity.
    test "execution.broadcast with AA-shaped tx_refs stores userop_hash and leaves nonce nil",
         %{conn: conn} do
      %{plan: plan} = in_flight_plan(:signing)

      userop_hash = "0x" <> String.duplicate("aa", 32)

      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.broadcast",
          "execution_plan_id" => plan.id,
          "tx_refs" => [
            %{
              "chain" => "base",
              "userop_hash" => userop_hash,
              "nonce" => "0x7",
              "bundler" => "base-v07-bundler"
            }
          ]
        })

      assert json_response(conn, 200)["status"] == "accepted"

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :broadcasting
      assert reloaded.tx_refs == [userop_hash]
      # AA 2D nonce is a hex string; the :integer column can't hold it.
      assert reloaded.nonce == nil
    end

    test "execution.confirmed with AA-shaped tx_refs stores userop_hash and tx hash (userop first)",
         %{conn: conn} do
      %{intent: intent, plan: plan} = in_flight_plan(:pending_confirmation)

      userop_hash = "0x" <> String.duplicate("bb", 32)
      tx_hash = "0x" <> String.duplicate("cc", 32)

      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.confirmed",
          "execution_plan_id" => plan.id,
          "tx_refs" => [
            %{
              "chain" => "base",
              "userop_hash" => userop_hash,
              "hash" => tx_hash,
              "nonce" => "0x7",
              "bundler" => "base-v07-bundler",
              "block_number" => 42_000,
              "status" => "success"
            }
          ]
        })

      assert json_response(conn, 200)["status"] == "accepted"

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :confirmed
      assert reloaded.final_outcome == :confirmed
      assert reloaded.tx_refs == [userop_hash, tx_hash]
      assert reloaded.nonce == nil

      assert %AgentIntent{state: :executed} = Repo.get!(AgentIntent, intent.id)
    end
  end

  describe "POST /internal/adapter/callback — execution.reverted" do
    test "moves plan to :reverted and intent to :blocked", %{conn: conn} do
      %{intent: intent, plan: plan} = in_flight_plan(:pending_confirmation)

      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.reverted",
          "execution_plan_id" => plan.id,
          "reason" => "chain_revert:out_of_gas"
        })

      assert json_response(conn, 200)["status"] == "accepted"

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :reverted
      assert reloaded.final_outcome == :reverted
      assert reloaded.final_reason == "chain_revert:out_of_gas"

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end
  end

  describe "POST /internal/adapter/callback — execution.aborted" do
    test "moves plan to :aborted and intent to :blocked", %{conn: conn} do
      %{intent: intent, plan: plan} = in_flight_plan(:broadcasting)

      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.aborted",
          "execution_plan_id" => plan.id,
          "reason" => "adapter_shutdown"
        })

      assert json_response(conn, 200)["status"] == "accepted"

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :aborted
      assert reloaded.final_outcome == :aborted
      assert reloaded.final_reason == "adapter_shutdown"

      assert %AgentIntent{state: :blocked} = Repo.get!(AgentIntent, intent.id)
    end
  end

  describe "POST /internal/adapter/callback — execution callback error paths" do
    test "unknown execution_plan_id returns accepted_with_warning", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "execution.confirmed",
          "execution_plan_id" => Ecto.UUID.generate()
        })

      body = json_response(conn, 200)
      assert body["status"] == "accepted_with_warning"
      assert body["warning"] == "plan_not_found"
    end
  end

  describe "POST /internal/adapter/callback — validation" do
    test "missing contract_version returns 400", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "kind" => "delegation.state_changed"
        })

      body = json_response(conn, 400)
      assert body["error"]["code"] == "missing_contract_version"
    end

    test "unsupported contract_version returns 422", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 99,
          "kind" => "delegation.state_changed"
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unsupported_contract_version"
    end

    test "missing kind returns 400", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1
        })

      body = json_response(conn, 400)
      assert body["error"]["code"] == "missing_kind"
    end

    test "unknown kind returns 422", %{conn: conn} do
      conn =
        post(conn, "/internal/adapter/callback", %{
          "contract_version" => 1,
          "kind" => "bogus.event"
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unknown_kind"
    end
  end

  # --- Helpers ---------------------------------------------------------------

  defp delegation(smart_account_id, delegation_id) do
    {:ok, d} = Delegations.grant(smart_account_id, delegation_id)
    d
  end
end
