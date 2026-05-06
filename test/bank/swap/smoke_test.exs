defmodule Bank.Swap.SmokeTest do
  use ExUnit.Case, async: true

  alias Bank.Swap.Smoke

  describe "Bank.Swap.Smoke.run/0" do
    test "passes every check on a synthetic Base Sepolia USDC route" do
      assert {:ok, report} = Smoke.run()

      check_names = Enum.map(report.checks, & &1.name)

      assert "swap.route_validation" in check_names
      assert "swap.route_artifacts" in check_names
      assert "swap.route_round_trip" in check_names
      assert "swap.safety_gate_accepts" in check_names
      assert "swap.safety_gate_rejects_mainnet" in check_names
      assert "swap.safety_gate_rejects_stale_route" in check_names
      assert "swap.safety_gate_rejects_minimum_above_expected" in check_names
      assert "swap.dispatch_envelope_shape" in check_names
      assert "swap.secret_hygiene" in check_names
      assert "swap.public_artifact_set" in check_names

      assert report.status == :pass
      assert report.passed == report.total
      assert report.total == length(check_names)
      assert Enum.all?(report.checks, &(&1.status == :pass))
    end

    test "every check carries a non-empty allowlisted detail string" do
      assert {:ok, report} = Smoke.run()

      Enum.each(report.checks, fn check ->
        assert is_binary(check.detail)
        assert String.length(check.detail) > 0

        # Detail strings end up in operator stdout — pin no
        # secret-shaped tokens leak through them.
        refute check.detail =~ ~r/Authorization\s*:\s*Bearer/i
        refute check.detail =~ ~r/\bsk_(live|test)_/
        refute check.detail =~ ~r/\bpk_(live|test)_/
        refute check.detail =~ ~r{://[^\s/@]+:[^\s/@]+@}
        refute check.detail =~ "PRIVATE KEY"
      end)
    end

    test "synthetic_route/0 is Base Sepolia + USDC + 0x" do
      route = Smoke.synthetic_route()

      assert route.chain == "base-sepolia"
      assert route.chain_id == 84_532
      assert route.source_asset == "USDC"
      assert route.destination_asset == "USDC"
      assert route.route_provider == "zerox"
      assert Decimal.equal?(route.value, Decimal.new("0"))
    end
  end

  describe "no live network surface" do
    @smoke_path Path.expand("../../../lib/bank/swap/smoke.ex", __DIR__)
    @task_path Path.expand("../../../lib/mix/tasks/bank.swap.smoke.ex", __DIR__)

    setup do
      smoke = File.read!(@smoke_path)
      task = File.read!(@task_path)
      {:ok, smoke: smoke, task: task, both: smoke <> "\n" <> task}
    end

    test "no `.env` sourcing or raw env reads of secret keys", %{both: src} do
      refute src =~ ~r/source\s+\.env\b/i
      refute src =~ ~r/dotenv/i
      refute src =~ ~r/System\.get_env\(\s*"AUTHORIZATION/i
      refute src =~ ~r/System\.get_env\(\s*"BEARER/i
      refute src =~ ~r/System\.get_env\(\s*"TENDERLY_API_KEY/i
    end

    test "no live adapter dispatch / chain RPC / bundler call", %{both: src} do
      # The smoke must not call any adapter-dispatch primitive or
      # any chain RPC / bundler method. Docstring mentions of these
      # modules (explaining what the smoke does NOT do) are fine —
      # we check the call sites, not the prose.
      refute src =~ ~r/AdapterClient\.dispatch_swap\(/
      refute src =~ ~r/AdapterClient\.dispatch_morpho/
      refute src =~ ~r/AdapterClient\.dispatch_transfer/
      refute src =~ ~r/AdapterClient\.dispatch_revoke/
      refute src =~ ~r/AdapterClient\.dispatch_grant/
      refute src =~ ~r/LiveProvider\.preview/
      refute src =~ ~r/sendUserOperation/i
      refute src =~ ~r/eth_(call|sendRawTransaction|sendTransaction)/i
    end

    test "smoke source pins mainnet rejection at the safety gate", %{smoke: src} do
      # Positive assertion: the smoke MUST exercise the
      # mainnet-rejected branch so a future regression flipping
      # `:swap_chain_not_supported` on for `chain: "base"` is
      # caught by the runner's own check.
      assert String.contains?(src, "safety_gate_rejects_mainnet")
      assert String.contains?(src, ":swap_chain_not_supported")
    end

    test "no withdraw / redeem / borrow / leverage vocabulary on the smoke surface", %{
      both: src
    } do
      refute src =~ ~r/\bwithdraw\b/i
      refute src =~ ~r/\bredeem\b/i
      refute src =~ ~r/\bborrow\b/i
      refute src =~ ~r/\bleverage\b/i
      refute src =~ ~r/\bmargin\b/i
      refute src =~ ~r/\bperpetual\b/i
    end
  end
end
