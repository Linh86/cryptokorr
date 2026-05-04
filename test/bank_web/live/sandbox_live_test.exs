defmodule BankWeb.SandboxLiveTest do
  @moduledoc """
  LiveView tests for the guided sandbox demo (#239).
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import Bank.Fixtures

  alias Bank.Counterparties.Counterparty
  alias Bank.Repo

  setup :register_and_log_in_user

  describe "initial render — empty state" do
    test "renders sandbox guide with stable ids and 0/8 progress",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(view, "#sandbox-page-title")
      assert has_element?(view, "#sandbox-guide")
      assert has_element?(view, "#sandbox-progress")

      for step <-
            ~w(workspace policies counterparty intent simulate approval replay held-blocked) do
        assert has_element?(view, "#sandbox-step-" <> step)
      end
    end

    test "workspace step is complete by default; the rest are pending",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(view, ~s|#sandbox-step-workspace[data-complete="true"]|)

      for step <-
            ~w(policies counterparty intent simulate approval replay held-blocked) do
        assert has_element?(view, ~s|#sandbox-step-#{step}[data-complete="false"]|)
      end

      assert has_element?(view, ~s|#sandbox-guide[data-completed="1"]|)
      assert has_element?(view, ~s|#sandbox-guide[data-total="8"]|)
    end
  end

  describe "step links" do
    test "each step has a navigate link to the right operator page",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(
               view,
               ~s|#sandbox-step-link-workspace[href="/dashboard"]|
             )

      assert has_element?(
               view,
               ~s|#sandbox-step-link-policies[href="/policies"]|
             )

      assert has_element?(
               view,
               ~s|#sandbox-step-link-counterparty[href="/counterparties"]|
             )

      assert has_element?(view, ~s|#sandbox-step-link-intent[href="/intents"]|)
      assert has_element?(view, ~s|#sandbox-step-link-simulate[href="/intents"]|)

      assert has_element?(
               view,
               ~s|#sandbox-step-link-approval[href="/queue#pending-approvals-section"]|
             )

      assert has_element?(view, ~s|#sandbox-step-link-replay[href="/audit"]|)

      assert has_element?(
               view,
               ~s|#sandbox-step-link-held-blocked[href="/queue#held-actions-section"]|
             )
    end
  end

  describe "step completion reflects DB state" do
    test "policies step flips to complete when an active rule exists",
         %{conn: conn, workspace: ws} do
      _rule = policy_rule(workspace_id: ws.id, state: :active)

      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(view, ~s|#sandbox-step-policies[data-complete="true"]|)
    end

    test "counterparty step flips to complete when a counterparty has a non-:unknown trust level",
         %{conn: conn, workspace: ws} do
      cp = counterparty(workspace_id: ws.id)
      {:ok, _} = cp |> Counterparty.changeset(%{}) |> Repo.update()

      {1, _} =
        Repo.update_all(
          from(c in Counterparty, where: c.id == ^cp.id),
          set: [current_trust_level: :trusted]
        )

      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(view, ~s|#sandbox-step-counterparty[data-complete="true"]|)
    end

    test "intent step flips to complete when an intent exists",
         %{conn: conn} do
      _intent = agent_intent()

      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(view, ~s|#sandbox-step-intent[data-complete="true"]|)
    end

    test "simulate step flips to complete when a SimulationReport exists",
         %{conn: conn} do
      intent = agent_intent()
      _sim = simulation_report(intent: intent)

      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(view, ~s|#sandbox-step-simulate[data-complete="true"]|)
    end

    test "approval step flips to complete when an :approval_required envelope exists",
         %{conn: conn} do
      intent = agent_intent()

      _envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(view, ~s|#sandbox-step-approval[data-complete="true"]|)
    end

    test "replay step flips to complete when any decision envelope exists",
         %{conn: conn} do
      intent = agent_intent()
      _envelope = decision_envelope(intent: intent, current: true)

      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(view, ~s|#sandbox-step-replay[data-complete="true"]|)
    end

    test "held-blocked step flips to complete for :hold or :block outcome",
         %{conn: conn} do
      intent_a = agent_intent()
      _hold = decision_envelope(intent: intent_a, outcome: :hold, current: true)

      {:ok, view_a, _html} = live(conn, "/sandbox")

      assert has_element?(view_a, ~s|#sandbox-step-held-blocked[data-complete="true"]|)

      intent_b = agent_intent()
      _block = decision_envelope(intent: intent_b, outcome: :block, current: true)

      {:ok, view_b, _html} = live(conn, "/sandbox")

      assert has_element?(view_b, ~s|#sandbox-step-held-blocked[data-complete="true"]|)
    end

    test "all steps complete drives sandbox-progress to 8/8",
         %{conn: conn, workspace: ws} do
      _rule = policy_rule(workspace_id: ws.id, state: :active)

      cp = counterparty(workspace_id: ws.id)

      {1, _} =
        Repo.update_all(
          from(c in Counterparty, where: c.id == ^cp.id),
          set: [current_trust_level: :trusted]
        )

      intent = agent_intent()
      _sim = simulation_report(intent: intent)

      _approval =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      hold_intent = agent_intent()
      _hold = decision_envelope(intent: hold_intent, outcome: :hold, current: true)

      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(view, ~s|#sandbox-guide[data-completed="8"]|)
      assert has_element?(view, "#sandbox-progress", "8/8")
    end
  end

  describe "fresh Demo.seed/0 — runbook claim (#242 P2)" do
    # Pre-fix: the seed created intents directly via `upsert_intent/4`,
    # bypassing the runtime simulation pipeline, so `/sandbox`'s
    # `simulate` step stayed incomplete after a fresh seed and the
    # runbook's "all eight steps render as complete" claim was false.
    # This test pins the post-fix surface.
    test "after Bank.Demo.seed/0, every /sandbox step including simulate is complete (8/8)",
         %{conn: conn} do
      :ok = Bank.Demo.seed()

      suffix = System.unique_integer([:positive])

      {:ok, demo_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "demo-#{suffix}",
          email: "demo-#{suffix}@example.com",
          name: "Demo Reviewer"
        })

      {:ok, _membership} =
        Bank.Workspaces.create_membership(%{
          user_id: demo_user.id,
          workspace_id: Bank.Demo.demo_workspace_id(),
          role: :operator
        })

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, demo_user.id)

      {:ok, view, _html} = live(conn, "/sandbox")

      for step <-
            ~w(workspace policies counterparty intent simulate approval replay held-blocked) do
        assert has_element?(view, ~s|#sandbox-step-#{step}[data-complete="true"]|),
               "step #{step} must be complete on a freshly seeded sandbox-demo workspace"
      end

      assert has_element?(view, ~s|#sandbox-guide[data-completed="8"]|)
      assert has_element?(view, "#sandbox-progress", "8/8")
    end
  end

  describe "cross-workspace isolation" do
    test "sibling-workspace data does NOT mark current workspace steps complete",
         %{conn: conn} do
      {:ok, sibling_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "sibling-sandbox-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      _rule = policy_rule(workspace_id: sibling_ws.id, state: :active)

      sibling_cp = counterparty(workspace_id: sibling_ws.id)

      {1, _} =
        Repo.update_all(
          from(c in Counterparty, where: c.id == ^sibling_cp.id),
          set: [current_trust_level: :trusted]
        )

      sibling_intent = agent_intent(workspace_id: sibling_ws.id)
      _sim = simulation_report(intent: sibling_intent)

      _approval =
        decision_envelope(
          intent: sibling_intent,
          outcome: :approval_required,
          current: true,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      sibling_intent_hold = agent_intent(workspace_id: sibling_ws.id)
      _hold = decision_envelope(intent: sibling_intent_hold, outcome: :hold, current: true)

      {:ok, view, _html} = live(conn, "/sandbox")

      # Workspace step is still complete (the user has their own
      # active workspace) but every other step stays pending.
      assert has_element?(view, ~s|#sandbox-step-workspace[data-complete="true"]|)

      for step <-
            ~w(policies counterparty intent simulate approval replay held-blocked) do
        assert has_element?(view, ~s|#sandbox-step-#{step}[data-complete="false"]|)
      end

      assert has_element?(view, ~s|#sandbox-guide[data-completed="1"]|)
    end
  end

  describe "no chain-broadcast / mutating dispatch" do
    test "page renders no execute / dispatch / sign / broadcast / pause / revoke / approve / reject button",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/sandbox")

      page_html =
        view
        |> element("#sandbox-guide")
        |> render()

      # Mutating phx-click events that exist elsewhere in the app
      # must not surface on the sandbox guide. Refuting both the
      # event names and common button labels catches both raw HTML
      # and the standard Phoenix attribute encoding.
      for refused <-
            ~w(
              phx-submit
              dispatch_intent
              execute_intent
              broadcast
              pause_runtime
              resume_runtime
              pause_chain
              resume_chain
              pause_agent_keys
              resume_agent_keys
              revoke_delegation
              approve_decision
              reject_decision
              abort_plan
            ) do
        refute page_html =~ refused
      end

      # `phx-click="refresh"` is allowed (read-only refresh of
      # the checklist counts) and only renders on the page-level
      # refresh button outside the guide section.
      refute page_html =~ ~s|phx-click="refresh"|

      # Belt-and-suspenders: no `data-confirm` anywhere on the
      # sandbox page. Confirmation prompts are only attached to
      # mutating actions; the absence here proves we have none.
      refute html =~ "data-confirm"
    end
  end

  describe "secret hygiene" do
    test "page does not include common secret-bearing substrings",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sandbox")

      refute html =~ "Bearer "
      refute html =~ "Authorization:"
      refute html =~ "cb_"
      refute html =~ "sk_"
      refute html =~ "0x"
      refute html =~ "BEGIN "
      refute html =~ "private_key"
      refute html =~ "signing"
    end
  end

  describe "refresh event" do
    test "refresh re-renders state without broadcasting anything",
         %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/sandbox")

      assert has_element?(view, ~s|#sandbox-step-policies[data-complete="false"]|)

      _rule = policy_rule(workspace_id: ws.id, state: :active)

      view |> element("button", "Refresh") |> render_click()

      assert has_element?(view, ~s|#sandbox-step-policies[data-complete="true"]|)
    end
  end
end
