defmodule Mix.Tasks.Bank.Swap.SmokeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @runbook_path Path.expand(
                  "../../../docs/runbooks/swap-dispatch.md",
                  __DIR__
                )

  describe "mix bank.swap.smoke" do
    test "passes against the synthetic Base Sepolia USDC route (all checks PASS)" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Swap.Smoke.run([])
        end)

      for name <- ~w(
            swap.route_validation
            swap.route_artifacts
            swap.route_round_trip
            swap.safety_gate_accepts
            swap.safety_gate_rejects_mainnet
            swap.safety_gate_rejects_stale_route
            swap.safety_gate_rejects_minimum_above_expected
            swap.dispatch_envelope_shape
            swap.secret_hygiene
            swap.public_artifact_set
          ) do
        assert output =~ "PASS #{name}",
               "missing PASS line for #{name}: #{inspect(output)}"
      end

      assert output =~ "10 / 10 PASS"
      assert output =~ "Phoenix-side shape only. No chain RPC, no adapter HTTP, no broadcast."
      refute output =~ "FAIL"
    end

    test "stdout never carries provider secret markers" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Swap.Smoke.run([])
        end)

      refute output =~ ~r/Authorization\s*:\s*Bearer/i
      refute output =~ ~r/\bsk_(live|test)_/
      refute output =~ ~r/\bpk_(live|test)_/
      refute output =~ ~r{://[^\s/@]+:[^\s/@]+@}
      refute output =~ "PRIVATE KEY"
    end
  end

  describe "docs/runbooks/swap-dispatch.md" do
    test "documents the dry-run smoke command (#196)" do
      contents = File.read!(@runbook_path)

      assert contents =~ "mix bank.swap.smoke",
             "runbook missing the `mix bank.swap.smoke` recipe"

      assert contents =~ "10 / 10 PASS",
             "runbook missing the smoke command's expected PASS summary"

      assert contents =~ ~r/Dry-run smoke/i,
             "runbook missing a dry-run smoke section heading"
    end

    test "documents the live-broadcast operator flow with explicit consent (#196)" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/Live broadcast/i,
             "runbook missing live-broadcast section heading"

      assert contents =~ "request_manual_execution",
             "runbook missing the operator broadcast primitive"

      assert contents =~ ~r/operator.{0,40}consent/i,
             "runbook missing the operator-consent callout"

      # Operator pre-flight checklist must reference the env keys
      # the broadcast depends on (presence-only, no values).
      assert contents =~ "Bank.AdapterClient",
             "runbook missing Bank.AdapterClient env reference"

      assert contents =~ ":dispatch_secret",
             "runbook missing :dispatch_secret pre-flight"

      assert contents =~ ":callback_secret",
             "runbook missing :callback_secret pre-flight"
    end

    test "documents quote-only / dry-run / live-broadcast split (#196)" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/Quote-only/i,
             "runbook missing the quote-only section"

      assert contents =~ ~r/Dry-run smoke/i,
             "runbook missing the dry-run smoke section"

      assert contents =~ ~r/Live broadcast/i,
             "runbook missing the live-broadcast section"
    end

    test "lists public artifacts to capture for any broadcast (#196)" do
      contents = File.read!(@runbook_path)

      for artifact <- ~w(
            intent_id
            decision_id
            plan_id
            route_hash
            route_provider
            expected_output_amount
            minimum_output_amount
            actual_output_amount
            tx_refs
            block_number
          ) do
        assert contents =~ artifact,
               "runbook missing the `#{artifact}` public-artifact callout"
      end
    end

    test "documents kill-switch / rollback (#196)" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/Kill switch.{0,5}rollback/i,
             "runbook missing the kill-switch / rollback section"

      assert contents =~ "Bank.Security.PauseState",
             "runbook missing the pause primitive"

      assert contents =~ ~r/cannot retract/i,
             "runbook missing the no-retract caveat for in-flight UserOps"
    end

    test "marks 1inch / CCTP / Jupiter as quote/planning-only (#196 scope-control)" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/1inch/i, "runbook missing 1inch"
      assert contents =~ ~r/CCTP/, "runbook missing CCTP"
      assert contents =~ ~r/jupiter/i, "runbook missing Jupiter"

      assert contents =~ ~r/quote.{0,15}planning.?only/i,
             "runbook missing the quote/planning-only scope sentence"
    end

    test "limitations recap covers Base-Sepolia / exact-input / no-mainnet (#196 scope-control)" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/limitations/i,
             "runbook missing a limitations recap"

      assert contents =~ ~r/Base Sepolia only/i,
             "runbook missing the Base Sepolia-only limitation"

      assert contents =~ ~r/exact-input only/i,
             "runbook missing the exact-input-only limitation"

      assert contents =~ ~r/no live mainnet|No live mainnet|No.{0,10}mainnet|post-MVP/,
             "runbook missing the no-live-mainnet limitation"

      assert contents =~ ~r/no guaranteed.{0,30}liquidity/i,
             "runbook missing the no-guaranteed-liquidity limitation"
    end

    test "does not overclaim mainnet / CCTP-live / 1inch-live / Jupiter-live (#196 scope-control)" do
      contents = File.read!(@runbook_path)

      refute contents =~ ~r/mainnet (is )?supported/i,
             "runbook overclaims mainnet support"

      # Tight overclaim patterns: each provider's name immediately
      # followed by an "is live / supports live / is the live
      # router" claim. Wider proximity matches false-positive on
      # legitimate prose like "1inch — quote/planning only. Live
      # execution flows through the 0x router."
      refute contents =~ ~r/CCTP\s+(?:is\s+|supports\s+)?live/i,
             "runbook overclaims CCTP live execution"

      refute contents =~ ~r/CCTP.{0,15}(?:live\s+(?:bridge|broadcast|cross-chain))/i,
             "runbook overclaims CCTP live bridging"

      refute contents =~ ~r/1inch\s+(?:is\s+|supports\s+)?live/i,
             "runbook overclaims 1inch live execution"

      refute contents =~ ~r/1inch.{0,15}live\s+(?:swap|router|broadcast)/i,
             "runbook overclaims 1inch live swap"

      refute contents =~ ~r/jupiter\s+(?:is\s+|supports\s+)?live/i,
             "runbook overclaims Jupiter live execution"

      refute contents =~ ~r/jupiter.{0,15}live\s+(?:swap|router|broadcast)/i,
             "runbook overclaims Jupiter live swap"

      refute contents =~ ~r/unlimited token support/i,
             "runbook overclaims arbitrary token support"

      refute contents =~ ~r/guaranteed (liquidity|fill|output)/i,
             "runbook overclaims a liquidity / fill / output guarantee"

      refute contents =~ ~r/production[ -]ready/i,
             "runbook overclaims production-ready posture"
    end

    test "never embeds a real-shape secret example (#196 secret hygiene)" do
      contents = File.read!(@runbook_path)

      refute contents =~ ~r/sk_live_[A-Za-z0-9]{6,}/,
             "runbook embeds a real-shape sk_live_ secret"

      refute contents =~ ~r/sk_test_[A-Za-z0-9]{6,}/,
             "runbook embeds a real-shape sk_test_ secret"

      refute contents =~ ~r/pk_live_[A-Za-z0-9]{6,}/,
             "runbook embeds a real-shape pk_live_ secret"

      refute contents =~ ~r/pk_test_[A-Za-z0-9]{6,}/,
             "runbook embeds a real-shape pk_test_ secret"

      refute contents =~ ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
             "runbook embeds a PEM private-key block"

      refute contents =~ ~r{://[A-Za-z0-9_.\-]+:[A-Za-z0-9_.\-]+@},
             "runbook embeds a credentialed URL"

      refute contents =~ ~r/Authorization:\s*Bearer\s+[A-Za-z0-9._-]{8,}/,
             "runbook embeds a real-shape Authorization: Bearer header"
    end
  end
end
