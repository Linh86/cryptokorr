defmodule Bank.Intents.SwapRouteTest do
  use ExUnit.Case, async: true

  alias Bank.Intents.SwapRoute

  @swap_doc_path Path.expand("../../../docs/swap-contract-v0_1.md", __DIR__)

  # Canonical v0.1 caps mirror the documented defaults. Every test
  # passes `:caps` explicitly so the gate is deterministic and free
  # of `Application` config drift; mirror of the
  # `CanaryCapsTest.@v01_caps` pattern.
  @v01_caps %{
    allowed_chains: ["base-sepolia"],
    allowed_assets: ["USDC"],
    max_slippage_bps: 100
  }

  # A pinned `now` for deadline tests so a wall-clock advance during
  # CI cannot flip a test outcome. The valid-route fixture's deadline
  # is well after this instant.
  @now ~U[2026-01-01 00:00:00.000000Z]

  defp v01, do: [caps: @v01_caps, now: @now]

  defp valid_route(overrides \\ %{}) do
    base = %{
      source_asset: "USDC",
      source_token_address: "0x036cbd53842c5426634e7929541ec2318f3dcf7e",
      destination_asset: "USDC",
      destination_token_address: "0x036cbd53842c5426634e7929541ec2318f3dcf7e",
      input_amount: Decimal.new("1.000000"),
      expected_output_amount: Decimal.new("0.995000"),
      minimum_output_amount: Decimal.new("0.985000"),
      spender: "0x1111111111111111111111111111111111111111",
      swap_target_contract: "0x2222222222222222222222222222222222222222",
      calldata: "0xdeadbeef",
      value: Decimal.new("0"),
      route_provider: "stub",
      quote_timestamp: ~U[2025-12-31 23:59:30.000000Z],
      deadline: ~U[2026-01-01 00:05:00.000000Z],
      chain: "base-sepolia",
      chain_id: 84_532,
      slippage_bps: 50
    }

    Map.merge(base, overrides)
  end

  describe "default_caps/0" do
    test "returns the documented v0.1 caps as a frozen map" do
      caps = SwapRoute.default_caps()

      assert caps.allowed_chains == ["base-sepolia"]
      assert caps.allowed_assets == ["USDC"]
      assert caps.max_slippage_bps == 100
    end
  end

  describe "required_fields/0" do
    test "names every minimum-required field from issue #189" do
      fields = SwapRoute.required_fields()

      # The 12 minimum required fields named verbatim in the issue
      # body (with the runtime's structural fields appended).
      for required <- [
            :source_asset,
            :source_token_address,
            :destination_asset,
            :destination_token_address,
            :input_amount,
            :expected_output_amount,
            :minimum_output_amount,
            :spender,
            :swap_target_contract,
            :calldata,
            :value,
            :route_provider,
            :quote_timestamp,
            :deadline,
            :chain_id
          ] do
        assert required in fields, "required_fields/0 missing #{required}"
      end
    end
  end

  describe "validate/2 — happy path" do
    test "passes for a fully-populated route on base-sepolia with USDC" do
      assert :ok = SwapRoute.validate(valid_route(), v01())
    end

    test "passes when slippage_bps is exactly at the cap (boundary)" do
      assert :ok = SwapRoute.validate(valid_route(%{slippage_bps: 100}), v01())
    end

    test "passes when slippage_bps is zero" do
      assert :ok = SwapRoute.validate(valid_route(%{slippage_bps: 0}), v01())
    end

    test "passes when minimum_output_amount equals expected_output_amount" do
      route =
        valid_route(%{
          minimum_output_amount: Decimal.new("0.995000"),
          expected_output_amount: Decimal.new("0.995000")
        })

      assert :ok = SwapRoute.validate(route, v01())
    end

    test "passes when value (native amount) is zero (ERC-20 swap)" do
      assert :ok = SwapRoute.validate(valid_route(%{value: Decimal.new("0")}), v01())
    end

    test "passes when value (native amount) is positive" do
      assert :ok = SwapRoute.validate(valid_route(%{value: Decimal.new("0.001")}), v01())
    end
  end

  describe "validate/2 — :swap_route_field_missing" do
    test "rejects when input is not a map" do
      assert {:error, :swap_route_field_missing} = SwapRoute.validate(nil, v01())
      assert {:error, :swap_route_field_missing} = SwapRoute.validate("not-a-map", v01())
      assert {:error, :swap_route_field_missing} = SwapRoute.validate(123, v01())
    end

    test "rejects each individually-removed required field" do
      for field <- SwapRoute.required_fields() do
        bad = Map.delete(valid_route(), field)

        assert {:error, :swap_route_field_missing} = SwapRoute.validate(bad, v01()),
               "missing #{field} did not produce :swap_route_field_missing"
      end
    end

    test "rejects nil calldata" do
      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{calldata: nil}), v01())
    end

    test "rejects empty-string calldata" do
      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{calldata: ""}), v01())
    end

    test "rejects empty-string spender" do
      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{spender: ""}), v01())
    end

    test "rejects empty-string swap_target_contract" do
      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{swap_target_contract: ""}), v01())
    end

    test "rejects non-Decimal input_amount" do
      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{input_amount: "1.0"}), v01())

      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{input_amount: 1}), v01())
    end

    test "rejects non-DateTime deadline" do
      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{deadline: "2026-01-01"}), v01())
    end

    test "rejects non-DateTime quote_timestamp" do
      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{quote_timestamp: "yesterday"}), v01())
    end

    test "rejects non-integer chain_id" do
      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{chain_id: "84532"}), v01())
    end

    test "rejects zero or negative chain_id" do
      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{chain_id: 0}), v01())

      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{chain_id: -1}), v01())
    end
  end

  describe "validate/2 — :swap_chain_not_supported" do
    test "rejects ethereum mainnet (not in allowed_chains)" do
      route = valid_route(%{chain: "ethereum", chain_id: 1})

      assert {:error, :swap_chain_not_supported} = SwapRoute.validate(route, v01())
    end

    test "rejects base mainnet (not in v0.1 testnet-first allowlist)" do
      route = valid_route(%{chain: "base", chain_id: 8453})

      assert {:error, :swap_chain_not_supported} = SwapRoute.validate(route, v01())
    end

    test "rejects an unknown chain string" do
      route = valid_route(%{chain: "polygon", chain_id: 137})

      assert {:error, :swap_chain_not_supported} = SwapRoute.validate(route, v01())
    end
  end

  describe "validate/2 — :swap_chain_id_mismatch" do
    test "rejects base-sepolia paired with the wrong chain_id" do
      route = valid_route(%{chain: "base-sepolia", chain_id: 8453})

      assert {:error, :swap_chain_id_mismatch} = SwapRoute.validate(route, v01())
    end

    test "rejects an admitted-but-unknown-id pair" do
      caps_with_phantom = %{@v01_caps | allowed_chains: ["phantom-chain"]}

      route = valid_route(%{chain: "phantom-chain", chain_id: 12_345})

      assert {:error, :swap_chain_id_mismatch} =
               SwapRoute.validate(route, caps: caps_with_phantom, now: @now)
    end
  end

  describe "validate/2 — :swap_asset_not_supported" do
    test "rejects DAI as source_asset (not in allowed_assets)" do
      assert {:error, :swap_asset_not_supported} =
               SwapRoute.validate(valid_route(%{source_asset: "DAI"}), v01())
    end

    test "rejects DAI as destination_asset" do
      assert {:error, :swap_asset_not_supported} =
               SwapRoute.validate(valid_route(%{destination_asset: "DAI"}), v01())
    end

    test "rejects ETH on either side" do
      assert {:error, :swap_asset_not_supported} =
               SwapRoute.validate(valid_route(%{source_asset: "ETH"}), v01())

      assert {:error, :swap_asset_not_supported} =
               SwapRoute.validate(valid_route(%{destination_asset: "ETH"}), v01())
    end

    test "asset check fires after chain check (ordering)" do
      # Asset is wrong AND chain is wrong — chain wins because
      # operators usually want the chain reason first.
      route = valid_route(%{chain: "ethereum", chain_id: 1, source_asset: "DAI"})

      assert {:error, :swap_chain_not_supported} = SwapRoute.validate(route, v01())
    end
  end

  describe "validate/2 — :swap_slippage_exceeded" do
    test "rejects slippage just over the cap" do
      assert {:error, :swap_slippage_exceeded} =
               SwapRoute.validate(valid_route(%{slippage_bps: 101}), v01())
    end

    test "rejects 200 bps when cap is 100" do
      assert {:error, :swap_slippage_exceeded} =
               SwapRoute.validate(valid_route(%{slippage_bps: 200}), v01())
    end

    test "rejects negative slippage_bps" do
      # A negative slippage value fails the structural well-shaped
      # check before reaching the cap clause.
      assert {:error, :swap_route_field_missing} =
               SwapRoute.validate(valid_route(%{slippage_bps: -1}), v01())
    end
  end

  describe "validate/2 — :swap_amount_invalid" do
    test "rejects zero input_amount" do
      assert {:error, :swap_amount_invalid} =
               SwapRoute.validate(valid_route(%{input_amount: Decimal.new("0")}), v01())
    end

    test "rejects negative input_amount" do
      assert {:error, :swap_amount_invalid} =
               SwapRoute.validate(valid_route(%{input_amount: Decimal.new("-1")}), v01())
    end

    test "rejects zero expected_output_amount" do
      assert {:error, :swap_amount_invalid} =
               SwapRoute.validate(
                 valid_route(%{
                   expected_output_amount: Decimal.new("0"),
                   minimum_output_amount: Decimal.new("0")
                 }),
                 v01()
               )
    end

    test "rejects negative minimum_output_amount" do
      assert {:error, :swap_amount_invalid} =
               SwapRoute.validate(
                 valid_route(%{minimum_output_amount: Decimal.new("-0.1")}),
                 v01()
               )
    end

    test "rejects negative value (native amount)" do
      assert {:error, :swap_amount_invalid} =
               SwapRoute.validate(valid_route(%{value: Decimal.new("-0.0001")}), v01())
    end

    test "rejects minimum_output_amount > expected_output_amount" do
      route =
        valid_route(%{
          minimum_output_amount: Decimal.new("1.000000"),
          expected_output_amount: Decimal.new("0.500000")
        })

      assert {:error, :swap_amount_invalid} = SwapRoute.validate(route, v01())
    end
  end

  describe "validate/2 — :swap_deadline_expired" do
    test "rejects a deadline strictly in the past" do
      route =
        valid_route(%{
          deadline: ~U[2025-12-31 00:00:00.000000Z]
        })

      assert {:error, :swap_deadline_expired} = SwapRoute.validate(route, v01())
    end

    test "rejects a deadline equal to now (not strictly future)" do
      route = valid_route(%{deadline: @now})

      assert {:error, :swap_deadline_expired} = SwapRoute.validate(route, v01())
    end

    test "deadline injection isolates the test from the wall clock" do
      route =
        valid_route(%{
          deadline: ~U[2026-01-01 00:00:01.000000Z]
        })

      # Pin `now` one microsecond before the deadline → passes.
      assert :ok =
               SwapRoute.validate(route,
                 caps: @v01_caps,
                 now: ~U[2026-01-01 00:00:00.999999Z]
               )

      # Pin `now` after the deadline → fails.
      assert {:error, :swap_deadline_expired} =
               SwapRoute.validate(route,
                 caps: @v01_caps,
                 now: ~U[2026-01-01 00:00:02.000000Z]
               )
    end
  end

  describe "validate/2 — :caps option overrides" do
    test "an explicit larger slippage cap relaxes the gate" do
      relaxed = %{@v01_caps | max_slippage_bps: 500}

      assert :ok =
               SwapRoute.validate(valid_route(%{slippage_bps: 300}),
                 caps: relaxed,
                 now: @now
               )
    end

    test "an explicit allowed_chains override admits a different chain" do
      with_base =
        %{@v01_caps | allowed_chains: ["base-sepolia", "base"]}

      route = valid_route(%{chain: "base", chain_id: 8453})

      assert :ok = SwapRoute.validate(route, caps: with_base, now: @now)
    end

    test "an explicit allowed_assets override admits a different asset" do
      with_dai =
        %{@v01_caps | allowed_assets: ["USDC", "DAI"]}

      route =
        valid_route(%{
          source_asset: "DAI",
          destination_asset: "USDC"
        })

      assert :ok = SwapRoute.validate(route, caps: with_dai, now: @now)
    end
  end

  describe "validate/2 — failure-atom shape (secret hygiene)" do
    test "every failure reason is a fixed-allowlist atom (no inspect blobs, no URLs, no hex)" do
      bad_routes = [
        # missing field
        Map.delete(valid_route(), :calldata),
        # wrong chain
        valid_route(%{chain: "ethereum", chain_id: 1}),
        # chain id mismatch
        valid_route(%{chain: "base-sepolia", chain_id: 8453}),
        # wrong asset
        valid_route(%{source_asset: "DAI"}),
        # slippage too high
        valid_route(%{slippage_bps: 1000}),
        # zero input amount
        valid_route(%{input_amount: Decimal.new("0")}),
        # min > expected
        valid_route(%{minimum_output_amount: Decimal.new("99")}),
        # deadline expired
        valid_route(%{deadline: ~U[2024-01-01 00:00:00Z]})
      ]

      reasons =
        for bad <- bad_routes do
          {:error, r} = SwapRoute.validate(bad, v01())
          r
        end

      allowlist = [
        :swap_chain_not_supported,
        :swap_chain_id_mismatch,
        :swap_asset_not_supported,
        :swap_route_field_missing,
        :swap_amount_invalid,
        :swap_slippage_exceeded,
        :swap_deadline_expired
      ]

      for reason <- reasons do
        assert is_atom(reason),
               "failure reason is not an atom: #{inspect(reason)}"

        assert reason in allowlist,
               "failure reason not in documented allowlist: #{inspect(reason)}"

        # Belt-and-braces: the atom string never carries a URL or a
        # hex blob. Defensive — any future regression that leaks a
        # raw value into the error term would fail this check.
        s = Atom.to_string(reason)
        refute s =~ "http", "atom string leaked URL: #{s}"
        refute s =~ "0x", "atom string leaked hex blob: #{s}"
      end
    end
  end

  describe "chain_id_for/1 + known_chain?/1" do
    test "returns the EIP-155 id for every Bank.Chains-known chain" do
      for chain <- Bank.Chains.mainnet_chains() ++ Bank.Chains.testnet_chains() do
        assert SwapRoute.known_chain?(chain),
               "Bank.Chains chain #{inspect(chain)} missing from SwapRoute chain_id table"

        assert is_integer(SwapRoute.chain_id_for(chain)) and SwapRoute.chain_id_for(chain) > 0,
               "no chain_id mapping for #{inspect(chain)}"
      end
    end

    test "returns nil for unknown chains" do
      assert SwapRoute.chain_id_for("polygon") == nil
      refute SwapRoute.known_chain?("polygon")

      assert SwapRoute.chain_id_for(nil) == nil
      assert SwapRoute.chain_id_for(:not_a_string) == nil
    end
  end

  describe "chain_supported?/2" do
    test "true for an admitted chain" do
      assert SwapRoute.chain_supported?("base-sepolia", caps: @v01_caps)
    end

    test "false for a non-admitted chain" do
      refute SwapRoute.chain_supported?("ethereum", caps: @v01_caps)
    end
  end

  describe "docs/swap-contract-v0_1.md (#189)" do
    test "exists at the expected path" do
      assert File.exists?(@swap_doc_path),
             "swap contract doc missing at #{@swap_doc_path}"
    end

    test "names the v0.1 swap type, chain, and asset allowlists" do
      contents = File.read!(@swap_doc_path)

      assert contents =~ ~r/exact[- ]input/i,
             "doc missing the exact-input swap type"

      assert contents =~ "base-sepolia",
             "doc missing the base-sepolia testnet-first chain"

      assert contents =~ "USDC",
             "doc missing the USDC asset allowlist"
    end

    test "lists every documented failure-mode atom" do
      contents = File.read!(@swap_doc_path)

      for atom <- [
            "swap_chain_not_supported",
            "swap_chain_id_mismatch",
            "swap_asset_not_supported",
            "swap_route_field_missing",
            "swap_amount_invalid",
            "swap_slippage_exceeded",
            "swap_deadline_expired"
          ] do
        assert contents =~ atom,
               "doc missing failure-mode atom #{inspect(atom)}"
      end
    end

    test "names every minimum required route field from issue #189" do
      contents = File.read!(@swap_doc_path)

      # The 12 minimum-required fields named in the issue body. The
      # doc uses the canonical snake_case names that match the
      # validator module's @type t — matching here ensures the doc
      # never drifts from the contract.
      for field <- [
            "source_asset",
            "source_token_address",
            "destination_asset",
            "destination_token_address",
            "input_amount",
            "expected_output_amount",
            "minimum_output_amount",
            "spender",
            "swap_target_contract",
            "calldata",
            "value",
            "route_provider",
            "quote_timestamp",
            "deadline",
            "chain_id"
          ] do
        assert contents =~ field,
               "doc missing required field: #{field}"
      end
    end

    test "cross-links to Bank.Intents.SwapRoute" do
      contents = File.read!(@swap_doc_path)

      assert contents =~ "Bank.Intents.SwapRoute",
             "doc missing cross-link to the validator module"
    end
  end
end
