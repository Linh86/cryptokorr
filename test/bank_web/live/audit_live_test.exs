defmodule BankWeb.AuditLiveTest do
  @moduledoc """
  LiveView tests for the audit trail page.
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

  describe "initial render — empty stream" do
    test "renders the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ "Audit trail"
      assert html =~ "Append-only stream"
    end

    test "shows empty state when no events", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ ~s(id="audit-empty")
      assert html =~ "No audit events"
      assert html =~ "Audit events appear here"
    end

    test "renders filter panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ ~s(id="audit-filters")
      assert html =~ "Event type"
      assert html =~ "Subject type"
      assert html =~ "Correlation id"
    end
  end

  describe "with events" do
    setup do
      intent = agent_intent()

      e1 =
        audit_event(
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: intent.id,
          correlation_id: intent.id,
          actor: :agent
        )

      e2 =
        audit_event(
          event_type: "decision.decided",
          subject_type: "decision_envelope",
          subject_id: Ecto.UUID.generate(),
          correlation_id: intent.id,
          actor: :runtime
        )

      e3 =
        audit_event(
          event_type: "security.paused",
          subject_type: "runtime",
          subject_id: "global",
          correlation_id: nil,
          actor: :user
        )

      %{intent: intent, e1: e1, e2: e2, e3: e3}
    end

    test "renders event list", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ ~s(id="audit-events")
      assert html =~ "intent.submitted"
      assert html =~ "decision.decided"
      assert html =~ "security.paused"
    end

    test "shows actor and subject metadata", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ "agent_intent"
      assert html =~ "decision_envelope"
      assert html =~ "runtime"
    end

    test "shows replay link for events with correlation_id", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ ~p"/audit/replay/#{intent.id}"
      assert html =~ "Replay"
    end

    test "does not show empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/audit")

      refute html =~ ~s(id="audit-empty")
    end
  end

  describe "filtering" do
    setup do
      intent_a = agent_intent()
      intent_b = agent_intent()

      audit_event(
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent_a.id,
        correlation_id: intent_a.id
      )

      audit_event(
        event_type: "decision.decided",
        subject_type: "decision_envelope",
        subject_id: Ecto.UUID.generate(),
        correlation_id: intent_b.id
      )

      audit_event(
        event_type: "security.paused",
        subject_type: "runtime",
        subject_id: "global"
      )

      %{intent_a: intent_a, intent_b: intent_b}
    end

    test "filters by event_type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audit?event_type=intent.submitted")

      html = render(view)
      assert html =~ "intent.submitted"
      refute html =~ "decision.decided"
      refute html =~ "security.paused"
    end

    test "filters by correlation_id", %{conn: conn, intent_a: intent_a} do
      {:ok, view, _html} = live(conn, "/audit?correlation_id=#{intent_a.id}")

      html = render(view)
      assert html =~ "intent.submitted"
      refute html =~ "decision.decided"
    end

    test "invalid uuid in correlation_id is gracefully ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audit?correlation_id=not-a-uuid")

      html = render(view)
      # No filter applied -> still see all events
      assert html =~ "intent.submitted"
      assert html =~ "decision.decided"
    end

    test "empty filters when nothing matches shows filtered empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audit?event_type=something.does.not.exist")

      html = render(view)
      assert html =~ "No events match the current filters"
    end

    test "clear_filters resets to all events", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audit?event_type=intent.submitted")

      view |> element("#clear-filters-btn") |> render_click()

      html = render(view)
      assert html =~ "intent.submitted"
      assert html =~ "decision.decided"
      assert html =~ "security.paused"
      refute html =~ ~s(id="clear-filters-btn")
    end

    test "filters by actor", %{conn: conn} do
      audit_event(
        event_type: "approval.recorded",
        subject_type: "decision_envelope",
        subject_id: Ecto.UUID.generate(),
        actor: :user
      )

      {:ok, _view, html} = live(conn, "/audit?actor=user")

      assert html =~ "approval.recorded"
      refute html =~ "decision.decided"
    end

    test "filters by from/to date window", %{conn: conn} do
      today = Date.utc_today() |> Date.to_iso8601()

      {:ok, _view, html} = live(conn, "/audit?from=#{today}&to=#{today}")

      # All fixture events were inserted today in UTC, so all still show.
      assert html =~ "intent.submitted"
    end
  end

  describe "pagination" do
    test "renders pagination controls when there are events", %{conn: conn} do
      audit_event(event_type: "intent.submitted", subject_id: Ecto.UUID.generate())

      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ ~s(id="audit-pagination")
      assert html =~ "Previous"
      assert html =~ "Next"
    end

    test "next/prev buttons are disabled when there is only one page", %{conn: conn} do
      audit_event(event_type: "intent.submitted", subject_id: Ecto.UUID.generate())

      {:ok, view, _html} = live(conn, "/audit")

      assert view |> element("#audit-next-page[disabled]") |> has_element?()
      assert view |> element("#audit-prev-page[disabled]") |> has_element?()
    end
  end

  describe "navigation" do
    test "Audit nav item is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/audit")

      # The active class lives on the nav item.
      assert html =~ ~s(href="/audit")
      assert html =~ "bg-primary/10 text-primary"
    end
  end
end
