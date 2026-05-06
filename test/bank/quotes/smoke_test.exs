defmodule Bank.Quotes.SmokeTest do
  # async: false — `Bank.Quotes.ProviderHealth` is a singleton ETS
  # table shared across the test process tree and the smoke
  # mutates it. `Bank.DataCase` checks out a Repo sandbox
  # connection so the smoke's call into `Bank.Ops.Health.snapshot/0`
  # (which runs a `stuck_plans` DB query) does not raise.
  use Bank.DataCase, async: false

  alias Bank.Quotes.{ProviderHealth, Smoke}

  setup do
    ProviderHealth.reset()
    :ok
  end

  describe "Bank.Quotes.Smoke.run/0" do
    test "passes every check against the local stub provider" do
      assert {:ok, report} = Smoke.run()

      check_names = Enum.map(report.checks, & &1.name)

      assert "quotes.stub_success" in check_names
      assert "quotes.attempted_provider_id" in check_names
      assert "quotes.health_recorded_after_success" in check_names
      assert "quotes.health_recorded_after_failure" in check_names
      assert "quotes.health_snapshot_rollup" in check_names
      assert "quotes.secret_hygiene" in check_names
      assert "quotes.live_provider_disabled_default" in check_names

      assert report.status == :pass
      assert report.passed == report.total
      assert report.total == length(check_names)
      assert Enum.all?(report.checks, &(&1.status == :pass))
    end

    test "restores prior ProviderHealth state after the run (idempotent)" do
      ProviderHealth.record_success("tenderly")
      ProviderHealth.record_success("tenderly")

      assert {:ok, _report} = Smoke.run()

      restored = ProviderHealth.get("tenderly")
      assert restored.success_count >= 1
      assert restored.status in [:healthy, :degraded]
    end

    test "leaves no synthetic stub failure in the readiness payload" do
      assert {:ok, _report} = Smoke.run()

      stub = ProviderHealth.get("stub")
      # The smoke deliberately injects a synthetic stub failure in
      # the middle of its run; the after-clause must scrub it out.
      assert stub.failure_count == 0
      assert stub.last_failure_reason == nil
    end

    test "every check carries a non-empty allowlisted detail string" do
      assert {:ok, report} = Smoke.run()

      Enum.each(report.checks, fn check ->
        assert is_binary(check.detail)
        assert String.length(check.detail) > 0

        # Detail strings are operator-readable; pin that they do
        # not accidentally carry secret-shaped tokens.
        refute check.detail =~ ~r/Authorization\s*:\s*Bearer/i
        refute check.detail =~ ~r/\bsk_(live|test)_/
        refute check.detail =~ ~r/\bpk_(live|test)_/
        refute check.detail =~ ~r{://[^\s/@]+:[^\s/@]+@}
        refute check.detail =~ "PRIVATE KEY"
      end)
    end
  end
end
