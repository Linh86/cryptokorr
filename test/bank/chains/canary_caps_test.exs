defmodule Bank.Chains.CanaryCapsTest do
  use ExUnit.Case, async: true

  alias Bank.Chains.CanaryCaps

  @canary_runbook_path Path.expand(
                         "../../../docs/runbooks/base-mainnet-canary.md",
                         __DIR__
                       )

  # The canonical v0.1 caps used in every assertion below. Tests
  # never read `Application.get_env/2` for the cap — they pass
  # `:caps` explicitly so the gate is deterministic and free of
  # config drift.
  @v01_caps %{
    allowed_chains: ["base"],
    allowed_assets: ["USDC"],
    amount_caps: %{"USDC" => Decimal.new("10.00")}
  }

  defp v01, do: [caps: @v01_caps]

  describe "default_caps/0" do
    test "returns the documented v0.1 caps as a frozen map" do
      caps = CanaryCaps.default_caps()

      assert caps.allowed_chains == ["base"]
      assert caps.allowed_assets == ["USDC"]
      assert Decimal.equal?(caps.amount_caps["USDC"], Decimal.new("10.00"))
    end
  end

  describe "validate/4 — happy path" do
    test "passes when chain, asset, and amount are all within caps" do
      assert :ok = CanaryCaps.validate("base", "USDC", Decimal.new("5.00"), v01())
    end

    test "passes at exactly the cap boundary (amount == cap)" do
      assert :ok = CanaryCaps.validate("base", "USDC", Decimal.new("10.00"), v01())
    end

    test "passes for an integer amount within the cap" do
      assert :ok = CanaryCaps.validate("base", "USDC", 5, v01())
    end

    test "passes for a string amount within the cap" do
      assert :ok = CanaryCaps.validate("base", "USDC", "5.00", v01())
    end
  end

  describe "validate/4 — testnet bypass" do
    test "testnet chain bypasses the cap regardless of amount" do
      huge = Decimal.new("999999.99")
      assert :ok = CanaryCaps.validate("base-sepolia", "USDC", huge, v01())
    end

    test "testnet chain bypasses the cap regardless of asset" do
      assert :ok = CanaryCaps.validate("base-sepolia", "ETH", Decimal.new("1"), v01())
    end

    test "sepolia testnet bypasses the cap" do
      assert :ok = CanaryCaps.validate("sepolia", "USDC", Decimal.new("1000"), v01())
    end

    test "unknown chain bypasses the cap (mainnet?/1 returns false for unknowns)" do
      # The intent-submission allowlist already rejects unknown chains
      # at the wire boundary; an unknown string can never reach a real
      # broadcast in production. The cap layer's job is to fail closed
      # on *known mainnet* chains; unknowns are someone else's problem.
      assert :ok = CanaryCaps.validate("foochain", "USDC", Decimal.new("1000"), v01())
    end
  end

  describe "validate/4 — :canary_chain_not_allowed" do
    test "rejects ethereum mainnet (not in allowed_chains)" do
      assert {:error, :canary_chain_not_allowed} =
               CanaryCaps.validate("ethereum", "USDC", Decimal.new("1.00"), v01())
    end

    test "rejects a mainnet chain even with a tiny amount" do
      assert {:error, :canary_chain_not_allowed} =
               CanaryCaps.validate("ethereum", "USDC", Decimal.new("0.01"), v01())
    end
  end

  describe "validate/4 — :canary_asset_not_allowed" do
    test "rejects ETH (not in allowed_assets)" do
      assert {:error, :canary_asset_not_allowed} =
               CanaryCaps.validate("base", "ETH", Decimal.new("1.00"), v01())
    end

    test "rejects a nil asset" do
      assert {:error, :canary_asset_not_allowed} =
               CanaryCaps.validate("base", nil, Decimal.new("1.00"), v01())
    end

    test "rejects an empty-string asset" do
      assert {:error, :canary_asset_not_allowed} =
               CanaryCaps.validate("base", "", Decimal.new("1.00"), v01())
    end

    test "asset check fires before amount check (ordering)" do
      # Amount $1M is way over cap, but asset is wrong — the
      # earlier-matching reason wins so the operator sees the
      # actionable reason first.
      assert {:error, :canary_asset_not_allowed} =
               CanaryCaps.validate("base", "ETH", Decimal.new("1000000"), v01())
    end
  end

  describe "validate/4 — :canary_amount_exceeded" do
    test "rejects amount just over the cap" do
      assert {:error, :canary_amount_exceeded} =
               CanaryCaps.validate("base", "USDC", Decimal.new("10.01"), v01())
    end

    test "rejects amount well over the cap" do
      assert {:error, :canary_amount_exceeded} =
               CanaryCaps.validate("base", "USDC", Decimal.new("1000.00"), v01())
    end

    test "rejects a nil amount on mainnet" do
      assert {:error, :canary_amount_exceeded} =
               CanaryCaps.validate("base", "USDC", nil, v01())
    end

    test "rejects an unparseable string amount" do
      assert {:error, :canary_amount_exceeded} =
               CanaryCaps.validate("base", "USDC", "not-a-number", v01())
    end

    test "rejects an asset that is allowed but has no amount cap entry" do
      # A misconfigured caps map (asset in allowlist but missing from
      # amount_caps) is treated as :canary_amount_exceeded — fail
      # closed on config bug. Operators see this and notice the
      # missing cap entry.
      misconfigured = %{
        allowed_chains: ["base"],
        allowed_assets: ["USDC", "DAI"],
        amount_caps: %{"USDC" => Decimal.new("10.00")}
      }

      assert {:error, :canary_amount_exceeded} =
               CanaryCaps.validate("base", "DAI", Decimal.new("0.01"), caps: misconfigured)
    end
  end

  describe "validate/4 — :caps option overrides" do
    test "an explicit larger amount cap relaxes the gate" do
      relaxed = %{
        allowed_chains: ["base"],
        allowed_assets: ["USDC"],
        amount_caps: %{"USDC" => Decimal.new("1000")}
      }

      assert :ok = CanaryCaps.validate("base", "USDC", Decimal.new("500"), caps: relaxed)
    end

    test "an explicit allowed_chains override admits a different chain" do
      with_eth = %{
        allowed_chains: ["base", "ethereum"],
        allowed_assets: ["USDC"],
        amount_caps: %{"USDC" => Decimal.new("10.00")}
      }

      assert :ok = CanaryCaps.validate("ethereum", "USDC", Decimal.new("1"), caps: with_eth)
    end

    test "an explicit allowed_assets override admits a different asset" do
      with_eth = %{
        allowed_chains: ["base"],
        allowed_assets: ["USDC", "ETH"],
        amount_caps: %{"USDC" => Decimal.new("10.00"), "ETH" => Decimal.new("1.00")}
      }

      assert :ok = CanaryCaps.validate("base", "ETH", Decimal.new("0.5"), caps: with_eth)
    end
  end

  describe "validate/4 — failure-atom shape (secret hygiene)" do
    test "every failure reason is a fixed-allowlist atom" do
      reasons =
        for {chain, asset, amount} <- [
              {"ethereum", "USDC", Decimal.new("1")},
              {"base", "ETH", Decimal.new("1")},
              {"base", "USDC", Decimal.new("100")},
              {"base", "USDC", nil},
              {"base", "USDC", "garbage"}
            ] do
          {:error, r} = CanaryCaps.validate(chain, asset, amount, v01())
          r
        end

      # Every reason is in the documented allowlist — no inspect/1
      # of a struct, no string carrying a URL, no Decimal blob, etc.
      for reason <- reasons do
        assert reason in [
                 :canary_chain_not_allowed,
                 :canary_asset_not_allowed,
                 :canary_amount_exceeded
               ],
               "unexpected failure atom: #{inspect(reason)}"
      end
    end
  end

  describe "docs/runbooks/base-mainnet-canary.md (#181)" do
    test "exists at the expected path" do
      assert File.exists?(@canary_runbook_path),
             "canary runbook missing at #{@canary_runbook_path}"
    end

    test "names where broadcast actually occurs in the dispatch worker" do
      contents = File.read!(@canary_runbook_path)

      assert contents =~ "Bank.AdapterClient.dispatch_transfer",
             "runbook missing the exact line where broadcast occurs"

      assert contents =~ ~r/where broadcast actually occurs/i,
             "runbook missing the dedicated 'where broadcast occurs' section"

      assert contents =~ "lib/bank/runtime/workers/run_execution.ex",
             "runbook missing the dispatch worker file path"
    end

    test "names every cap dimension and the v0.1 default" do
      contents = File.read!(@canary_runbook_path)

      # Chain dimension.
      assert contents =~ ~r/chain.+\["?base"?\]/i,
             "runbook missing the chain allowlist (\"base\")"

      # Asset dimension.
      assert contents =~ ~r/asset.+\["?USDC"?\]/i,
             "runbook missing the asset allowlist (\"USDC\")"

      # Amount cap dimension — must surface the v0.1 $10 default.
      assert contents =~ "10.00",
             "runbook missing the v0.1 amount cap ($10.00 USDC)"
    end

    test "documents every canary cap failure atom with a next operator action" do
      contents = File.read!(@canary_runbook_path)

      for atom <- [
            "canary_chain_not_allowed",
            "canary_asset_not_allowed",
            "canary_amount_exceeded"
          ] do
        assert contents =~ atom,
               "runbook failure-modes table missing atom #{inspect(atom)}"
      end

      # Each cap-row must mention an operator-actionable next step.
      assert contents =~ ~r/next operator action/i,
             "runbook missing the failure-modes table header"
    end

    test "documents pause / rollback steps" do
      contents = File.read!(@canary_runbook_path)

      assert contents =~ ~r/Bank\.Security\.pause/,
             "runbook missing the runtime pause command"

      assert contents =~ ~r/Bank\.Workspaces\.set_mainnet_enabled.*false/,
             "runbook missing the mainnet flag flip-off rollback"

      assert contents =~ ~r/revoke[_ ]delegation/i,
             "runbook missing the revoke-delegation rollback option"

      assert contents =~ ~r/pause.+rollback|rollback/i,
             "runbook missing the dedicated pause/rollback section"
    end

    test "lists every required public artifact (#181 acceptance)" do
      contents = File.read!(@canary_runbook_path)

      # The acceptance criterion names: user op hash, tx hash, block
      # number, smart account, workspace id.
      for required <- [
            "user op hash",
            "tx hash",
            "block number",
            "smart account",
            "workspace id"
          ] do
        assert contents =~ ~r/#{required}/i,
               "runbook missing required artifact: #{required}"
      end

      assert contents =~ "tx_refs",
             "runbook missing reference to ExecutionPlan.tx_refs (the artifact source column)"
    end

    test "documents post-canary verification and incident rollback" do
      contents = File.read!(@canary_runbook_path)

      assert contents =~ ~r/post.canary/i,
             "runbook missing post-canary verification section"

      assert contents =~ "incident-runbook.md",
             "runbook missing cross-link to incident-runbook.md"
    end

    test "operator confirmation checklist references the rehearsal as a precondition" do
      contents = File.read!(@canary_runbook_path)

      assert contents =~ "base-mainnet-rehearsal.md",
             "runbook missing cross-link to base-mainnet-rehearsal.md (rehearsal precondition)"

      assert contents =~ ~r/rehearsal.+(must|cleared|prerequisite)/i,
             "runbook missing the rehearsal-must-have-cleared precondition"

      assert contents =~ ~r/operator confirmation/i,
             "runbook missing the operator-confirmation checklist item"
    end

    test "names the dependency chain back to the parent epic" do
      contents = File.read!(@canary_runbook_path)

      assert contents =~ "#166", "runbook missing reference to epic #166"
      assert contents =~ "#178", "runbook missing reference to mainnet flag #178"
      assert contents =~ "#179", "runbook missing reference to preflight #179"
      assert contents =~ "#180", "runbook missing reference to rehearsal #180"
      assert contents =~ "#181", "runbook missing reference to itself (#181)"
    end

    test "cross-links to the canary cap unit + integration test pins" do
      contents = File.read!(@canary_runbook_path)

      assert contents =~ "test/bank/chains/canary_caps_test.exs",
             "runbook missing cross-link to canary_caps_test.exs (unit pin)"

      assert contents =~ "test/bank/runtime/workers/run_execution_canary_caps_test.exs",
             "runbook missing cross-link to run_execution_canary_caps_test.exs (integration pin)"
    end
  end
end
