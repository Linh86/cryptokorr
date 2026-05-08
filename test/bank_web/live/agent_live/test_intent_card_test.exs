defmodule BankWeb.AgentLive.TestIntentCardTest do
  @moduledoc """
  Tests for the test-intent section of `BankWeb.AgentLive`. Covers
  rendering, the `intent:run` → `Bank.Intents.submit/2` path, the
  PubSub-driven IntentResult state machine, and the `intent:approve`
  → `Bank.Decisions.approve/2` path with role gating.
  """
  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bank.Fixtures
  import Ecto.Query

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime.PubSub, as: RuntimePubSub

  describe "rendering — locked state (no permission)" do
    setup :register_and_log_in_user

    test "renders the test card with the locked notice", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "04 — Test"
      assert html =~ "Run test intent"
      assert html =~ "Install agent permission to run a test intent."
    end

    test "the Run button is disabled while locked", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      # The Run button is disabled while permission is not :active.
      assert view |> element("button[phx-click=\"intent:run\"]") |> render() =~ "disabled"
    end
  end

  describe "rendering — example copy per mode" do
    setup :register_and_log_in_user

    test "Hold mode shows the no-op example", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      # default mode is "hold"
      html = render(view)
      assert html =~ "No-op intent"
    end

    test "Swap mode shows the swap example after switching", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      html = view |> element("button[phx-value-mode=\"swap\"]") |> render_click()
      # The mode card sub-copy switches to the swap example.
      assert html =~ "Swap"
    end
  end

  describe "intent:run — submit happy path" do
    setup :register_and_log_in_user

    test "submits an AgentIntent on Base Sepolia and flips to running", %{conn: conn} do
      before_count = Repo.aggregate(AgentIntent, :count)

      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()

      # UI flipped to "Running…" because submit succeeded and we're now
      # waiting on PubSub events from the decision pipeline.
      assert render(view) =~ "Running…"

      # A real AgentIntent row was inserted, on base-sepolia (sandbox-only).
      assert Repo.aggregate(AgentIntent, :count) == before_count + 1

      intent = latest_intent()

      assert intent.chain == "base-sepolia"
      assert intent.asset == "USDC"
      assert intent.kind == :transfer
      assert intent.workspace_id != nil
    end

    test "earn mode submits a defi_yield_deposit on base-sepolia", %{conn: conn} do
      before_count = Repo.aggregate(AgentIntent, :count)

      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button[phx-value-mode=\"earn\"]") |> render_click()
      view |> element("button", "Run test intent") |> render_click()

      assert Repo.aggregate(AgentIntent, :count) == before_count + 1
      intent = latest_intent()
      assert intent.kind == :defi_yield_deposit
      assert intent.chain == "base-sepolia"
    end
  end

  describe "PubSub — decision_updated transitions" do
    setup :register_and_log_in_user

    test ":approval_required flips to needs-approval and surfaces the reason copy", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          state: :pending_decision,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z],
          reasons: %{
            "items" => [
              %{"code" => "per_trade_limit_exceeded", "message" => "Per-trade limit exceeded."}
            ]
          }
        )

      broadcast_decision(intent.id, envelope.id, :approval_required)

      html = render(view)
      assert html =~ "Needs your approval"
      assert html =~ "Approve once"
      assert html =~ "Per-trade limit exceeded."
    end

    test ":hold flips to blocked", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :hold,
          state: :pending_decision,
          current: true,
          reasons: %{
            "items" => [%{"code" => "trust_pending", "message" => "Trust signals pending."}]
          }
        )

      broadcast_decision(intent.id, envelope.id, :hold)

      html = render(view)
      assert html =~ "Intent blocked"
      assert html =~ "Trust signals pending."
    end

    test ":block flips to blocked", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :block,
          state: :decided,
          current: true,
          reasons: %{
            "items" => [%{"code" => "policy_blocked", "message" => "Target outside scope."}]
          }
        )

      broadcast_decision(intent.id, envelope.id, :block)

      html = render(view)
      assert html =~ "Intent blocked"
      assert html =~ "Target outside scope."
    end
  end

  describe "PubSub — execution_updated transitions" do
    setup :register_and_log_in_user

    test ":confirmed flips to executed and renders the truncated tx hash", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()

      tx = "0x" <> String.duplicate("a", 64)

      RuntimePubSub.broadcast(
        RuntimePubSub.intent(intent.id),
        %{
          topic: :intent_lifecycle,
          event: :execution_updated,
          intent_id: intent.id,
          at: DateTime.utc_now(),
          payload: %{
            execution_plan_id: Ecto.UUID.generate(),
            prior_status: :pending_confirmation,
            execution_status: :confirmed,
            final_outcome: :confirmed,
            tx_refs: [tx]
          }
        }
      )

      html = render(view)
      assert html =~ "Intent executed"
      # Short form: "0xaaaa…aaaa" — first 6 chars of the hash + ellipsis +
      # last 4. We only assert on the leading slice to stay tolerant of
      # exact ellipsis byte representation in the rendered HTML.
      assert html =~ "0xaaaa"
    end

    test ":reverted flips to failed", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()

      RuntimePubSub.broadcast(
        RuntimePubSub.intent(intent.id),
        %{
          topic: :intent_lifecycle,
          event: :execution_updated,
          intent_id: intent.id,
          at: DateTime.utc_now(),
          payload: %{
            execution_plan_id: Ecto.UUID.generate(),
            prior_status: :broadcasting,
            execution_status: :reverted,
            final_outcome: :reverted,
            tx_refs: []
          }
        }
      )

      html = render(view)
      assert html =~ "Intent failed"
      assert html =~ "Execution reverted."
    end
  end

  # Role gate moved up to the live_session: viewers redirect to
  # /unauthorized at mount, so they never see the Approve button.
  # The button-disabled defense-in-depth in test_intent_card.ex
  # stays put for safety, but the dedicated test was deleted in
  # the hardening sprint — the live_auth_rbac_test now pins viewer
  # rejection at the router level.

  describe "approve flow — operator path" do
    setup :register_and_log_in_user

    test "Approve once supersedes the envelope via Bank.Decisions.approve/2", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          state: :pending_decision,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      broadcast_decision(intent.id, envelope.id, :approval_required)

      # Click Approve once. With no active delegation the dispatch branch
      # returns `{:held, :no_executable_account}`; the LiveView surfaces
      # that as a flash but the approval itself succeeds — the prior
      # envelope is no longer current and a successor with outcome
      # `:auto_exec` exists.
      view |> element("button", "Approve once") |> render_click()

      reloaded_prior = Repo.get!(DecisionEnvelope, envelope.id)
      refute reloaded_prior.current

      successor =
        Repo.one(
          from e in DecisionEnvelope,
            where: e.intent_id == ^intent.id and e.supersedes_id == ^envelope.id
        )

      assert successor != nil
      assert successor.outcome == :auto_exec
      assert successor.current == true
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────────

  # Drive the LiveView's permission state machine into `:active` by
  # sending the same async message the real flow produces.
  # `handle_info(:permission_signed, ...)` flips permission to :active.
  # We bypass the wallet/install click chain because the test card only
  # gates on `permission == :active`; the wallet/install flow lives in
  # other agents' cards and is exercised in their tests.
  defp activate_permission!(view) do
    send(view.pid, :permission_signed)
    # Force a synchronous re-render so subsequent assertions see the
    # post-message state.
    _ = render(view)
    :ok
  end

  defp latest_intent do
    Repo.one(from i in AgentIntent, order_by: [desc: i.inserted_at], limit: 1)
  end

  defp broadcast_decision(intent_id, envelope_id, outcome) do
    RuntimePubSub.broadcast(
      RuntimePubSub.intent(intent_id),
      %{
        topic: :intent_lifecycle,
        event: :decision_updated,
        intent_id: intent_id,
        at: DateTime.utc_now(),
        payload: %{
          decision_envelope_id: envelope_id,
          outcome: outcome,
          risk_tier: :moderate
        }
      }
    )
  end
end
