defmodule BankWeb.IntentsLiveTest do
  @moduledoc """
  LiveView tests for the control-tower intents page (#44).
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
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
end
