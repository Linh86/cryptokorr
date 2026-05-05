defmodule Bank.Notifications.SmokeTest do
  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Demo
  alias Bank.Notifications
  alias Bank.Notifications.Deliveries
  alias Bank.Notifications.Smoke

  setup do
    on_exit(fn ->
      Application.delete_env(:bank, Bank.Notifications.Channel.Stub)
    end)

    :ok
  end

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
      assert report.total >= 10

      check_names = Enum.map(report.checks, & &1.name)

      # Order is part of the contract — operators read the
      # report top-to-bottom.
      assert check_names == [
               "seed_intents",
               "operator_preferences",
               "emit_approval_required",
               "emit_hold",
               "mark_read",
               "archive",
               "delivery_preference_dispatch",
               "delivery_attempt_success",
               "delivery_attempt_transient_failure",
               "secret_hygiene"
             ]

      assert Enum.all?(report.checks, &(&1.status == :pass))
    end

    test "side-effect contract: no Oban jobs, no chain calls, no real delivery" do
      # `Bank.AdapterClient` is the chain HTTP boundary. The
      # smoke must never hit it. Pin via the `Req.Test`
      # config: every test stubs adapter calls so a real call
      # would error. We further check Oban + the existence of
      # only stub-channel deliveries.
      assert {:ok, _report} = Smoke.run()

      assert all_enqueued() == []

      # All delivery rows belong to one of the documented
      # external channels routed via the stub.
      workspace_id = Demo.demo_workspace_id()

      deliveries =
        workspace_id
        |> Notifications.list_for_workspace(status: :all, limit: 100)
        |> Enum.flat_map(&Deliveries.list_deliveries_for/1)

      Enum.each(deliveries, fn d ->
        assert d.channel in [:email, :webhook, :telegram]
      end)
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

  # Pinned by #237 P2: the runbook's "Implemented event types"
  # table and troubleshooting copy must stay in lock-step with
  # the emitter vocabulary on `main`. Pause/resume notifications
  # were shipped in #415 (`security.scope_paused` /
  # `security.scope_resumed`) but the runbook from #417 still
  # listed them as #234 follow-ups. The opt-in
  # `execution.confirmed` surface shipped in #418
  # (`Bank.Workspaces.Workspace.notify_execution_confirmed?/1`),
  # but the runbook still described it as silent and as a #234
  # follow-up. These tests fail fast when the runbook drifts
  # away from the emitter again.
  describe "runbook docs/runbooks/notifications.md" do
    @runbook_path "docs/runbooks/notifications.md"

    test "documents every emitter event type implemented on main" do
      runbook = File.read!(@runbook_path)

      for event_type <- [
            "decision.approval_required",
            "decision.hold",
            "decision.block",
            "execution.reverted",
            "execution.aborted",
            "execution.confirmed",
            "access.approved",
            "security.scope_paused",
            "security.scope_resumed"
          ] do
        assert runbook =~ "`#{event_type}`",
               "runbook is missing implemented event type `#{event_type}`"
      end
    end

    test "does not describe pause/resume as an unimplemented #234 follow-up" do
      runbook = File.read!(@runbook_path)

      refute runbook =~ "incident pause/resume",
             "runbook still claims incident pause/resume are #234 follow-ups; " <>
               "pause/resume notifications shipped in #415"
    end

    test "does not describe execution.confirmed as silent or as a #234 follow-up" do
      runbook = File.read!(@runbook_path)

      refute runbook =~ "`execution.confirmed` is silent",
             "runbook still claims `execution.confirmed` is silent; " <>
               "the opt-in surface shipped in #418 (workspace " <>
               "`notify_execution_confirmed` flag)"

      refute runbook =~ "opt-in `execution.confirmed`",
             "runbook still describes opt-in `execution.confirmed` as a " <>
               "#234 follow-up; it is implemented on main behind the " <>
               "workspace `notify_execution_confirmed` flag"
    end

    test "documents the notify_execution_confirmed opt-in flag" do
      runbook = File.read!(@runbook_path)

      assert runbook =~ "`notify_execution_confirmed`",
             "runbook should mention the workspace " <>
               "`notify_execution_confirmed` flag so operators know how " <>
               "to opt in to success-side rows"
    end
  end
end
