defmodule Bank.Activity.ReconciliationTest do
  @moduledoc """
  Tests for `Bank.Activity.Reconciliation` (#246) — links imported
  chain activity rows to CryptoBank execution plans by `tx_hash`,
  workspace, and chain.

  Coverage:

    * `match_for_plan/1` — returns workspace-scoped, chain-scoped
      activities citing a tx_hash from the plan's `tx_refs`
    * cross-workspace and cross-chain misses collapse to `[]`
    * `match_for_plans/1` — flat batch shape
    * `classify_activity/2` — `:cryptobank_execution` for matched
      rows, `:external` for unmatched / no tx_hash
    * read-only: no row mutation, no Oban enqueue
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Activity
  alias Bank.Activity.{ImportedActivity, Reconciliation}
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Repo

  import Bank.Fixtures

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "recon-#{System.unique_integer([:positive])}",
        name: "Recon",
        mainnet_enabled: true
      })

    %{workspace: ws}
  end

  # --- match_for_plan/1 -------------------------------------------------

  describe "match_for_plan/1 — workspace + chain + tx_hash matcher" do
    test "matches a confirmed activity citing a tx_hash from the plan's tx_refs",
         %{workspace: ws} do
      tx_hash = "0xabc1234567890def" <> String.duplicate("0", 30)

      plan = build_plan(ws, tx_refs: [tx_hash], chain: "base")

      {:ok, :inserted, activity} =
        Activity.create_imported_activity(activity_attrs(ws.id, tx_hash: tx_hash, chain: "base"))

      assert [%{activity: matched, plan_id: pid, tx_hash: ^tx_hash}] =
               Reconciliation.match_for_plan(plan)

      assert matched.id == activity.id
      assert pid == plan.id
    end

    test "returns [] for a plan with empty tx_refs", %{workspace: ws} do
      plan = build_plan(ws, tx_refs: [], chain: "base")
      assert Reconciliation.match_for_plan(plan) == []
    end

    test "ignores activity rows in a sibling workspace (cross-workspace isolation)",
         %{workspace: ws_a} do
      tx_hash = "0xshared" <> String.duplicate("a", 38)

      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "recon-other-#{System.unique_integer([:positive])}",
          name: "Recon Other",
          mainnet_enabled: true
        })

      plan_a = build_plan(ws_a, tx_refs: [tx_hash], chain: "base")

      # Workspace B happens to import the same tx_hash. Workspace A
      # must NOT see it as a match — that would cross-link ledgers.
      {:ok, :inserted, _activity_b} =
        Activity.create_imported_activity(
          activity_attrs(ws_b.id, tx_hash: tx_hash, chain: "base")
        )

      assert Reconciliation.match_for_plan(plan_a) == []
    end

    test "ignores activity rows on a different chain (cross-chain isolation)",
         %{workspace: ws} do
      tx_hash = "0xchainmix" <> String.duplicate("b", 36)
      plan_base = build_plan(ws, tx_refs: [tx_hash], chain: "base")

      # Same hash on a DIFFERENT chain — must not cross-link.
      {:ok, :inserted, _wrong_chain} =
        Activity.create_imported_activity(
          activity_attrs(ws.id, tx_hash: tx_hash, chain: "ethereum")
        )

      assert Reconciliation.match_for_plan(plan_base) == []
    end

    test "matches multiple activity rows that cite different tx_refs from the same plan",
         %{workspace: ws} do
      h1 = "0xref1" <> String.duplicate("1", 39)
      h2 = "0xref2" <> String.duplicate("2", 39)

      plan = build_plan(ws, tx_refs: [h1, h2], chain: "base")

      {:ok, :inserted, _a1} =
        Activity.create_imported_activity(activity_attrs(ws.id, tx_hash: h1, chain: "base"))

      {:ok, :inserted, _a2} =
        Activity.create_imported_activity(
          activity_attrs(ws.id,
            tx_hash: h2,
            chain: "base",
            occurred_at:
              DateTime.add(DateTime.utc_now(), 60, :second) |> DateTime.truncate(:microsecond)
          )
        )

      matches = Reconciliation.match_for_plan(plan)
      assert length(matches) == 2
      assert Enum.all?(matches, &(&1.plan_id == plan.id))
      assert Enum.map(matches, & &1.tx_hash) |> Enum.sort() == Enum.sort([h1, h2])
    end

    test "returns [] when plan has nil workspace_id (defensive)", %{workspace: ws} do
      tx_hash = "0xdefensive" <> String.duplicate("c", 35)
      plan = build_plan(ws, tx_refs: [tx_hash], chain: "base")
      defensive = %{plan | workspace_id: nil}

      assert Reconciliation.match_for_plan(defensive) == []
    end
  end

  # --- match_for_plans/1 ------------------------------------------------

  describe "match_for_plans/1 — batch shape" do
    test "concatenates matches across multiple plans", %{workspace: ws} do
      h1 = "0xbatch1" <> String.duplicate("1", 37)
      h2 = "0xbatch2" <> String.duplicate("2", 37)

      plan_one = build_plan(ws, tx_refs: [h1], chain: "base")
      plan_two = build_plan(ws, tx_refs: [h2], chain: "base")

      {:ok, :inserted, _} =
        Activity.create_imported_activity(activity_attrs(ws.id, tx_hash: h1, chain: "base"))

      {:ok, :inserted, _} =
        Activity.create_imported_activity(activity_attrs(ws.id, tx_hash: h2, chain: "base"))

      matches = Reconciliation.match_for_plans([plan_one, plan_two])

      assert length(matches) == 2

      assert Enum.map(matches, & &1.plan_id) |> Enum.sort() ==
               Enum.sort([plan_one.id, plan_two.id])
    end

    test "returns [] for an empty plan list" do
      assert Reconciliation.match_for_plans([]) == []
    end
  end

  # --- classify_activity/2 ----------------------------------------------

  describe "classify_activity/2 — :cryptobank_execution vs :external" do
    test "matches plan in same workspace + chain → :cryptobank_execution",
         %{workspace: ws} do
      tx_hash = "0xclass1" <> String.duplicate("1", 38)
      plan = build_plan(ws, tx_refs: [tx_hash], chain: "base")

      {:ok, :inserted, activity} =
        Activity.create_imported_activity(activity_attrs(ws.id, tx_hash: tx_hash, chain: "base"))

      assert Reconciliation.classify_activity(activity, [plan]) == :cryptobank_execution
    end

    test "no matching plan → :external (external wallet transfer)", %{workspace: ws} do
      {:ok, :inserted, activity} =
        Activity.create_imported_activity(
          activity_attrs(ws.id,
            tx_hash: "0xexternal" <> String.duplicate("e", 36),
            chain: "base"
          )
        )

      # No plan in this workspace cites the activity's tx_hash.
      assert Reconciliation.classify_activity(activity, []) == :external
    end

    test "activity with nil tx_hash classifies as :external", %{workspace: ws} do
      {:ok, :inserted, activity} =
        Activity.create_imported_activity(
          activity_attrs(ws.id,
            source_type: :csv,
            source_ref: "csv:row:no-hash",
            tx_hash: nil,
            chain: "base"
          )
        )

      plan =
        build_plan(ws,
          tx_refs: ["0xshould-not-match" <> String.duplicate("0", 30)],
          chain: "base"
        )

      assert Reconciliation.classify_activity(activity, [plan]) == :external
    end

    test "plan in a sibling workspace does NOT classify the activity as :cryptobank_execution",
         %{workspace: ws_a} do
      tx_hash = "0xsibling" <> String.duplicate("a", 37)

      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "recon-sibling-#{System.unique_integer([:positive])}",
          name: "Recon Sibling",
          mainnet_enabled: true
        })

      # Plan is in workspace B; activity is in workspace A.
      sibling_plan = build_plan(ws_b, tx_refs: [tx_hash], chain: "base")

      {:ok, :inserted, activity} =
        Activity.create_imported_activity(
          activity_attrs(ws_a.id, tx_hash: tx_hash, chain: "base")
        )

      assert Reconciliation.classify_activity(activity, [sibling_plan]) == :external
    end
  end

  # --- read-only contract -----------------------------------------------

  describe "read-only by construction" do
    test "match_for_plan/1 enqueues no Oban job and does not mutate rows",
         %{workspace: ws} do
      tx_hash = "0xreadonly" <> String.duplicate("1", 36)
      plan = build_plan(ws, tx_refs: [tx_hash], chain: "base")

      {:ok, :inserted, activity} =
        Activity.create_imported_activity(activity_attrs(ws.id, tx_hash: tx_hash, chain: "base"))

      jobs_before = Repo.all(Oban.Job)
      activity_before = Repo.get!(ImportedActivity, activity.id)
      plan_before = Repo.get!(ExecutionPlan, plan.id)

      _ = Reconciliation.match_for_plan(plan)
      _ = Reconciliation.match_for_plans([plan])
      _ = Reconciliation.classify_activity(activity, [plan])

      assert Repo.all(Oban.Job) == jobs_before
      assert Repo.get!(ImportedActivity, activity.id) == activity_before
      assert Repo.get!(ExecutionPlan, plan.id) == plan_before
    end
  end

  # --- helpers -----------------------------------------------------------

  # Build an execution plan in the supplied workspace. The
  # fixtures default to a process-dict workspace_id which DataCase
  # doesn't set; pass workspace_id explicitly so the plan's
  # workspace matches the test's reconciliation scope.
  defp build_plan(ws, opts) do
    chain = Keyword.get(opts, :chain, "base")
    intent = agent_intent(workspace_id: ws.id, chain: chain)
    decision = decision_envelope(intent: intent, outcome: :auto_exec, current: true)
    plan = execution_plan(decision: decision, intent_id: intent.id, workspace_id: ws.id)

    plan
    |> Ecto.Changeset.change(
      tx_refs: Keyword.get(opts, :tx_refs, []),
      chain: chain,
      execution_status: :confirmed,
      final_outcome: :confirmed,
      active: false
    )
    |> Repo.update!()
  end

  defp activity_attrs(workspace_id, overrides) do
    Map.merge(
      %{
        workspace_id: workspace_id,
        source_type: :wallet_chain,
        source_ref: "wallet:" <> Integer.to_string(System.unique_integer([:positive])),
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        asset: "USDC",
        chain: "base",
        amount: Decimal.new("100.50"),
        direction: :inbound,
        status: :confirmed,
        confidence: :high,
        tx_hash: nil
      },
      Enum.into(overrides, %{})
    )
  end
end
