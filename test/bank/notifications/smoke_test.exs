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
end
