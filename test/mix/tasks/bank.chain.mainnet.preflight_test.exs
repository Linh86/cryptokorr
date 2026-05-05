defmodule Mix.Tasks.Bank.Chain.Mainnet.PreflightTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  describe "mix bank.chain.mainnet.preflight" do
    # The Mix task wraps `Bank.Chains.MainnetPreflight.run/0` with
    # no overrides, so in `:test` it reads the real `System.get_env/0`.
    # That env has none of `BASE_RPC_URL` / `BUNDLER_RPC_URL` /
    # `BASE_CHAIN_ID` / `SMART_ACCOUNT_ADDRESS` set, so the rollup
    # collapses to `:not_configured` and the task exits 0 with PASS
    # lines (a deliberately-absent dependency on local/dev is
    # benign — same posture as `Bank.Ops.Health.snapshot/0`).
    test "with no env set the task exits 0 and prints :not_configured PASS lines" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Chain.Mainnet.Preflight.run([])
        end)

      assert output =~ "running 8 checks"
      assert output =~ "PASS config_present"
      assert output =~ "config_missing:"
      assert output =~ "8 / 8 PASS"
      refute output =~ "FAIL"
    end

    test "with --quiet suppresses PASS lines but keeps the summary" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Chain.Mainnet.Preflight.run(["--quiet"])
        end)

      refute output =~ "PASS config_present"
      refute output =~ "running 8 checks"
      assert output =~ "8 / 8 PASS"
    end
  end
end
