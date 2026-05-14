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

  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Delegations.Delegation
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime.PubSub, as: RuntimePubSub
  alias Bank.SessionPermissions
  alias Bank.WalletBindings.WalletBinding

  describe "rendering — locked state (no permission)" do
    setup :register_and_log_in_user

    test "renders the test card with the locked notice", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "04 — Test"
      assert html =~ "Run test intent"

      # P0 wallet-state-divergence: when no wallet is connected, the
      # Run button is locked behind the wallet rather than the
      # permission — the operator needs to connect a wallet FIRST,
      # then install permission. The wallet-lock banner takes
      # precedence over the install-permission banner so the
      # operator follows the correct order. Either banner counts as
      # "locked"; we assert at least one.
      assert html =~ "Connect your wallet to run a test intent." or
               html =~ "Install agent permission to run a test intent."
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

      # Click Approve once. The LiveView passes the smart_account_id
      # from its active wallet-bound delegation, so approval can
      # dispatch without asking the global resolver to guess.
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

    test "Approve once dispatches through the active wallet-bound delegation even when another delegation exists",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      %{delegation: delegation} = activate_permission!(view)

      workspace_id = Process.get(:bank_test_workspace_id)
      _other_delegation = insert_delegation!(workspace_id, nil, "sa-other-active", :active)

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

      view |> element("button", "Approve once") |> render_click()

      successor =
        Repo.one!(
          from e in DecisionEnvelope,
            where: e.intent_id == ^intent.id and e.supersedes_id == ^envelope.id
        )

      plan =
        Repo.one!(
          from p in ExecutionPlan,
            where: p.decision_id == ^successor.id and p.active == true
        )

      assert plan.smart_account_id == delegation.smart_account_id

      html = render(view)
      refute html =~ "ambiguous_executable_account"
      refute html =~ "Approved · dispatch held"
    end

    test "Approve once for swap mode fails closed when no executable 0x route is available",
         %{conn: conn} do
      # `base-sepolia` is the sandbox chain the test intent uses,
      # but `Bank.Stablecoins.Registry` and the live 0x provider
      # both only carry mainnet entries (ethereum/base/arbitrum/
      # optimism/polygon). The resolver therefore rejects the
      # pre-flight quote at `QuoteRequest.build/1` with
      # `:unsupported_source_chain`, the LiveView flips IntentResult
      # to a terminal failure, AND crucially never calls
      # `Bank.Decisions.approve/2` — so no successor envelope and
      # no execution plan are created.
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button[phx-value-mode=\"swap\"]") |> render_click()
      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()
      assert intent.kind == :swap

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          state: :pending_decision,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      broadcast_decision(intent.id, envelope.id, :approval_required)

      view |> element("button", "Approve once") |> render_click()

      refute Repo.exists?(from e in DecisionEnvelope, where: e.supersedes_id == ^envelope.id)

      refute Repo.exists?(from p in ExecutionPlan, where: p.intent_id == ^intent.id)

      html = render(view)
      assert html =~ "Cannot resolve swap route"
      refute html =~ "0xdeadbeef"
      refute html =~ "swap_route_missing"
      refute html =~ "Approved · dispatch held"
    end

    test "Approve once successful dispatch flips IntentResult OFF needs-approval immediately (no stale Approve button, dispatching copy, execution_plan_id stored)",
         %{conn: conn} do
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

      # Approve must be visible BEFORE the click and gone AFTER.
      assert has_element?(view, "button", "Approve once")

      view |> element("button", "Approve once") |> render_click()

      # The IntentResult banner is now in the `dispatching` state
      # — the prior "needs-approval" copy is GONE so the operator
      # never sees a stale Approve button after a successful approve.
      assert has_element?(view, "#test-intent-result[data-state='dispatching']")
      refute has_element?(view, "#test-intent-result[data-state='needs-approval']")
      refute has_element?(view, "button", "Approve once")

      html = render(view)
      assert html =~ "Approved · dispatching"
      assert html =~ "Approval accepted"

      # The execution_plan_id is stored on the result so the
      # details panel surfaces it. Persisted plan exists in DB.
      successor =
        Repo.one!(
          from e in DecisionEnvelope,
            where: e.intent_id == ^intent.id and e.supersedes_id == ^envelope.id
        )

      plan =
        Repo.one!(
          from p in ExecutionPlan,
            where: p.decision_id == ^successor.id and p.active == true
        )

      view |> element("#test-intent-view-details") |> render_click()
      panel_html = view |> element("#test-intent-details-panel") |> render()
      assert panel_html =~ plan.id
      assert panel_html =~ successor.id
    end

    test "Approve once successful dispatch makes a repeat approve impossible (button gone, click is no-op)",
         %{conn: conn} do
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

      view |> element("button", "Approve once") |> render_click()

      # A second approve click can't be issued via the UI — the
      # button is no longer in the DOM. Asserting via `has_element?`
      # is the LiveView-honest way to prove this; raw HTML checks
      # could miss class-only changes.
      refute has_element?(view, "button", "Approve once")

      # Defense in depth: even if some external actor synthesised an
      # `intent:approve` event the LiveView still has no
      # `decision_envelope_id` matching an `:approval_required` row
      # in `last_result` (it's `state: "dispatching"` now), so the
      # handler short-circuits to the catch-all no-op.
      one_successor_count =
        Repo.aggregate(
          from(e in DecisionEnvelope, where: e.intent_id == ^intent.id and e.current == true),
          :count
        )

      assert one_successor_count == 1
    end

    test "Approve once landing on :held renders an amber 'Approved · dispatch held' result, not a success",
         %{conn: conn} do
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

      # Force `Bank.Decisions.approve/2`'s dispatch branch to return
      # `{:held, :runtime_paused}` by globally pausing the runtime
      # right before the approve click. The approval itself still
      # succeeds (the successor envelope is written); only the
      # dispatch hops onto the held path. Resume on test exit so
      # other tests don't observe the pause.
      {:ok, _} = Bank.Security.pause(:global, actor: :user, actor_id: nil)
      on_exit(fn -> Bank.Security.resume(:global, actor: :user, actor_id: nil) end)

      view |> element("button", "Approve once") |> render_click()

      html = render(view)

      # Held UX copy: amber, not success.
      assert html =~ "Approved · dispatch held"
      assert html =~ "Approved · awaiting dispatch"
      # The held reason is included so the operator can act on it.
      assert html =~ "runtime_paused"

      # The success copy ("Intent executed") must NOT appear.
      refute html =~ "Intent executed"
      # Held results render in the warn/amber slot — not the green "ok" slot.
      refute html =~ "intent-result--ok"
      assert html =~ "intent-result--warn"

      # The approval is already in the past (the successor envelope
      # exists). The UI must not invite another approve click.
      refute has_element?(view, "button", "Approve once")
    end
  end

  describe "intent:run — preconditions guard" do
    setup :register_and_log_in_user

    test "wallet disconnected → intent:run is a no-op (no AgentIntent row created)", %{conn: conn} do
      before_count = Repo.aggregate(AgentIntent, :count)

      {:ok, view, _} = live(conn, "/")
      # No `activate_permission!` — the LiveView mounts with no
      # binding, no delegation, permission == :not_installed. We
      # bypass the disabled Run button by sending the event directly
      # the way a stale browser tab might.
      render_hook(view, "intent:run", %{})

      assert Repo.aggregate(AgentIntent, :count) == before_count
    end

    test "permission :revoking → intent:run is a no-op", %{conn: conn} do
      before_count = Repo.aggregate(AgentIntent, :count)

      {:ok, view, _} = live(conn, "/")
      %{delegation: delegation} = activate_permission!(view)

      # Flip the seeded `:active` delegation to `:revoking` and force
      # a DB re-read. With state == :revoking the intent:run guard
      # falls through to the no-op branch.
      {:ok, _} =
        delegation
        |> Ecto.Changeset.change(state: :revoking)
        |> Repo.update()

      send(view.pid, :_test_reload_state)
      _ = render(view)

      render_hook(view, "intent:run", %{})

      assert Repo.aggregate(AgentIntent, :count) == before_count
    end

    test "smart account mismatch → intent:run is a no-op", %{conn: conn} do
      before_count = Repo.aggregate(AgentIntent, :count)

      {:ok, view, _} = live(conn, "/")
      %{delegation: delegation} = activate_permission!(view)

      # Tamper with the delegation's smart_account_id so it no longer
      # matches `compute_smart_account_id(binding)`. The preconditions
      # guard catches the mismatch and refuses to submit.
      {:ok, _} =
        delegation
        |> Ecto.Changeset.change(smart_account_id: "sa_wb_tampered")
        |> Repo.update()

      send(view.pid, :_test_reload_state)
      _ = render(view)

      render_hook(view, "intent:run", %{})

      assert Repo.aggregate(AgentIntent, :count) == before_count
    end
  end

  describe "intent:run — 30s timeout watchdog (:slow state)" do
    setup :register_and_log_in_user

    test "{:intent_timeout, intent_id} flips to :slow with a 'Still processing' result", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()

      # Simulate the 30s timer firing (we don't actually wait 30s).
      send(view.pid, {:intent_timeout, intent.id})
      html = render(view)

      assert html =~ "Still processing"
      # The Run button must stay disabled while :slow — there's still
      # an in-flight intent and a re-click would race the late event.
      assert view |> element("button[phx-click=\"intent:run\"]") |> render() =~ "disabled"
    end

    test "a late :decision_updated overwrites :slow with the real outcome", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()

      # Trip the timeout first.
      send(view.pid, {:intent_timeout, intent.id})
      assert render(view) =~ "Still processing"

      # The decision pipeline finally caught up — broadcast a
      # :approval_required outcome and assert the slow copy is
      # gone, replaced by the needs-approval variant.
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
      refute html =~ "Still processing"
      assert html =~ "Needs your approval"
      assert html =~ "Per-trade limit exceeded."
    end

    test "a stale :intent_timeout for a different intent is a no-op", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()

      # Send a timeout for an unrelated intent id — the guard checks
      # `active_intent_id == intent_id` so the stale message is
      # silently dropped without flipping to :slow.
      send(view.pid, {:intent_timeout, Ecto.UUID.generate()})

      refute render(view) =~ "Still processing"
    end

    # Regression for the manual-test bug: backend reached `:block`
    # but the LiveView raced the `:decision_updated` broadcast (Oban
    # worker finished synchronously, faster than
    # `RuntimePubSub.subscribe`) and the UI stayed on "Running…"
    # until the 30s watchdog flipped to "Still processing" — a
    # non-terminal copy even though the row was already terminal.
    # The watchdog now reads the DB first and applies the real
    # outcome.
    test "{:intent_timeout, ...} reconciles from DB and renders Blocked when an envelope already exists",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()

      _envelope =
        decision_envelope(
          intent: intent,
          outcome: :block,
          state: :decided,
          current: true,
          reasons: %{
            "items" => [
              %{
                "code" => "policy_malformed_params",
                "message" =>
                  "rule params failed validation: `tier` must be one of 'auto', 'manual', 'block'"
              }
            ]
          }
        )

      send(view.pid, {:intent_timeout, intent.id})

      html = render(view)
      refute html =~ "Still processing"
      assert has_element?(view, "#test-intent-result[data-state='blocked']")
      assert html =~ "Intent blocked"
      assert html =~ "`tier` must be one of"
    end

    test "{:intent_reconcile, ...} applies a fast-decided block without waiting for the watchdog",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button", "Run test intent") |> render_click()
      intent = latest_intent()

      _envelope =
        decision_envelope(
          intent: intent,
          outcome: :block,
          state: :decided,
          current: true,
          reasons: %{
            "items" => [
              %{"code" => "chain_not_allowed", "message" => "chain `base-sepolia` not allowed"}
            ]
          }
        )

      send(view.pid, {:intent_reconcile, intent.id})

      html = render(view)
      refute html =~ "Running…"
      refute html =~ "Still processing"
      assert html =~ "Intent blocked"
      assert html =~ "chain `base-sepolia` not allowed"
    end
  end

  describe "View details — inline expand panel" do
    setup :register_and_log_in_user

    test "the View details control is a real button and toggles the details panel with reason code + message",
         %{conn: conn} do
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
            "items" => [
              %{
                "code" => "policy_malformed_params",
                "message" =>
                  "rule params failed validation: `tier` must be one of 'auto', 'manual', 'block'"
              }
            ]
          }
        )

      broadcast_decision(intent.id, envelope.id, :block)

      # Closed by default — panel not in the DOM yet.
      refute has_element?(view, "#test-intent-details-panel")

      # View-details exists and is a real <button> (not a dead anchor).
      assert has_element?(
               view,
               "button#test-intent-view-details[phx-click='intent:toggle_details']"
             )

      view |> element("#test-intent-view-details") |> render_click()

      assert has_element?(view, "#test-intent-details-panel")
      panel_html = view |> element("#test-intent-details-panel") |> render()
      assert panel_html =~ "policy_malformed_params"
      assert panel_html =~ "`tier` must be one of"

      # Toggle again closes the panel.
      view |> element("#test-intent-view-details") |> render_click()
      refute has_element?(view, "#test-intent-details-panel")
    end
  end

  describe "Preview-only Run guard" do
    setup :register_and_log_in_user

    test "Swap mode + non-executable preview disables Run and surfaces the preview-only banner",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button[phx-value-mode=\"swap\"]") |> render_click()

      send(view.pid, {:_test_set_preview, preview_for(:quote_only_odos)})
      _ = render(view)

      assert has_element?(view, "#test-intent-preview-only")
      assert has_element?(view, "#test-intent-run[disabled]")

      html = render(view)
      assert html =~ "preview-only"
      assert html =~ "0x route"
      assert html =~ "odos"
    end

    test "Swap mode + executable preview keeps Run enabled and hides the preview-only banner",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      view |> element("button[phx-value-mode=\"swap\"]") |> render_click()

      send(view.pid, {:_test_set_preview, preview_for(:executable_zerox)})
      _ = render(view)

      refute has_element?(view, "#test-intent-preview-only")
      refute view |> element("#test-intent-run") |> render() =~ "disabled"
    end

    test "Hold mode is not gated on preview executability (advisory-only contract preserved)",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      # Default mode is "hold". Even with a non-executable preview,
      # Run must stay enabled — Hold doesn't depend on a swap route.
      send(view.pid, {:_test_set_preview, preview_for(:quote_only_odos)})
      _ = render(view)

      refute has_element?(view, "#test-intent-preview-only")
      refute view |> element("#test-intent-run") |> render() =~ "disabled"
    end
  end

  describe "real 0x quote preview (swap mode, read-only)" do
    setup :register_and_log_in_user

    test "swap mode renders the Fetch real quote button", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)

      # Hold mode (default) must NOT render the preview block.
      refute has_element?(view, "#test-intent-real-quote")
      refute has_element?(view, "#test-intent-preview-real")

      # Switch to swap → preview block + button appear.
      view |> element("button[phx-value-mode=\"swap\"]") |> render_click()
      html = render(view)
      assert html =~ ~s(id="test-intent-real-quote")
      assert html =~ ~s(id="test-intent-preview-real")
      assert html =~ "Fetch real quote"
    end

    test "no wallet binding → no_wallet_binding reason with operator-friendly hint",
         %{conn: conn} do
      # Intentionally do NOT call activate_permission! — no binding row.
      {:ok, view, _} = live(conn, "/")

      view |> element("button[phx-value-mode=\"swap\"]") |> render_click()
      view |> element("#test-intent-preview-real") |> render_click()

      html = render(view)
      assert html =~ ~s(id="test-intent-real-quote-panel")
      assert html =~ ~s(data-state="error")
      assert html =~ "preview:no_wallet_binding"
      assert html =~ "Connect your wallet first"
    end

    test "all providers report missing api key → preview:missing_api_key reason",
         %{conn: conn} do
      # Force ZeroX + OneInch into the missing-key path. This is the
      # exact failure mode an operator hits when they forget to export
      # `ZEROX_API_KEY` before `mix phx.server`: every configured
      # provider returns `{:provider_error, %{reason: "missing_api_key"}}`
      # and `RouteSelector` collapses them into
      # `{:no_quotes, [...]}`. The handler must collapse THAT into a
      # stable `preview:missing_api_key` code so the UI can render a
      # single, actionable hint instead of the nested term.
      zerox_orig = Application.get_env(:bank, Bank.Stablecoins.Providers.ZeroX)
      oneinch_orig = Application.get_env(:bank, Bank.Stablecoins.Providers.OneInch)

      on_exit(fn ->
        Application.put_env(:bank, Bank.Stablecoins.Providers.ZeroX, zerox_orig)
        Application.put_env(:bank, Bank.Stablecoins.Providers.OneInch, oneinch_orig)
      end)

      Application.put_env(
        :bank,
        Bank.Stablecoins.Providers.ZeroX,
        Keyword.put(zerox_orig, :api_key, nil)
      )

      Application.put_env(
        :bank,
        Bank.Stablecoins.Providers.OneInch,
        Keyword.put(oneinch_orig, :api_key, nil)
      )

      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)
      view |> element("button[phx-value-mode=\"swap\"]") |> render_click()

      view |> element("#test-intent-preview-real") |> render_click()

      html = render(view)
      assert html =~ ~s(id="test-intent-real-quote-panel")
      assert html =~ ~s(data-state="error")
      assert html =~ "preview:missing_api_key"
      assert html =~ "Server has no 0x API key configured"
      assert html =~ "ZEROX_API_KEY"
    end

    test "happy path: injected ok preview renders the quote panel with route data",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      activate_permission!(view)
      view |> element("button[phx-value-mode=\"swap\"]") |> render_click()

      route = %{
        chain: "base",
        chain_id: 8453,
        source_asset: "USDC",
        source_token_address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        destination_asset: "USDT",
        destination_token_address: "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2",
        input_amount: Decimal.new("10"),
        expected_output_amount: Decimal.new("9.990573"),
        minimum_output_amount: Decimal.new("9.941049"),
        slippage_bps: 50,
        spender: "0x000000000022d473030f116ddee9f6b43ac78ba3",
        swap_target_contract: "0x7747f8d2a76bd6345cc29622a946a929647f2359",
        calldata: "0x" <> String.duplicate("ab", 100),
        value: Decimal.new(0),
        route_provider: "zerox",
        quote_timestamp: ~U[2026-05-12 16:40:42Z],
        deadline: ~U[2026-05-12 16:50:42Z]
      }

      send(
        view.pid,
        {:_test_set_real_quote_preview,
         %{state: :ok, route: route, fetched_at: ~U[2026-05-12 16:40:42Z]}}
      )

      html = render(view)
      assert html =~ ~s(id="test-intent-real-quote-panel")
      assert html =~ ~s(data-state="ok")
      assert html =~ "USDC"
      assert html =~ "USDT"
      assert html =~ "9.990573"
      assert html =~ "9.941049"
      assert html =~ "0.50% (50 bps)"
      assert html =~ "zerox"
      assert html =~ "base (8453)"
      assert html =~ "100 bytes"
      assert html =~ "Refresh quote"
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────────

  # Drive the LiveView's permission state machine into `:active` by
  # seeding the same DB-truth a real install flow would persist:
  # a verified wallet binding + an `:active` delegation whose
  # `smart_account_id` matches `compute_smart_account_id(binding)`.
  # The hardened `intent:run` preconditions check the binding +
  # delegation assigns directly (defense-in-depth on top of the
  # `permission == :active` render gate), so the test fixture has
  # to mirror the production state machine — the legacy
  # `:permission_signed` shortcut alone is no longer enough.
  defp activate_permission!(view) do
    workspace_id = Process.get(:bank_test_workspace_id)
    user_id = current_user_id_for_workspace(workspace_id)

    binding = verified_binding(workspace_id, user_id)
    sa_id = SessionPermissions.compute_smart_account_id(binding)
    delegation = insert_delegation!(workspace_id, binding.id, sa_id, :active)

    # Mount has already run by the time this helper is called, so
    # the seeded rows aren't visible to the LiveView yet. Send the
    # test-only `:_test_reload_state` message to force a DB re-read
    # (mirrors what `wallet_connect:verify` +
    # `session_permission_install:confirmed` do on the real path).
    send(view.pid, :_test_reload_state)
    _ = render(view)

    # P0 wallet-state-divergence: `intent:run` now requires
    # `:wallet == :connected`, which is the composite of DB binding
    # + live browser provider exposing the bound account. The DB
    # side is satisfied by the rows above; simulate the JS hook's
    # `pushBrowserStatus` so the LiveView learns the browser is
    # exposing the bound EOA on Base Sepolia. Without this push the
    # wallet would land in `:browser_disconnected` and the
    # hardened `intent:run` guard would silently no-op every click.
    render_hook(view, "wallet_connect:browser_status", %{
      "status" => "exposed_account",
      "accounts" => [binding.address],
      "chain_id" => 84_532,
      "permissions_count" => 1
    })

    %{binding: binding, delegation: delegation}
  end

  # Look up the user_id of the workspace's lone membership.
  # `register_and_log_in_user` creates exactly one membership per
  # test, so there's no ambiguity.
  defp current_user_id_for_workspace(workspace_id) do
    Repo.one(
      from m in Bank.Workspaces.Membership,
        where: m.workspace_id == ^workspace_id,
        select: m.user_id,
        limit: 1
    )
  end

  defp verified_binding(workspace_id, user_id) do
    nonce = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    now = DateTime.utc_now()
    expires = DateTime.add(now, 300, :second)
    addr = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    {:ok, binding} =
      Repo.insert(%WalletBinding{
        workspace_id: workspace_id,
        user_id: user_id,
        address: addr,
        chain_id: 84_532,
        nonce: nonce,
        challenge_message: "test binding",
        expires_at: expires,
        verified_at: now
      })

    binding
  end

  defp insert_delegation!(workspace_id, binding_id, smart_account_id, state) do
    attrs = %{
      smart_account_id: smart_account_id,
      delegation_id: "del-#{System.unique_integer([:positive])}",
      state: state,
      chain: "base-sepolia",
      scope: SessionPermissions.Scope.default(),
      workspace_id: workspace_id,
      binding_id: binding_id,
      root_validator_owner: "user",
      install_userop_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    }

    {:ok, delegation} =
      %Delegation{}
      |> Delegation.changeset(attrs)
      |> Repo.insert()

    delegation
  end

  defp latest_intent do
    Repo.one(from i in AgentIntent, order_by: [desc: i.inserted_at], limit: 1)
  end

  defp preview_for(:executable_zerox) do
    %Bank.Quotes.Preview{
      expected_output: Decimal.new("9.95"),
      slippage_bps: 50,
      estimated_fee: nil,
      route: %{"provider_id" => "zerox", "executable?" => true}
    }
  end

  defp preview_for(:quote_only_odos) do
    %Bank.Quotes.Preview{
      expected_output: Decimal.new("9.94"),
      slippage_bps: 50,
      estimated_fee: nil,
      route: %{"provider_id" => "odos", "executable?" => false}
    }
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
