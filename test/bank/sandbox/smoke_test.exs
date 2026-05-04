defmodule Bank.Sandbox.SmokeTest do
  use Bank.DataCase, async: false

  use Oban.Testing, repo: Bank.Repo

  import Ecto.Query, only: [from: 2]

  alias Bank.Decisions.SimulationReport
  alias Bank.Demo
  alias Bank.Sandbox.Smoke

  describe "run/0 — happy path on freshly seeded workspace" do
    setup do
      stub_adapter_health_ok()
      :ok = Demo.seed()
      %{workspace_id: Demo.demo_workspace_id()}
    end

    test "returns {:ok, report} with every check passing", %{workspace_id: workspace_id} do
      assert {:ok, report} = Smoke.run()
      assert report.status == :pass
      assert report.workspace_slug == Demo.workspace_slug()
      assert report.workspace_id == workspace_id
      assert report.passed == report.total
      assert report.total >= 10

      check_names = Enum.map(report.checks, & &1.name)

      # The order is part of the public contract — operators reading
      # the report rely on it. Health first, then workspace, then the
      # eight Level-1 review-flow steps.
      assert check_names == [
               "health",
               "workspace",
               "policies",
               "counterparty",
               "intent",
               "simulate",
               "approval",
               "held_or_blocked",
               "cancel",
               "replay"
             ]

      assert Enum.all?(report.checks, &(&1.status == :pass))
    end

    test "side-effect contract: no Oban jobs enqueued, no chain calls, no audit rows added" do
      audit_before = Bank.Repo.aggregate(Bank.Audit.AuditEvent, :count, :id)
      intents_before = Bank.Repo.aggregate(Bank.Intents.AgentIntent, :count, :id)
      plans_before = Bank.Repo.aggregate(Bank.Decisions.ExecutionPlan, :count, :id)

      assert {:ok, _} = Smoke.run()

      assert all_enqueued() == []
      assert Bank.Repo.aggregate(Bank.Audit.AuditEvent, :count, :id) == audit_before
      assert Bank.Repo.aggregate(Bank.Intents.AgentIntent, :count, :id) == intents_before
      assert Bank.Repo.aggregate(Bank.Decisions.ExecutionPlan, :count, :id) == plans_before
    end
  end

  describe "run/0 — missing seed" do
    test "returns {:error, report} with a single seed-failure check on an empty DB" do
      # No Demo.seed/0 call — workspace does not exist.
      refute Demo.demo_workspace_id()

      assert {:error, report} = Smoke.run()
      assert report.status == :fail
      assert report.workspace_slug == Demo.workspace_slug()
      assert report.workspace_id == nil
      assert report.total == 1
      assert report.passed == 0

      assert [seed_check] = report.checks
      assert seed_check.name == "seed"
      assert seed_check.status == :fail
      assert seed_check.detail =~ "mix bank.demo.seed"
    end
  end

  describe "run/0 — regression detection" do
    setup do
      stub_adapter_health_ok()
      :ok = Demo.seed()
      :ok
    end

    test "fails the simulate check when simulation reports are missing" do
      # Simulates a stub regression: the Intents context still lists
      # rows but the simulation pipeline has stopped persisting
      # anything. The smoke must catch that.
      Bank.Repo.delete_all(SimulationReport)

      assert {:error, report} = Smoke.run()
      assert report.status == :fail

      simulate = Enum.find(report.checks, &(&1.name == "simulate"))
      assert simulate.status == :fail
      assert simulate.detail =~ "no simulation reports"

      # Defence-in-depth: the unrelated checks must still pass so
      # operators can see exactly which surface regressed.
      pass_names = for c <- report.checks, c.status == :pass, do: c.name
      assert "health" in pass_names
      assert "intent" in pass_names
      assert "approval" in pass_names
      assert "cancel" in pass_names
    end

    test "fails the cancel check when no cancelled intent exists" do
      Bank.Repo.delete_all(from(i in Bank.Intents.AgentIntent, where: i.state == :cancelled))

      assert {:error, report} = Smoke.run()

      cancel = Enum.find(report.checks, &(&1.name == "cancel"))
      assert cancel.status == :fail
      assert cancel.detail =~ "no cancelled intent"
    end
  end

  # The Smoke runner's `health` check pings the configured adapter
  # via `Bank.Ops.Health.adapter/0`. In test, the adapter `base_url`
  # is set but no live HTTP server is running, so without a Req.Test
  # stub the call would surface as `:unknown` and degrade overall
  # health. A 200 stub matches the dev-environment surface where an
  # operator either runs `mix bank.sandbox.smoke` against a healthy
  # adapter or — more commonly — has no adapter configured at all
  # (the production benign-path).
  defp stub_adapter_health_ok do
    Req.Test.stub(Bank.AdapterClient, fn conn ->
      Req.Test.json(conn, %{status: "ok"})
    end)
  end
end
