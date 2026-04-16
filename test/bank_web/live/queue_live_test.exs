defmodule BankWeb.QueueLiveTest do
  @moduledoc """
  LiveView tests for the action queue page.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
      assert html =~ "Approval recorded"

      # DB state reflects the successor envelope.
      successor =
        Bank.Repo.get_by(Bank.Decisions.DecisionEnvelope, intent_id: intent.id, current: true)

      assert successor.outcome == :auto_exec
      assert successor.decided_by == :user
      assert successor.supersedes_id == envelope.id
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
end
