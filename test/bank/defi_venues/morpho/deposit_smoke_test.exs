defmodule Bank.DefiVenues.Morpho.DepositSmokeTest do
  @moduledoc """
  Coverage for `Bank.DefiVenues.Morpho.DepositSmoke` (#209) — the
  explicit-confirmation Base Sepolia ERC-4626 USDC deposit smoke.

  Two layers of assertion:

    1. **Refused mode** — without `:confirm`, the runner returns a
       `:refused` report carrying the operator pre-flight checklist.
       The Mix task exits non-zero on this and never broadcasts.
    2. **Source hygiene** — regex scans of the runner + Mix task
       sources fail closed if a future edit introduces `.env`
       sourcing, raw `Authorization` / `Bearer` / `private_key` /
       PEM marker / tokenized URL strings, the mainnet `chain:
       "base"` as a supported live path, or any withdraw / redeem
       / borrow / leverage / looping vocabulary on the smoke
       surface.

  The live-mode end-to-end path (intent → evaluate → approve →
  plan → adapter dispatch) is intentionally NOT exercised in this
  test file: a true live test would require a configured chain
  adapter, a funded smart account, and a real bundler — none of
  which CI has. The dispatch wiring is tested in
  `test/bank/decisions/morpho_deposit_plan_test.exs` (#206) and
  `test/bank/decisions/morpho_dispatch_safety_test.exs`. This
  smoke's value-add is the operator-facing `--confirm` boundary
  + the source-pin invariants that make broadcasts in CI
  impossible.
  """

  use ExUnit.Case, async: true

  alias Bank.DefiVenues.Morpho.DepositSmoke

  @runner_path "lib/bank/defi_venues/morpho/deposit_smoke.ex"
  @task_path "lib/mix/tasks/bank.morpho.deposit_smoke.ex"
  @runbook_path "docs/runbooks/morpho-deposits.md"

  describe "refused mode (no --confirm)" do
    test "returns {:refused, report} when :confirm is absent" do
      assert {:refused, report} = DepositSmoke.run([])
      assert report.mode == :refused
      assert report.status == :refused
      assert report.reason == :missing_confirm
    end

    test "returns {:refused, report} when :confirm is explicitly false" do
      assert {:refused, _report} = DepositSmoke.run(confirm: false)
    end

    test "refused report carries the operator pre-flight checklist" do
      assert {:refused, report} = DepositSmoke.run([])

      check_names = Enum.map(report.checks, & &1.name)

      assert "missing_confirm" in check_names
      assert "preflight_chain" in check_names
      assert "preflight_asset" in check_names
      assert "preflight_vault" in check_names
      assert "preflight_phoenix_env" in check_names
      assert "preflight_adapter_env" in check_names
      assert "preflight_no_withdraw" in check_names
      assert "expected_artifacts" in check_names
    end

    test "refused report carries empty artifacts (no leak when broadcast didn't happen)" do
      assert {:refused, report} = DepositSmoke.run([])

      assert report.artifacts.intent_id == nil
      assert report.artifacts.plan_id == nil
      assert report.artifacts.decision_id == nil
      assert report.artifacts.execution_status == nil
      assert report.artifacts.tx_refs == []
      assert report.artifacts.vault_address == nil
      # Constants surface — chain + asset are pinned.
      assert report.artifacts.chain == "base-sepolia"
      assert report.artifacts.asset == "USDC"
    end
  end

  describe "source hygiene — no .env / no secrets / no mainnet / no withdraw" do
    setup do
      runner = File.read!(@runner_path)
      task = File.read!(@task_path)
      both = runner <> "\n" <> task
      {:ok, runner: runner, task: task, both: both}
    end

    test "no `.env` sourcing or raw env reads of network/secret keys", %{both: src} do
      # Don't shell out to source a `.env` file. The literal
      # "source .env" / "dotenv" patterns must not appear.
      refute src =~ ~r/source\s+\.env\b/i,
             "smoke surface must never `source .env`"

      refute src =~ ~r/dotenv/i,
             "smoke surface must never use a dotenv loader"

      # Raw env reads of network endpoints / secret material must
      # NOT happen on the smoke surface. The smoke asserts presence
      # of Phoenix-side config by NAME via Application.get_env, not
      # by reading raw env vars.
      refute src =~ ~r/System\.get_env\(\s*"BASE_RPC_URL/i,
             "smoke surface must not read raw RPC URLs from env directly"

      refute src =~ ~r/System\.get_env\(\s*"BUNDLER_RPC_URL/i,
             "smoke surface must not read raw bundler URLs from env directly"

      refute src =~ ~r/System\.get_env\(\s*"OPERATOR_KEY/i,
             "smoke surface must not read operator private key from env directly"

      refute src =~ ~r/System\.get_env\(\s*"DISPATCH_SECRET/i,
             "smoke surface must not read dispatch secret from env directly"
    end

    test "no raw secret-bearing strings in the smoke source", %{both: src} do
      refute src =~ ~r/Authorization\s*:/i,
             "smoke surface must not embed raw Authorization headers"

      refute src =~ ~r/Bearer\s+[A-Za-z0-9]/,
             "smoke surface must not embed raw Bearer tokens"

      refute src =~ ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
             "smoke surface must not embed raw PEM private-key markers"

      refute src =~ ~r/sk_(test|live)_/i,
             "smoke surface must not embed raw provider secret prefixes"

      refute src =~ ~r{blue-api\.morpho\.org/graphql\?token=},
             "smoke surface must not embed tokenized Morpho URLs"
    end

    test "no mainnet chain accepted as a supported smoke path", %{both: src} do
      # The smoke surface mentions "base" only in the context of
      # explicitly REJECTING mainnet. There must be no
      # `chain: "base"` as a configured value, no
      # `chain_id: 8453`, and no `mainnet_enabled` opt-in path.
      refute src =~ ~r/@chain\s+"base"\b/,
             "smoke surface must not pin `@chain` to mainnet"

      refute src =~ ~r/@chain_id\s+8453\b/,
             "smoke surface must not pin `@chain_id` to mainnet"

      refute src =~ ~r/mainnet_enabled.*true/,
             "smoke surface must not opt the smoke into mainnet"

      # Positive assertion: the smoke must declare base-sepolia.
      assert src =~ ~r/@chain\s+"base-sepolia"/,
             "smoke surface must pin chain to `base-sepolia`"

      assert src =~ ~r/@chain_id\s+84_532/,
             "smoke surface must pin chain_id to 84_532"
    end

    test "no withdraw / redeem / borrow / leverage / looping vocabulary", %{both: src} do
      forbidden = ~w(
        withdraw
        redeem
        borrow
        leverage
        looping
      )

      Enum.each(forbidden, fn token ->
        # The runner moduledoc explicitly says "no withdraw / redeem"
        # in the context of REJECTING those paths. Allow the
        # negative-form mention "no withdraw" / "withdraw is
        # operator-only" / "withdraw / redeem is operator-only" but
        # forbid any function name or function call carrying the
        # token — i.e. the token must not appear as
        # `def_withdraw`, `:withdraw =>`, `withdraw_`, etc.
        # Practical rule: any line with the token that is NOT a
        # comment / docstring / "operator-only" framing fails the
        # source pin.
        offending_lines =
          src
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, token))
          |> Enum.reject(fn line ->
            String.starts_with?(String.trim(line), "#") or
              String.contains?(line, "operator-only") or
              String.contains?(line, "never agent-initiated") or
              String.contains?(line, "no withdraw") or
              String.contains?(line, "No withdraw") or
              String.contains?(line, "no withdraw / redeem") or
              String.contains?(line, "carries no withdraw") or
              String.contains?(line, "no call into any withdraw") or
              String.contains?(line, "preflight_no_withdraw") or
              String.contains?(line, "tracked under #207") or
              String.contains?(line, "@moduledoc") or
              String.contains?(line, "@shortdoc") or
              String.contains?(line, "@doc") or
              String.contains?(line, "context of REJECTING")
          end)

        assert offending_lines == [],
               "smoke surface mentions `#{token}` outside operator-only / negative framing:\n  " <>
                 Enum.join(offending_lines, "\n  ")
      end)
    end

    test "no arbitrary calldata field referenced on the wire", %{both: src} do
      # The dispatch wire envelope (Bank.AdapterClient.dispatch_morpho_deposit/2)
      # carries no `calldata` field. The smoke must not synthesize
      # one or accept one as input.
      refute src =~ ~r/:calldata\s*=>/,
             "smoke surface must not synthesize a `:calldata` field"

      refute src =~ ~r/"calldata"\s*=>/,
             "smoke surface must not synthesize a `\"calldata\"` field"
    end
  end

  describe "runbook drift — explicit-confirmation deposit smoke section" do
    setup do
      runbook = File.read!(@runbook_path)
      {:ok, runbook: runbook}
    end

    test "runbook documents the explicit-confirmation smoke section",
         %{runbook: runbook} do
      assert runbook =~ "mix bank.morpho.deposit_smoke",
             "runbook should reference the new Mix task by name"

      assert runbook =~ "--confirm",
             "runbook should explain that --confirm is required for live broadcast"
    end

    test "runbook documents the pre-flight checklist", %{runbook: runbook} do
      assert runbook =~ ~r/[Pp]re-flight checklist/,
             "runbook should have a pre-flight checklist section"

      assert runbook =~ "mix bank.demo.seed",
             "checklist should mention mix bank.demo.seed"

      assert runbook =~ "allowed_vault",
             "checklist should mention the allowed_vault policy rule"
    end

    test "runbook documents the expected output artifacts", %{runbook: runbook} do
      Enum.each(
        ~w(intent_id decision_id plan_id execution_status tx_refs vault_address),
        fn artifact ->
          assert runbook =~ artifact,
                 "runbook should document the `#{artifact}` artifact"
        end
      )
    end

    test "runbook documents failure modes including dispatch unavailability",
         %{runbook: runbook} do
      assert runbook =~ "adapter_unavailable",
             "runbook should document the :adapter_unavailable failure mode"

      assert runbook =~ "phoenix_env",
             "runbook should document the :phoenix_env failure mode"
    end

    test "runbook explicitly says no withdraw / redeem path", %{runbook: runbook} do
      assert runbook =~ ~r/operator-only and never agent-initiated/i,
             "runbook should preserve the explicit operator-only withdraw boundary (#454 P2)"
    end

    test "runbook explicitly says Base Sepolia only (no mainnet)", %{runbook: runbook} do
      [first_workflow, _post_mvp] = String.split(runbook, "## Optional", parts: 2)

      refute first_workflow =~ "mainnet, requires per-workspace mainnet opt-in",
             "first supported workflow must not advertise mainnet (#203 P2 invariant)"

      assert runbook =~ "Base Sepolia only",
             "runbook should pin Base Sepolia only as the supported live chain"
    end
  end
end
