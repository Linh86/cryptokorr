defmodule BankWeb.IntentsLiveTest do
  @moduledoc """
  LiveView tests for the control-tower intents page (#44).
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user
  import Bank.Fixtures

  # --- Empty state ---------------------------------------------------------

  describe "empty state" do
    test "renders the intents page with empty state when no intents exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/intents")

      assert html =~ ~s(id="page-title")
      assert html =~ "Intents"
      assert html =~ ~s(id="intents-empty")
      assert html =~ "No intents match"
    end

    test "state breakdown is rendered even when all counts are zero", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/intents")

      assert html =~ ~s(id="state-breakdown")
    end
  end

  # --- Populated table -----------------------------------------------------

  describe "with intents" do
    setup do
      intent = agent_intent()
      %{intent: intent}
    end

    test "lists the submitted intent", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/intents")

      assert html =~ ~s(id="intents-table")
      assert html =~ "intent-row-" <> intent.id
      assert html =~ intent.agent_id
    end

    test "replay link points to the intent's replay view", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/intents")

      assert html =~ ~p"/audit/replay/#{intent.id}"
    end
  end

  # --- Filters -------------------------------------------------------------

  describe "filters" do
    test "state filter narrows the list", %{conn: conn} do
      submitted = agent_intent()
      # Put a second intent into a different state.
      blocked = agent_intent()
      {:ok, blocked} = blocked |> Ecto.Changeset.change(%{state: :blocked}) |> Bank.Repo.update()

      {:ok, _view, html} = live(conn, "/intents?state=blocked")

      assert html =~ "intent-row-" <> blocked.id
      refute html =~ "intent-row-" <> submitted.id
    end

    test "unknown state query falls back to :all", %{conn: conn} do
      intent = agent_intent()
      {:ok, _view, html} = live(conn, "/intents?state=does-not-exist")
      assert html =~ "intent-row-" <> intent.id
    end
  end

  # --- Count semantics (issue #53) ------------------------------------------

  describe "state breakdown respects kind + search filters" do
    test "kind filter scopes the chip counts", %{conn: conn} do
      # Three transfers + one swap; every intent starts in :submitted.
      _t1 = agent_intent(kind: :transfer)
      _t2 = agent_intent(kind: :transfer)
      _t3 = agent_intent(kind: :transfer)
      _swap = agent_intent(kind: :swap)

      {:ok, view, _html} = live(conn, "/intents?kind=transfer")

      # The submitted chip inside the breakdown must show 3, not 4.
      breakdown = view |> element("#state-breakdown") |> render()

      assert breakdown =~ ~r/Submitted.*3/s
      refute breakdown =~ ~r/Submitted.*4/s
    end

    test "search filter scopes the chip counts", %{conn: conn} do
      _alpha = agent_intent(agent_id: "agent-alpha")
      _beta1 = agent_intent(agent_id: "agent-beta-1")
      _beta2 = agent_intent(agent_id: "agent-beta-2")

      {:ok, view, _html} = live(conn, "/intents?q=beta")

      breakdown = view |> element("#state-breakdown") |> render()
      assert breakdown =~ ~r/Submitted.*2/s
    end

    test "state filter does NOT scope the chip counts (chips stay navigable)",
         %{conn: conn} do
      submitted = agent_intent()
      blocked = agent_intent()
      {:ok, _} = blocked |> Ecto.Changeset.change(%{state: :blocked}) |> Bank.Repo.update()

      {:ok, view, _html} = live(conn, "/intents?state=blocked")

      breakdown = view |> element("#state-breakdown") |> render()

      # Even when filtering the table to blocked, the chips still show
      # the submitted count so the operator can see where switching
      # would land them.
      assert breakdown =~ ~r/Submitted.*1/s
      assert breakdown =~ ~r/Blocked.*1/s

      _ = submitted
    end
  end
end
