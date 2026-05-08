defmodule BankWeb.AgentLive.ActivityTest do
  @moduledoc """
  Wiring tests for `BankWeb.AgentLive`'s activity strip,
  `BankWeb.AgentActivityLive`'s full timeline + filter chips, and
  the shared `Bank.Audit.ActivityView` transformer.

  `async: false` because we publish on the `audit:stream` PubSub
  topic and assert other LiveView processes pick the broadcast up.
  """
  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bank.Fixtures

  alias Bank.Audit.{ActivityView, AuditEvent}

  setup :register_and_log_in_user

  describe "BankWeb.AgentLive activity strip" do
    test "renders empty state when the workspace has no audit rows", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "05 — Activity"
      assert html =~ "No activity yet. Run a test intent to populate this."
      # Lock in: the strip must not fall back to the old hardcoded
      # `@seed_activity` rows when there are no audit events.
      refute html =~ "Permission ready to install"
      refute html =~ "Faucet drip received"
    end

    test "another workspace's audit rows do not appear at mount", %{conn: conn} do
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "other-mount-#{System.unique_integer([:positive])}",
          name: "Other workspace at mount"
        })

      _foreign =
        audit_event(
          event_type: "wallet_binding.verified",
          subject_type: "wallet_binding",
          subject_id: Ecto.UUID.generate(),
          actor: :user,
          workspace_id: other_ws.id,
          after_ref: %{"address" => "0xfeed00112233445566778899aabbccddeeff1122"}
        )

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "No activity yet. Run a test intent to populate this."
      refute html =~ "Wallet connected"
    end

    test "renders the most recent audit rows transformed via ActivityView",
         %{conn: conn} do
      _wallet_event =
        audit_event(
          event_type: "wallet_binding.verified",
          subject_type: "wallet_binding",
          subject_id: Ecto.UUID.generate(),
          actor: :user,
          after_ref: %{"address" => "0x7a2f00112233445566778899aabbccddeeff1122"}
        )

      _install_event =
        audit_event(
          event_type: "delegation.install_confirmed_onchain",
          subject_type: "delegation",
          subject_id: Ecto.UUID.generate(),
          actor: :runtime
        )

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Wallet connected"
      assert html =~ "Permission installed"
    end

    test "audit:stream broadcast prepends a new event live", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")
      refute html =~ "Wallet connected"

      # Append + broadcast — same shape `Bank.Runtime.emit_audit/1`
      # produces. We use `Bank.Audit.append_event/1` directly and then
      # broadcast manually so we don't depend on every emitter site
      # routing through the runtime helper.
      event =
        audit_event(
          event_type: "wallet_binding.verified",
          subject_type: "wallet_binding",
          subject_id: Ecto.UUID.generate(),
          actor: :user,
          after_ref: %{"address" => "0xabcd00112233445566778899aabbccddeeff1122"}
        )

      Bank.Runtime.PubSub.broadcast(
        Bank.Runtime.PubSub.audit_stream(),
        %{
          topic: :audit_stream,
          event: :appended,
          at: DateTime.utc_now(),
          payload: %{
            id: event.id,
            event_type: event.event_type,
            subject_type: event.subject_type,
            subject_id: event.subject_id,
            correlation_id: event.correlation_id,
            ts: event.ts
          }
        }
      )

      assert render(view) =~ "Wallet connected"
    end

    test "events from other workspaces are ignored", %{conn: conn} do
      # Create a separate workspace's event.
      {:ok, other_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "other-ws-#{System.unique_integer([:positive])}",
          name: "Other workspace"
        })

      foreign =
        audit_event(
          event_type: "wallet_binding.verified",
          subject_type: "wallet_binding",
          subject_id: Ecto.UUID.generate(),
          actor: :user,
          workspace_id: other_ws.id,
          after_ref: %{"address" => "0xff0000112233445566778899aabbccddeeff1122"}
        )

      {:ok, view, _html} = live(conn, "/")

      Bank.Runtime.PubSub.broadcast(
        Bank.Runtime.PubSub.audit_stream(),
        %{
          topic: :audit_stream,
          event: :appended,
          at: DateTime.utc_now(),
          payload: %{
            id: foreign.id,
            event_type: foreign.event_type,
            subject_type: foreign.subject_type,
            subject_id: foreign.subject_id,
            correlation_id: foreign.correlation_id,
            ts: foreign.ts
          }
        }
      )

      refute render(view) =~ "Wallet connected"
    end
  end

  describe "BankWeb.AgentActivityLive empty state" do
    test "renders 'Nothing here yet.' when the workspace has no audit rows",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/activity")

      assert html =~ "Nothing here yet."
      # Same negative lock as the strip — full timeline must not show
      # any of the old hardcoded seed rows.
      refute html =~ "Permission ready to install"
      refute html =~ "Faucet drip received"
    end
  end

  describe "BankWeb.AgentActivityLive filter chips" do
    setup do
      executed =
        audit_event(
          event_type: "execution.confirmed",
          subject_type: "execution_plan",
          subject_id: Ecto.UUID.generate(),
          actor: :runtime,
          after_ref: %{"network" => "base-sepolia"}
        )

      blocked =
        audit_event(
          event_type: "execution.reverted",
          subject_type: "execution_plan",
          subject_id: Ecto.UUID.generate(),
          actor: :runtime,
          after_ref: %{"reason" => "insufficient funds"}
        )

      wallet =
        audit_event(
          event_type: "wallet_binding.verified",
          subject_type: "wallet_binding",
          subject_id: Ecto.UUID.generate(),
          actor: :user,
          after_ref: %{"address" => "0x1234567890abcdef1234567890abcdef12345678"}
        )

      %{executed: executed, blocked: blocked, wallet: wallet}
    end

    test "All filter shows every event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/activity")
      view |> element("button[phx-value-id=\"all\"]") |> render_click()
      html = render(view)

      assert html =~ "Transaction confirmed"
      assert html =~ "Transaction reverted"
      assert html =~ "Wallet connected"
    end

    test "Executed filter keeps only success outcomes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/activity")
      view |> element("button[phx-value-id=\"executed\"]") |> render_click()
      html = render(view)

      assert html =~ "Transaction confirmed"
      assert html =~ "Wallet connected"
      refute html =~ "Transaction reverted"
    end

    test "Blocked filter keeps only blocked / failed outcomes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/activity")
      view |> element("button[phx-value-id=\"blocked\"]") |> render_click()
      html = render(view)

      assert html =~ "Transaction reverted"
      refute html =~ "Transaction confirmed"
      refute html =~ "Wallet connected"
    end

    test "Permission filter keeps wallet_binding + delegation events",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/activity")
      view |> element("button[phx-value-id=\"permission\"]") |> render_click()
      html = render(view)

      assert html =~ "Wallet connected"
      refute html =~ "Transaction confirmed"
      refute html =~ "Transaction reverted"
    end
  end

  describe "Bank.Audit.ActivityView" do
    test "wallet_binding.verified renders as a wallet :note" do
      event = %AuditEvent{
        id: Ecto.UUID.generate(),
        ts: DateTime.utc_now(),
        event_type: "wallet_binding.verified",
        subject_type: "wallet_binding",
        subject_id: "wb-1",
        after_ref: %{"address" => "0x7a2f00112233445566778899aabbccddeeff1122"}
      }

      assert %{
               kind: "wallet",
               status: "note",
               title: "Wallet connected",
               reason: "Base Sepolia · 0x7a2f…1122"
             } = ActivityView.render(event)
    end

    test "wallet_binding.failed renders as wallet :failed with the reason" do
      event = %AuditEvent{
        id: Ecto.UUID.generate(),
        ts: DateTime.utc_now(),
        event_type: "wallet_binding.failed",
        subject_type: "wallet_binding",
        subject_id: "wb-2",
        after_ref: %{"reason" => "user rejected"}
      }

      assert %{
               kind: "wallet",
               status: "failed",
               title: "Wallet connect failed",
               reason: "user rejected"
             } = ActivityView.render(event)
    end

    test "delegation.install_confirmed_onchain renders as :installed" do
      event = %AuditEvent{
        id: Ecto.UUID.generate(),
        ts: DateTime.utc_now(),
        event_type: "delegation.install_confirmed_onchain",
        subject_type: "delegation",
        subject_id: "d-1"
      }

      assert %{
               kind: "permission",
               status: "installed",
               title: "Permission installed",
               reason: "Ready to use"
             } = ActivityView.render(event)
    end

    test "delegation.state_changed -> :revoked emits a revoked entry" do
      event = %AuditEvent{
        id: Ecto.UUID.generate(),
        ts: DateTime.utc_now(),
        event_type: "delegation.state_changed",
        subject_type: "delegation",
        subject_id: "d-2",
        after_ref: %{"state" => "revoked", "reason" => "operator revoked"}
      }

      assert %{
               kind: "permission",
               status: "revoked",
               title: "Permission revoked",
               reason: "operator revoked"
             } = ActivityView.render(event)
    end

    test "intent.submitted renders as :pending intent" do
      event = %AuditEvent{
        id: Ecto.UUID.generate(),
        ts: DateTime.utc_now(),
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: "i-1",
        after_ref: %{"kind" => "swap"}
      }

      assert %{
               kind: "intent",
               status: "pending",
               title: "Intent submitted",
               reason: "Kind: swap"
             } = ActivityView.render(event)
    end

    test "intent.state_changed -> :executed surfaces tx_hash" do
      event = %AuditEvent{
        id: Ecto.UUID.generate(),
        ts: DateTime.utc_now(),
        event_type: "intent.state_changed",
        subject_type: "agent_intent",
        subject_id: "i-2",
        after_ref: %{"state" => "executed", "tx_hash" => "0xdeadbeef0011223344556677889900aabbccddee"}
      }

      assert %{
               kind: "intent",
               status: "executed",
               title: "Intent executed",
               tx_hash: "0xdeadbeef0011223344556677889900aabbccddee"
             } = ActivityView.render(event)
    end

    test "execution.confirmed surfaces tx_hash and a network reason" do
      event = %AuditEvent{
        id: Ecto.UUID.generate(),
        ts: DateTime.utc_now(),
        event_type: "execution.confirmed",
        subject_type: "execution_plan",
        subject_id: "p-1",
        after_ref: %{
          "network" => "base-sepolia",
          "tx_hash" => "0xfeedface0011223344556677889900aabbccddee"
        }
      }

      assert %{
               kind: "execution",
               status: "executed",
               title: "Transaction confirmed",
               tx_hash: "0xfeedface0011223344556677889900aabbccddee"
             } = ActivityView.render(event)
    end

    test "decision.decided -> approval_required surfaces needs-approval" do
      event = %AuditEvent{
        id: Ecto.UUID.generate(),
        ts: DateTime.utc_now(),
        event_type: "decision.decided",
        subject_type: "decision_envelope",
        subject_id: "de-1",
        after_ref: %{"outcome" => "approval_required", "reason" => "over per-trade limit"}
      }

      assert %{
               kind: "intent",
               status: "needs-approval",
               title: "Approval needed",
               reason: "over per-trade limit"
             } = ActivityView.render(event)
    end

    test "unknown event_type falls back to :system :note with the type as title" do
      event = %AuditEvent{
        id: Ecto.UUID.generate(),
        ts: DateTime.utc_now(),
        event_type: "exotic.never_seen",
        subject_type: "weirdo",
        subject_id: "w-1"
      }

      assert %{
               kind: "system",
               status: "note",
               title: "exotic.never_seen",
               reason: nil
             } = ActivityView.render(event)
    end

    test "humanize/1 renders coarse buckets" do
      now = DateTime.utc_now()

      assert ActivityView.humanize(now) == "just now"
      assert ActivityView.humanize(DateTime.add(now, -120, :second)) == "2 min ago"
      assert ActivityView.humanize(DateTime.add(now, -7200, :second)) == "2 hr ago"
      assert ActivityView.humanize(DateTime.add(now, -2 * 86_400, :second)) == "2 d ago"
    end

    test "render/1 maps a list" do
      events =
        for type <- ["wallet_binding.verified", "delegation.install_confirmed_onchain"] do
          %AuditEvent{
            id: Ecto.UUID.generate(),
            ts: DateTime.utc_now(),
            event_type: type,
            subject_type: "x",
            subject_id: "x-1"
          }
        end

      assert [%{kind: "wallet"}, %{kind: "permission"}] = ActivityView.render(events)
    end
  end
end
