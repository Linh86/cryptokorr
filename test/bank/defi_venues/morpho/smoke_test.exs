defmodule Bank.DefiVenues.Morpho.SmokeTest do
  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.DefiVenues.Morpho.Smoke
  alias Bank.Demo

  describe "run/0 — happy path on freshly seeded workspace" do
    setup do
      :ok = Demo.seed()
      :ok
    end

    test "returns {:ok, report} with every check passing" do
      assert {:ok, report} = Smoke.run()
      assert report.status == :pass
      assert report.workspace_slug == Demo.workspace_slug()
      assert is_binary(report.workspace_id)
      assert report.passed == report.total
      assert report.total == length(Smoke.check_order())

      check_names = Enum.map(report.checks, & &1.name)

      # Order is part of the contract — operators read the
      # report top-to-bottom and the runbook lists checks in
      # the same order.
      assert check_names == Smoke.check_order()
      assert Enum.all?(report.checks, &(&1.status == :pass))
    end

    test "side-effect contract: no execution / chain Oban jobs, no execution plans" do
      assert {:ok, _report} = Smoke.run()

      # The Morpho path is read-only with respect to chain
      # broadcast: no `RunExecution`, no `RevokeDelegation`, no
      # adapter-side worker is enqueued. The benign
      # `ExpireApproval` job IS enqueued for each
      # `:approval_required` decision (that's the operator
      # approval-window timer); it touches no chain and is
      # captured by the existing approvals replay coverage.
      forbidden_workers =
        Enum.map(
          [
            Bank.Runtime.Workers.RunExecution,
            Bank.Runtime.Workers.RevokeDelegation
          ],
          &to_string/1
        )

      enqueued_workers = Enum.map(all_enqueued(), & &1.worker)
      leaks = Enum.filter(enqueued_workers, &(&1 in forbidden_workers))

      assert leaks == [],
             "forbidden chain-touching workers were enqueued: #{inspect(leaks)}"

      # Read-only Morpho path never creates an `ExecutionPlan`
      # for any of its `defi_yield_deposit` intents. The demo
      # seed itself owns its own (transfer) execution plans, so
      # we filter on the smoke's agent_id rather than asserting a
      # global zero.
      import Ecto.Query

      plan_count =
        Bank.Repo.one(
          from p in Bank.Decisions.ExecutionPlan,
            join: i in Bank.Intents.AgentIntent,
            on: p.intent_id == i.id,
            where: i.agent_id == "morpho-smoke-agent",
            select: count(p.id)
        )

      assert plan_count == 0,
             "Morpho intents must not create ExecutionPlans (got #{plan_count})"
    end

    test "is idempotent — re-running the smoke does not fail" do
      assert {:ok, _first} = Smoke.run()
      assert {:ok, _second} = Smoke.run()
    end
  end

  describe "run/0 — missing seed" do
    test "returns {:error, report} with a single seed-failure check on an empty DB" do
      refute Demo.demo_workspace_id()

      assert {:error, report} = Smoke.run()
      assert report.status == :fail
      assert report.workspace_id == nil
      assert report.total == 1
      assert report.passed == 0

      assert [seed_check] = report.checks
      assert seed_check.name == "seed"
      assert seed_check.detail =~ "mix bank.demo.seed"
    end
  end

  # The runbook lists each check by name and describes the
  # outcome the operator should expect. If the runner adds or
  # renames a check, the runbook must follow — these tests fail
  # fast when the two drift apart.
  describe "runbook docs/runbooks/morpho-deposits.md" do
    @runbook_path "docs/runbooks/morpho-deposits.md"

    test "lists every smoke check name from `Smoke.check_order/0`" do
      runbook = File.read!(@runbook_path)

      for check_name <- Smoke.check_order() do
        assert runbook =~ "`#{check_name}`",
               "runbook is missing smoke check `#{check_name}`"
      end
    end

    test "documents every Morpho audit event type implemented on this branch" do
      runbook = File.read!(@runbook_path)

      for event_type <- [
            "morpho.risk_explained",
            "morpho.snapshot_stale",
            "morpho.policy_blocked"
          ] do
        assert runbook =~ "`#{event_type}`",
               "runbook is missing implemented event type `#{event_type}`"
      end
    end

    test "lists the four MVP outcomes with the right vocabulary" do
      runbook = File.read!(@runbook_path)

      for outcome <- ["approval_required", "hold", "block"] do
        assert runbook =~ "`:#{outcome}`",
               "runbook is missing the `:#{outcome}` outcome"
      end

      # MVP rule: Morpho deposits never auto_exec. The runbook
      # must call this out explicitly.
      assert runbook =~ "`:auto_exec`",
             "runbook should mention `:auto_exec` (to explain why MVP deposits never reach it)"
    end

    test "calls out that Morpho intents are internal-only at the HTTP boundary" do
      runbook = File.read!(@runbook_path)

      assert runbook =~ "internal",
             "runbook should explain Morpho intents are internal-only (Bank.Intents.normalize/1 rejects defi_yield_deposit)"

      assert runbook =~ "Bank.Intents.normalize/1",
             "runbook should reference Bank.Intents.normalize/1 as the HTTP boundary that rejects defi_yield_deposit"
    end

    test "calls out that execution dispatch is out of scope (#206/#207)" do
      runbook = File.read!(@runbook_path)

      assert runbook =~ "#206",
             "runbook should reference #206 as the deposit-dispatch follow-up"

      assert runbook =~ "#207",
             "runbook should reference #207 as the withdraw-dispatch follow-up"
    end

    test "links the Morpho risk-explanation design doc" do
      runbook = File.read!(@runbook_path)

      assert runbook =~ "morpho-risk-explanation.md",
             "runbook should link the design doc docs/morpho-risk-explanation.md"
    end
  end
end
