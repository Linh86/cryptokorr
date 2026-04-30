defmodule BankWeb.IntentReplayLiveTest do
  @moduledoc """
  LiveView tests for the per-intent replay page.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user
  import Bank.Fixtures

  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  describe "mount — intent not found" do
    test "redirects to /audit with a flash error", %{conn: conn} do
      missing_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/audit", flash: flash}}} =
               live(conn, "/audit/replay/#{missing_id}")

      assert %{"error" => message} = flash
      assert message =~ "not found"
    end
  end

  describe "intent with no children" do
    setup do
      intent = agent_intent()
      %{intent: intent}
    end

    test "renders intent summary section", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "Intent replay"
      assert html =~ ~s(id="replay-intent")
      assert html =~ to_string(intent.kind)
      assert html =~ intent.asset
      assert html =~ intent.chain
      assert html =~ Decimal.to_string(intent.amount)
    end

    test "shows empty stubs in each section", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "No audit events yet"
      assert html =~ "No trust assessments produced yet"
      assert html =~ "No simulation reports"
      assert html =~ "No decision envelopes written yet"
      assert html =~ "No execution plans"
      assert html =~ "No policy rules captured"
    end

    test "renders all six section cards", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ ~s(id="replay-intent")
      assert html =~ ~s(id="replay-audit")
      assert html =~ ~s(id="replay-trust")
      assert html =~ ~s(id="replay-simulations")
      assert html =~ ~s(id="replay-decisions")
      assert html =~ ~s(id="replay-plans")
      assert html =~ ~s(id="replay-policy")
    end
  end

  describe "intent with full bundle" do
    setup do
      intent = agent_intent()
      claim = trust_assessment(intent: intent, derived_trust: :trusted, current: true)
      sim = simulation_report(intent: intent, status: :completed, current: true)

      decision =
        decision_envelope(
          intent: intent,
          outcome: :auto_exec,
          risk_tier: :low,
          current: true,
          reasons: %{"items" => ["policy.amount_limit ok", "simulation passed"]}
        )

      plan =
        execution_plan(
          decision: decision,
          execution_status: :confirmed,
          final_outcome: :confirmed,
          tx_refs: ["0xabc1234567890def"]
        )

      audit_event(
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :agent
      )

      audit_event(
        event_type: "decision.decided",
        subject_type: "decision_envelope",
        subject_id: decision.id,
        correlation_id: intent.id,
        actor: :runtime
      )

      %{intent: intent, claim: claim, sim: sim, decision: decision, plan: plan}
    end

    test "renders trust assessment with derived level", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "trusted"
      assert html =~ "confidence:"
    end

    test "renders simulation with status and provider", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "completed"
      assert html =~ "tenderly"
    end

    test "renders decision with reasons", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "auto_exec"
      assert html =~ "policy.amount_limit ok"
      assert html =~ "simulation passed"
    end

    test "renders execution plan with final outcome and tx ref", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "confirmed"
      assert html =~ "final:"
      # Truncated tx ref
      assert html =~ "0xabc12345"
    end

    test "renders audit timeline with correlation slice", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "intent.submitted"
      assert html =~ "decision.decided"
    end
  end

  describe "navigation" do
    test "back link points to /audit", %{conn: conn} do
      intent = agent_intent()
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ ~s(href="/audit")
    end

    test "Audit nav item is active on replay page", %{conn: conn} do
      intent = agent_intent()
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      # The sidebar's Audit link gets the active style.
      assert html =~ "bg-primary/10 text-primary"
    end
  end

  describe "refresh" do
    test "refresh button reloads the bundle", %{conn: conn} do
      intent = agent_intent()
      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      # Add a new audit event after mount.
      audit_event(
        event_type: "intent.cancelled",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :user
      )

      view |> element("button", "Refresh") |> render_click()

      html = render(view)
      assert html =~ "intent.cancelled"
    end
  end
end
