defmodule BankWeb.QueueLiveTest do
  @moduledoc """
  LiveView tests for the action queue page.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  alias Bank.Security.PauseState

  import Bank.Fixtures

  setup do
    PauseState.reset()
    :ok
  end

  # --- Mount / render -------------------------------------------------------

  describe "initial render — empty queue" do
    test "renders the queue page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ "Action Queue"
      assert html =~ "Decisions and executions requiring attention"
    end

    test "shows empty state when no items", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ ~s(id="empty-queue")
      assert html =~ "Queue is clear"
      assert html =~ "trust engine"
    end

    test "does not show section cards when empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      refute html =~ ~s(id="pending-approvals-section")
      refute html =~ ~s(id="held-actions-section")
      refute html =~ ~s(id="blocked-actions-section")
    end

    test "page has correct title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ "Action Queue"
    end
  end

  # --- Pending approvals ----------------------------------------------------

  describe "pending approvals" do
    setup do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          risk_tier: :moderate,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      %{intent: intent, envelope: envelope}
    end

    test "renders pending approvals section", %{conn: conn, envelope: envelope} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ ~s(id="pending-approvals-section")
      assert html =~ "Pending approvals"
      assert html =~ "Approval required"
      assert html =~ String.slice(envelope.id, 0, 8)
    end

    test "shows active approve/reject buttons wired to LiveView events", %{
      conn: conn,
      envelope: envelope
    } do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ "Approve"
      assert html =~ "Reject"
      assert html =~ ~s(id="approve-btn-#{envelope.id}")
      assert html =~ ~s(id="reject-btn-#{envelope.id}")
      refute html =~ "Approval backend not yet implemented"
    end

    test "shows risk tier", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ "Moderate"
    end

    test "shows approval expiry", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ "Expires in"
      assert html =~ "2030-01-01"
    end

    test "shows total items badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      # Total items > 0 so badge appears
      refute html =~ ~s(id="empty-queue")
    end

    test "expanded row shows a Download report link pointing at the #250 endpoint (#251)",
         %{conn: conn, envelope: envelope, intent: intent} do
      {:ok, view, _html} = live(conn, "/queue")

      # The "Details" expander reveals the intent-replay + report
      # links. Click it before asserting on the link's presence.
      view |> element("#details-btn-#{envelope.id}") |> render_click()

      assert has_element?(
               view,
               ~s(a#decision-report-link-#{envelope.id}[href="/audit/replay/#{intent.id}/report"]),
               "Download report"
             )

      assert has_element?(
               view,
               ~s(a#decision-report-link-#{envelope.id}[target="_blank"])
             )
    end
  end

  # --- Held actions ---------------------------------------------------------

  describe "held actions" do
    setup do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :hold,
          risk_tier: :elevated,
          current: true
        )

      %{intent: intent, envelope: envelope}
    end

    test "renders held actions section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ ~s(id="held-actions-section")
      assert html =~ "Held actions"
      assert html =~ "Held"
    end

    test "shows risk tier for held decision", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ "Elevated"
    end
  end

  # --- Blocked actions ------------------------------------------------------

  describe "blocked actions" do
    setup do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :block,
          risk_tier: :severe,
          current: true
        )

      %{intent: intent, envelope: envelope}
    end

    test "renders blocked actions section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ ~s(id="blocked-actions-section")
      assert html =~ "Blocked actions"
      assert html =~ "Blocked"
    end

    test "shows risk tier for blocked decision", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ "Severe"
    end
  end

  # --- Active executions ----------------------------------------------------

  describe "active executions" do
    setup do
      intent = agent_intent()
      decision = decision_envelope(intent: intent, current: true)
      plan = execution_plan(decision: decision, execution_status: :signing)

      %{intent: intent, plan: plan}
    end

    test "renders active executions section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ ~s(id="active-executions-section")
      assert html =~ "Active executions"
      assert html =~ "Signing"
    end

    test "shows execution status badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ "signing"
    end
  end

  # --- Mixed state ----------------------------------------------------------

  describe "mixed queue items" do
    setup do
      # Create one of each type
      i1 = agent_intent()

      _approval =
        decision_envelope(
          intent: i1,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      i2 = agent_intent()
      _held = decision_envelope(intent: i2, outcome: :hold, current: true)

      i3 = agent_intent()
      _blocked = decision_envelope(intent: i3, outcome: :block, current: true)

      :ok
    end

    test "renders all three sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ ~s(id="pending-approvals-section")
      assert html =~ ~s(id="held-actions-section")
      assert html =~ ~s(id="blocked-actions-section")
      refute html =~ ~s(id="empty-queue")
    end
  end

  # --- Events ---------------------------------------------------------------

  describe "refresh event" do
    test "reloads state and shows flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/queue")

      html = view |> element("button", "Refresh") |> render_click()

      assert html =~ "Queue refreshed"
    end
  end

  # --- Approve / reject actions ---------------------------------------------

  describe "approve action" do
    setup do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          risk_tier: :moderate,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      %{intent: intent, envelope: envelope}
    end

    test "clicking Approve records the decision and removes the row", %{
      conn: conn,
      envelope: envelope,
      intent: intent
    } do
      {:ok, view, _html} = live(conn, "/queue")

      html =
        view
        |> element("#approve-btn-" <> envelope.id)
        |> render_click()

      refute html =~ envelope.id
      # No delegation in this test setup -> dispatch is held; flash
      # carries the held-state hint pointing operators at /execute.
      assert html =~ "Approval recorded"
      assert html =~ "dispatch held"
      assert html =~ "no_executable_account"

      # DB state reflects the successor envelope.
      successor =
        Bank.Repo.get_by(Bank.Decisions.DecisionEnvelope, intent_id: intent.id, current: true)

      assert successor.outcome == :auto_exec
      assert successor.decided_by == :user
      assert successor.supersedes_id == envelope.id

      # Held: no active execution plan was created — operator must
      # resolve the gate (e.g. grant a delegation) and trigger
      # /v1/decisions/{id}/execute manually.
      assert is_nil(Bank.Decisions.active_plan_for(successor.id))
    end

    test "clicking Reject blocks the intent", %{
      conn: conn,
      envelope: envelope,
      intent: intent
    } do
      {:ok, view, _html} = live(conn, "/queue")

      html =
        view
        |> element("#reject-btn-" <> envelope.id)
        |> render_click()

      assert html =~ "rejected"

      successor =
        Bank.Repo.get_by(Bank.Decisions.DecisionEnvelope, intent_id: intent.id, current: true)

      assert successor.outcome == :block
      assert successor.decided_by == :user

      updated_intent = Bank.Repo.get!(Bank.Intents.AgentIntent, intent.id)
      assert updated_intent.state == :blocked
    end

    test "toggling details reveals and hides the context panel", %{
      conn: conn,
      envelope: envelope
    } do
      {:ok, view, html} = live(conn, "/queue")
      refute html =~ ~s(id="approval-details-#{envelope.id}")

      html =
        view
        |> element("#details-btn-" <> envelope.id)
        |> render_click()

      assert html =~ ~s(id="approval-details-#{envelope.id}")

      html =
        view
        |> element("#details-btn-" <> envelope.id)
        |> render_click()

      refute html =~ ~s(id="approval-details-#{envelope.id}")
    end
  end

  # --- PubSub updates -------------------------------------------------------

  describe "PubSub updates" do
    test "approval queue event triggers re-render", %{conn: conn} do
      {:ok, view, html} = live(conn, "/queue")
      assert html =~ "Queue is clear"

      # Create a pending approval
      intent = agent_intent()

      _envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      # Broadcast
      Bank.Runtime.PubSub.broadcast(
        Bank.Runtime.PubSub.approval_queue(),
        %{topic: :approval_queue, event: :enqueued, at: DateTime.utc_now(), payload: %{}}
      )

      html = render(view)
      assert html =~ "Pending approvals"
    end

    test "security event triggers re-render", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/queue")

      Bank.Runtime.PubSub.broadcast(
        Bank.Runtime.PubSub.security_events(),
        %{topic: :security_events, event: :paused, at: DateTime.utc_now(), payload: %{}}
      )

      # Should re-render without crashing
      _html = render(view)
    end
  end

  # --- Layouts.app current_scope (admin nav visibility, mirrors #308 / #311)
  #
  # Representative admin-nav test for the sweep that added
  # `current_scope={@current_scope}` to <Layouts.app> across eight
  # LiveViews (audit / control / counterparties / counterparty_detail
  # / intent_replay / intents / policies / queue). Without the assign,
  # `admin_visible?/1` always returns `false` and the
  # `/admin/api_keys` sidebar link is hidden from legitimate admins.
  # Pinning the wiring here keeps a future drive-by edit from silently
  # breaking it again on the highest-traffic operator surface.

  describe "layout current_scope wiring" do
    test "admin user sees /admin/api_keys nav link when allowlisted",
         %{conn: conn, current_user: user} do
      original_admin_emails = Application.get_env(:bank, :admin_emails)

      try do
        Application.put_env(:bank, :admin_emails, [user.email])

        {:ok, _view, html} = live(conn, "/queue")

        assert html =~ ~s(href="/admin/api_keys")
      after
        Application.put_env(:bank, :admin_emails, original_admin_emails)
      end
    end
  end

  # --- Swap badges and metadata (#195) -------------------------------------

  describe "swap badges and metadata (#195)" do
    test "approval row carries a swap kind badge for swap intents", %{conn: conn} do
      swap_intent = agent_intent(kind: :swap, asset: "USDC", chain: "base-sepolia")

      envelope =
        decision_envelope(
          intent: swap_intent,
          outcome: :approval_required,
          risk_tier: :moderate,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, view, _html} = live(conn, "/queue")

      assert has_element?(view, "#approval-kind-badge-#{envelope.id}", "swap")
    end

    test "transfer approval row does NOT carry a swap badge", %{conn: conn} do
      transfer_intent = agent_intent(kind: :transfer)

      envelope =
        decision_envelope(
          intent: transfer_intent,
          outcome: :approval_required,
          risk_tier: :low,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, view, _html} = live(conn, "/queue")

      refute has_element?(view, "#approval-kind-badge-#{envelope.id}")
    end

    test "active execution row badges a swap plan and shows the route summary",
         %{conn: conn} do
      swap_intent = agent_intent(kind: :swap, chain: "base-sepolia")
      decision = decision_envelope(intent: swap_intent, current: true)

      plan =
        swap_execution_plan(
          decision: decision,
          intent_id: swap_intent.id,
          execution_status: :broadcasting
        )

      {:ok, view, _html} = live(conn, "/queue")

      assert has_element?(view, "#execution-kind-badge-#{plan.id}", "swap")
      assert has_element?(view, "#execution-swap-summary-#{plan.id}")

      summary = render(element(view, "#execution-swap-summary-#{plan.id}"))
      assert summary =~ "USDC → USDC"
      assert summary =~ plan.steps["route_provider"]
    end

    test "held / blocked decision row carries a swap badge for swap intents",
         %{conn: conn} do
      swap_intent = agent_intent(kind: :swap, chain: "base-sepolia")

      held =
        decision_envelope(
          intent: swap_intent,
          outcome: :hold,
          risk_tier: :elevated,
          current: true
        )

      {:ok, view, _html} = live(conn, "/queue")

      assert has_element?(view, "#decision-kind-badge-#{held.id}", "swap")
    end

    test "secret hygiene — queue UI never renders raw calldata, spender, or token addresses",
         %{conn: conn} do
      swap_intent = agent_intent(kind: :swap, chain: "base-sepolia")
      decision = decision_envelope(intent: swap_intent, current: true)

      plan =
        swap_execution_plan(
          decision: decision,
          intent_id: swap_intent.id,
          execution_status: :pending_confirmation
        )

      {:ok, _view, html} = live(conn, "/queue")

      refute html =~ plan.steps["calldata"]
      refute html =~ plan.steps["spender"]
      refute html =~ plan.steps["swap_target_contract"]
      refute html =~ plan.steps["source_token_address"]
      refute html =~ plan.steps["destination_token_address"]
      refute html =~ "Bearer "
      refute html =~ "Authorization:"
    end
  end

  # --- Morpho deposit risk-explanation UI (#204) ---------------------------

  describe "morpho deposit approval card (#204)" do
    @morpho_vault "0x" <> String.duplicate("a4", 20)
    @morpho_explanation %{
      "kind" => "morpho_vault_risk",
      "venue" => "morpho",
      "vault_address" => @morpho_vault,
      "vault_name" => "Demo USDC Vault",
      "chain_id" => 84_532,
      "loan_asset" => "USDC",
      "decision" => "approval_required",
      "risk_tier" => "moderate",
      "summary" => "Approval required because vault is not yet listed.",
      "primary_reasons" => [
        %{
          "code" => "vault_listed",
          "severity" => "approval",
          "message" => "Vault is not listed on Morpho yet."
        },
        %{
          "code" => "snapshot_freshness_warnings",
          "severity" => "warn",
          "message" => "Warning snapshot age 4m 12s exceeds 5m floor."
        }
      ],
      "checks" => [
        %{
          "code" => "vault_allowlist",
          "status" => "pass",
          "label" => "Vault on workspace allowlist",
          "source" => "policy.morpho_vault_allowlist"
        },
        %{
          "code" => "asset_match",
          "status" => "pass",
          "label" => "Loan asset matches intent",
          "source" => "snapshot.loan_asset"
        },
        %{
          "code" => "vault_listed",
          "status" => "warn",
          "label" => "Vault listed",
          "source" => "snapshot.listed"
        }
      ],
      "market_allocations" => [],
      "source_refs" => []
    }

    defp morpho_decision_setup(_ctx) do
      intent = morpho_deposit_intent(target_raw_address: @morpho_vault)

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          risk_tier: :moderate,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z],
          reasons: %{
            "items" => [
              %{
                "code" => "morpho_risk_explanation",
                "message" => @morpho_explanation["summary"],
                "details" => %{"morpho_risk_explanation" => @morpho_explanation}
              }
            ]
          }
        )

      %{intent: intent, envelope: envelope}
    end

    setup :morpho_decision_setup

    test "approval row shows the morpho deposit kind badge", %{conn: conn, envelope: envelope} do
      {:ok, view, _html} = live(conn, "/queue")

      assert has_element?(view, "#approval-morpho-badge-#{envelope.id}", "morpho deposit")
      refute has_element?(view, "#approval-kind-badge-#{envelope.id}")
    end

    test "expanded approval details surface the morpho risk explanation",
         %{conn: conn, envelope: envelope} do
      {:ok, view, _html} = live(conn, "/queue")

      view |> element("#details-btn-#{envelope.id}") |> render_click()

      assert has_element?(view, "#approval-morpho-details-#{envelope.id}")
      assert has_element?(view, "#approval-morpho-summary-#{envelope.id}")
      assert has_element?(view, "#approval-morpho-reasons-#{envelope.id}")
      assert has_element?(view, "#approval-morpho-checks-#{envelope.id}")

      details = render(element(view, "#approval-morpho-details-#{envelope.id}"))

      assert details =~ "Demo USDC Vault"
      assert details =~ @morpho_vault
      assert details =~ "84532"
      assert details =~ "Approval required because vault is not yet listed."
      # Primary reasons are rendered with severity + code + message.
      assert details =~ "vault_listed"
      assert details =~ "Vault is not listed on Morpho yet."
      assert details =~ "approval"
      # Checks render with their pass/warn label.
      assert details =~ "Vault on workspace allowlist"
      assert details =~ "Loan asset matches intent"
    end

    test "approval / reject controls remain present for morpho decisions",
         %{conn: conn, envelope: envelope} do
      {:ok, _view, html} = live(conn, "/queue")

      assert html =~ ~s(id="approve-btn-#{envelope.id}")
      assert html =~ ~s(id="reject-btn-#{envelope.id}")
    end

    test "held morpho decision row carries the morpho badge", %{conn: conn} do
      held_intent = morpho_deposit_intent(target_raw_address: @morpho_vault)

      held =
        decision_envelope(
          intent: held_intent,
          outcome: :hold,
          risk_tier: :elevated,
          current: true,
          reasons: %{
            "items" => [
              %{
                "code" => "morpho_risk_explanation",
                "message" => "Snapshot stale.",
                "details" => %{"morpho_risk_explanation" => @morpho_explanation}
              }
            ]
          }
        )

      {:ok, view, _html} = live(conn, "/queue")

      assert has_element?(view, "#decision-morpho-badge-#{held.id}", "morpho deposit")
    end

    test "non-morpho approval does NOT render morpho badge or details panel",
         %{conn: conn} do
      transfer_intent = agent_intent(kind: :transfer)

      transfer_decision =
        decision_envelope(
          intent: transfer_intent,
          outcome: :approval_required,
          risk_tier: :low,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, view, _html} = live(conn, "/queue")

      refute has_element?(view, "#approval-morpho-badge-#{transfer_decision.id}")

      view |> element("#details-btn-#{transfer_decision.id}") |> render_click()
      refute has_element?(view, "#approval-morpho-details-#{transfer_decision.id}")
    end

    test "secret hygiene — morpho approval card never embeds raw provider payloads",
         %{conn: conn, envelope: envelope} do
      {:ok, view, _html} = live(conn, "/queue")
      view |> element("#details-btn-#{envelope.id}") |> render_click()

      details = render(element(view, "#approval-morpho-details-#{envelope.id}"))

      refute details =~ "Bearer "
      refute details =~ "Authorization:"
      refute details =~ "private_key"
      # market_allocations / pending_caps / source warnings are
      # intentionally NOT projected onto the approval block.
      refute details =~ "market_allocations"
      refute details =~ "pending_caps"
      refute details =~ "source_warnings"
    end
  end
end
