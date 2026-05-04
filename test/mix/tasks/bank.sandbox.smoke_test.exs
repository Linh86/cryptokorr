defmodule Mix.Tasks.Bank.Sandbox.SmokeTest do
  use Bank.DataCase, async: false

  import ExUnit.CaptureIO

  alias Bank.Demo

  describe "mix bank.sandbox.smoke" do
    test "passes against the seeded sandbox dataset, prints the named checks, exits 0" do
      :ok = Demo.seed()

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Sandbox.Smoke.run([])
        end)

      # All eight checks named in the task moduledoc must surface in
      # the output as PASS lines on a green run.
      for name <-
            ~w(health seeded_workspace create_intent show_intent simulate_reasons approval cancel_flow replay) do
        assert output =~ "PASS #{name}", "missing PASS line for #{name}: #{inspect(output)}"
      end

      assert output =~ "8 / 8 PASS"
      refute output =~ "FAIL"
    end

    test "with --seed runs Bank.Demo.seed/0 first and prints the seed-message" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Sandbox.Smoke.run(["--seed"])
        end)

      # The --seed flag's job is to ensure the dataset is in place
      # before the checks. After the task returns, the seed must
      # have run successfully and the task must have passed.
      assert Bank.Workspaces.get_workspace_by_slug("sandbox-demo") != nil
      assert output =~ "seeding sandbox dataset (--seed)"
      assert output =~ "8 / 8 PASS"
    end

    test "fails loudly when a required seeded fixture is missing (no fake-pass on stub regression)" do
      :ok = Demo.seed()

      # Simulate a regression where the cancelled-intent scenario
      # is removed from the seed (e.g., a downstream slice changes
      # the seed shape without updating the smoke). The cancel_flow
      # check MUST surface this as a FAIL — silent green is the
      # anti-acceptance for #240's "fails on stubbed endpoint
      # regressions" bullet.
      import Ecto.Query

      Bank.Repo.update_all(
        from(i in Bank.Intents.AgentIntent,
          where: i.state == :cancelled
        ),
        set: [state: :submitted]
      )

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/bank\.sandbox\.smoke FAILED/, fn ->
            Mix.Tasks.Bank.Sandbox.Smoke.run([])
          end
        end)

      assert output =~ "FAIL cancel_flow"
      refute output =~ "8 / 8 PASS"
    end

    test "with --quiet suppresses PASS lines but still prints the summary" do
      :ok = Demo.seed()

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Sandbox.Smoke.run(["--quiet"])
        end)

      refute output =~ "PASS health"
      refute output =~ "PASS replay"
      assert output =~ "8 / 8 PASS"
    end

    # #240 acceptance: "Runs locally without secrets. Does not source
    # chain `.env`." This is a static guard against a future regression
    # adding a secret read into the task. The runtime guard (no
    # AdapterClient call, no chain RPC) is implicit because none of the
    # checks reach those modules.
    test "task source carries no secret-shaped literals or .env reads" do
      path = Path.expand("../../../lib/mix/tasks/bank.sandbox.smoke.ex", __DIR__)
      assert File.exists?(path)
      contents = File.read!(path)

      refute Regex.match?(~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/, contents)
      refute Regex.match?(~r/\b(sk_live|pk_live|sk_test)_[A-Za-z0-9_-]+/, contents)
      refute Regex.match?(~r/\bauthorization\s*:\s*\"?bearer\s+/i, contents)
      refute Regex.match?(~r{https?://[^/\s\"`]+:[^@/\s\"`]+@[A-Za-z0-9.-]+}, contents)
      refute Regex.match?(~r/System\.get_env\b/, contents)
      refute Regex.match?(~r/File\.read.*\.env\b/, contents)
      # Bank.AdapterClient as an actual call site (with `.func(`):
      # the moduledoc legitimately mentions the module name in
      # backticks to declare the no-call posture.
      refute Regex.match?(~r/Bank\.AdapterClient\.[a-z_][A-Za-z0-9_]*\(/, contents)

      # Banned production/mainnet tokens in code-emitting position
      # (string literals or atoms). Comments are fine.
      for pattern <- [
            ~r/"mainnet"/,
            ~r/:mainnet\b/,
            ~r/"production"/,
            ~r/:production\b/,
            ~r/"live"/,
            ~r/:live\b/
          ] do
        refute Regex.match?(pattern, contents),
               "task source contains banned production/mainnet token (matched #{inspect(pattern)})"
      end
    end
  end
end
