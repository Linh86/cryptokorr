defmodule Mix.Tasks.Bank.Quotes.SmokeTest do
  # `Bank.DataCase` checks out a Repo sandbox connection so the
  # smoke's call into `Bank.Ops.Health.snapshot/0` (which runs a
  # `stuck_plans` DB query) does not raise.
  use Bank.DataCase, async: false

  import ExUnit.CaptureIO

  alias Bank.Quotes.ProviderHealth

  @runbook_path Path.expand(
                  "../../../docs/runbooks/quote-provider-degraded-mode.md",
                  __DIR__
                )

  setup do
    ProviderHealth.reset()
    :ok
  end

  describe "mix bank.quotes.smoke" do
    test "passes against the local stub provider (all checks PASS)" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Quotes.Smoke.run([])
        end)

      for name <- ~w(
            quotes.stub_success
            quotes.attempted_provider_id
            quotes.health_recorded_after_success
            quotes.health_recorded_after_failure
            quotes.health_snapshot_rollup
            quotes.secret_hygiene
            quotes.live_provider_disabled_default
          ) do
        assert output =~ "PASS #{name}",
               "missing PASS line for #{name}: #{inspect(output)}"
      end

      assert output =~ "7 / 7 PASS"
      assert output =~ "No live network, no `.env` reads, no Tenderly HTTP."
      refute output =~ "FAIL"
    end

    test "stdout never carries provider secret markers" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Quotes.Smoke.run([])
        end)

      refute output =~ ~r/Authorization\s*:\s*Bearer/i
      refute output =~ ~r/\bsk_(live|test)_/
      refute output =~ ~r/\bpk_(live|test)_/
      refute output =~ ~r{://[^\s/@]+:[^\s/@]+@}
      refute output =~ "PRIVATE KEY"
    end
  end

  describe "docs/runbooks/quote-provider-degraded-mode.md" do
    test "documents the local stub-mode smoke command (#177)" do
      contents = File.read!(@runbook_path)

      assert contents =~ "mix bank.quotes.smoke",
             "runbook missing the `mix bank.quotes.smoke` recipe"

      assert contents =~ "7 / 7 PASS",
             "runbook missing the smoke command's expected PASS summary"

      assert contents =~ ~r/local stub.?mode smoke/i,
             "runbook missing a local stub-mode smoke section heading"
    end

    test "documents the staging live-provider recipe with config keys (#177)" do
      contents = File.read!(@runbook_path)

      # Env var names must be discoverable so an operator can wire
      # the staging deploy without grepping the source tree.
      assert contents =~ "TENDERLY_BASE_URL",
             "runbook missing TENDERLY_BASE_URL env var"

      assert contents =~ "TENDERLY_API_KEY",
             "runbook missing TENDERLY_API_KEY env var"

      assert contents =~ "Bank.Quotes.LiveProvider",
             "runbook missing the live provider config key"

      assert contents =~ ~r/staging.{0,40}live.?provider/i,
             "runbook missing the staging live-provider section"
    end

    test "documents the failure / degraded-mode contract (#176/#177)" do
      contents = File.read!(@runbook_path)

      assert contents =~ "provider_unavailable",
             "runbook missing the :provider_unavailable failure category"

      # Every category atom in the result_tag allowlist must be
      # documented so an operator looking at a readiness payload
      # can map it back to a known cause.
      for atom <- Bank.Quotes.ProviderHealth.result_tag_allowlist() do
        assert contents =~ Atom.to_string(atom),
               "runbook missing the #{inspect(atom)} category"
      end

      assert contents =~ ~r/degraded/i,
             "runbook missing degraded-mode coverage"

      assert contents =~ "/v1/health/deep",
             "runbook missing the /v1/health/deep reference"
    end

    test "names the stub vs live attribution boundary (#177)" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~s|"stub"|, "runbook missing the literal stub provider id"
      assert contents =~ ~s|"tenderly"|, "runbook missing the literal tenderly provider id"
      assert contents =~ ~s|"disabled"|, "runbook missing the literal disabled provider id"

      assert contents =~ "SimulationReport.provider",
             "runbook missing the per-decision provider attribution column"
    end

    test "marks 1inch / CCTP / Jupiter as quote/planning-only (#177 scope-control)" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/1inch/i, "runbook missing 1inch"
      assert contents =~ ~r/CCTP/, "runbook missing CCTP"
      assert contents =~ ~r/jupiter/i, "runbook missing Jupiter"

      assert contents =~ ~r/quote.{0,10}planning.?only/i,
             "runbook missing the quote/planning-only scope sentence"
    end

    test "does not overclaim mainnet / live-execution readiness (#177 scope-control)" do
      contents = File.read!(@runbook_path)

      # Live mainnet execution and broad swap-execution readiness
      # are explicitly post-MVP. The runbook may MENTION mainnet to
      # call out the boundary, but must never claim it as a
      # supported live-execution path.
      refute contents =~ ~r/mainnet (is )?supported/i,
             "runbook overclaims mainnet support"

      refute contents =~ ~r/production[ -]ready/i,
             "runbook overclaims production-ready posture"

      refute contents =~ ~r/guaranteed liquidity/i,
             "runbook overclaims liquidity"

      assert contents =~ ~r/(post-MVP|no live mainnet|Base Sepolia)/i,
             "runbook missing the testnet-only / post-MVP boundary callout"
    end

    test "never embeds a real-shape secret example (#177 secret hygiene)" do
      contents = File.read!(@runbook_path)

      # The runbook can reference category atoms (`Authorization` /
      # `Bearer` may appear in prose explaining what is REDACTED),
      # but no live-shape secret example must be present.
      refute contents =~ ~r/sk_live_[A-Za-z0-9]+/,
             "runbook embeds a real-shape sk_live_ secret"

      refute contents =~ ~r/sk_test_[A-Za-z0-9]{6,}/,
             "runbook embeds a real-shape sk_test_ secret"

      refute contents =~ ~r/pk_live_[A-Za-z0-9]+/,
             "runbook embeds a real-shape pk_live_ secret"

      refute contents =~ ~r/pk_test_[A-Za-z0-9]{6,}/,
             "runbook embeds a real-shape pk_test_ secret"

      refute contents =~ ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
             "runbook embeds a PEM private-key block"

      # Credentialed URL pattern — `://user:password@host`.
      refute contents =~ ~r{://[A-Za-z0-9_.\-]+:[A-Za-z0-9_.\-]+@},
             "runbook embeds a credentialed URL"
    end
  end
end
