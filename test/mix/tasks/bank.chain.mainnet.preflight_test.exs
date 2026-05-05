defmodule Mix.Tasks.Bank.Chain.Mainnet.PreflightTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @rehearsal_runbook_path Path.expand(
                            "../../../docs/runbooks/base-mainnet-rehearsal.md",
                            __DIR__
                          )

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

  describe "docs/runbooks/base-mainnet-rehearsal.md (#180)" do
    test "exists at the expected path" do
      assert File.exists?(@rehearsal_runbook_path),
             "base mainnet rehearsal runbook missing at #{@rehearsal_runbook_path}"
    end

    test "is explicit about the no-broadcast boundary" do
      contents = File.read!(@rehearsal_runbook_path)

      assert contents =~ ~r/no broadcast/i,
             "runbook missing the 'no broadcast' boundary statement"

      assert contents =~ ~r/no transaction hash/i,
             "runbook missing the 'no transaction hash' acceptance criterion (#180)"

      assert contents =~ ~r/no\s+`?eth_sendRawTransaction`?/i,
             "runbook missing the explicit 'no eth_sendRawTransaction' callout"

      assert contents =~ ~r/no\s+UserOp/i,
             "runbook missing the explicit 'no UserOp submission' callout"

      assert contents =~ ~r/no\s+(`?Bank\.AdapterClient`?|adapter\s+dispatch)/i,
             "runbook missing the 'no Bank.AdapterClient dispatch' callout"

      assert contents =~ ~r/no\s+signing/i,
             "runbook missing the explicit 'no signing' callout"
    end

    test "documents that .env is not sourced" do
      contents = File.read!(@rehearsal_runbook_path)

      assert contents =~ ~r/`?\.env`?/,
             "runbook missing the .env discussion"

      assert contents =~ ~r/(no\s+`?\.env`?|never\s+`?source.+\.env`?|not\s+sourced)/i,
             "runbook missing the explicit no-.env-sourcing posture"
    end

    test "names every step that the rehearsal walks through" do
      contents = File.read!(@rehearsal_runbook_path)

      assert contents =~ "mix bank.chain.mainnet.preflight",
             "runbook missing the preflight Mix command"

      assert contents =~ "mix bank.observability.smoke",
             "runbook missing the observability smoke Mix command"

      assert contents =~ ~r/mainnet_enabled/,
             "runbook missing the workspace mainnet_enabled gate description"

      assert contents =~ ~r/Bank\.Security\.paused\?/,
             "runbook missing the pause / kill-switch posture check"
    end

    test "documents every preflight failure detail with a next operator action" do
      contents = File.read!(@rehearsal_runbook_path)

      # Every detail string drawn from the
      # `Bank.Chains.MainnetPreflight` moduledoc allowlist must
      # appear in the failure-modes table.
      details = [
        "config_missing",
        "chain_id_declared_mismatch",
        "chain_id_rpc_mismatch",
        "entrypoint_missing",
        "smart_account_address_invalid",
        "smart_account_not_deployed",
        "bundler_url_invalid",
        "transport_error",
        "http_5xx",
        "http_4xx",
        "rpc_error",
        "invalid_response",
        "rpc_check_raised",
        "rpc_check_timeout"
      ]

      for detail <- details do
        assert contents =~ detail,
               "runbook failure-modes table missing detail #{inspect(detail)}"
      end
    end

    test "tells the operator what to do if a transaction hash appears" do
      contents = File.read!(@rehearsal_runbook_path)

      # Acceptance criterion: a tx hash sighting must be treated as
      # a posture violation, not a soft warning. The runbook's
      # failure-modes table must walk the operator through pause +
      # incident-runbook follow-up.
      assert contents =~ ~r/unexpected transaction hash/i,
             "runbook missing the 'unexpected transaction hash' failure row"

      assert contents =~ ~r/Bank\.Security\.pause/,
             "runbook missing the pause-on-violation guidance"

      assert contents =~ ~r/incident-runbook\.md/,
             "runbook missing cross-link to docs/incident-runbook.md"
    end

    test "cross-links to the existing mainnet preflight + gate proofs" do
      contents = File.read!(@rehearsal_runbook_path)

      assert contents =~ "test/bank/mainnet_gate_test.exs",
             "runbook missing cross-link to mainnet_gate_test.exs"

      assert contents =~ "test/bank/chains/mainnet_preflight_test.exs",
             "runbook missing cross-link to mainnet_preflight_test.exs"

      assert contents =~ "production-observability.md",
             "runbook missing cross-link to production-observability runbook"
    end

    test "names the dependency chain back to the parent epic" do
      contents = File.read!(@rehearsal_runbook_path)

      assert contents =~ "#166", "runbook missing reference to epic #166"
      assert contents =~ "#178", "runbook missing reference to mainnet flag #178"
      assert contents =~ "#179", "runbook missing reference to preflight #179"
      assert contents =~ "#180", "runbook missing reference to itself (#180)"
    end
  end
end
