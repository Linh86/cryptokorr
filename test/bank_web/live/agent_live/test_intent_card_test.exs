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

    test "Approve once landing on :held renders an amber 'Approved · dispatch held' result, not a success", %{conn: conn} do
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
      install_userop_hash:
        "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
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
