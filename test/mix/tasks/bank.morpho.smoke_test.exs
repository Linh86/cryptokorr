defmodule Mix.Tasks.Bank.Morpho.SmokeTest do
  use Bank.DataCase, async: false

  import ExUnit.CaptureIO

  alias Bank.Demo
  alias Bank.DefiVenues.Morpho.Smoke

  describe "mix bank.morpho.smoke" do
    test "prints PASS for every check on a freshly seeded workspace" do
      :ok = Demo.seed()

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Morpho.Smoke.run([])
        end)

      for check_name <- Smoke.check_order() do
        assert output =~ "PASS] #{check_name}",
               "expected PASS line for `#{check_name}`; output:\n#{output}"
      end

      assert output =~ "Result: PASS"
      assert output =~ "No chain RPC, no Morpho HTTP, no execution dispatch."
    end

    test "exits with shutdown 1 when the demo workspace is not seeded" do
      refute Demo.demo_workspace_id()

      output =
        capture_io(fn ->
          assert catch_exit(Mix.Tasks.Bank.Morpho.Smoke.run([])) == {:shutdown, 1}
        end)

      assert output =~ "FAIL] seed"
      assert output =~ "mix bank.demo.seed"
      assert output =~ "Result: FAIL"
    end
  end

  # Pinned source-level invariants — the smoke task runner must
  # not regress to reading `.env`, calling the chain adapter, or
  # making real Morpho HTTP calls. These checks scan the source
  # text rather than relying on runtime stubs so a future edit
  # cannot silently reintroduce a forbidden boundary.
  describe "task source carries no forbidden boundaries" do
    @task_path "lib/mix/tasks/bank.morpho.smoke.ex"
    @runner_path "lib/bank/defi_venues/morpho/smoke.ex"

    test "task source does not call env / adapter / Morpho HTTP" do
      contents = File.read!(@task_path)

      # Match call shape (`Mod.fun(`) — bare mentions in
      # docstrings ("no Bank.AdapterClient calls") are fine.
      refute Regex.match?(~r/System\.get_env\(/, contents)
      refute Regex.match?(~r/Bank\.AdapterClient\.[a-z_]+\(/, contents)
      refute Regex.match?(~r/Bank\.DefiVenues\.Morpho\.Client\.[a-z_]+\(/, contents)
    end

    test "runner source does not call env / adapter / Morpho HTTP" do
      contents = File.read!(@runner_path)

      refute Regex.match?(~r/System\.get_env\(/, contents)
      refute Regex.match?(~r/Bank\.AdapterClient\.[a-z_]+\(/, contents)
      refute Regex.match?(~r/Bank\.DefiVenues\.Morpho\.Client\.[a-z_]+\(/, contents)
    end
  end
end
