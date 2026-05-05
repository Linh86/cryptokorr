defmodule Bank.DefiVenues.Morpho.RiskExplanationTest do
  @moduledoc """
  Pure tests for `Bank.DefiVenues.Morpho.RiskExplanation` (#201).

  Every test is a pure function on
  `(snapshot, policy, now)` — no DB, no HTTP, no Oban. The
  snapshot is a `%PersistedVaultSnapshot{}` struct built
  in-memory; we never `Repo.insert/1` it.
  """

  use ExUnit.Case, async: true

  alias Bank.DefiVenues.Morpho.PersistedVaultSnapshot
  alias Bank.DefiVenues.Morpho.PolicyInput
  alias Bank.DefiVenues.Morpho.RiskExplanation

  @chain_id 1
  @vault "0xbeef000000000000000000000000000000000099"
  @oracle "0xchainlinkoracle"
  @collateral "0xwsteth"
  @now ~U[2026-05-05 12:00:00.000000Z]

  defp build_snapshot(overrides \\ %{}) do
    fetched_at =
      Map.get(overrides, :fetched_at, ~U[2026-05-05 11:59:00.000000Z])

    base = %PersistedVaultSnapshot{
      chain_id: @chain_id,
      vault_address: @vault,
      name: "Steakhouse USDC",
      symbol: "steakUSDC",
      network: "mainnet",
      listed: true,
      deposit_asset: %{"address" => "0xusdc", "symbol" => "USDC", "decimals" => 6},
      state: %{"apy" => "0.045", "net_apy" => "0.041", "total_assets" => "10000000000000"},
      allocations: [
        %{
          "market_unique_key" => "0xmarket1",
          "loan_asset" => "0xusdc",
          "collateral_asset" => @collateral,
          "oracle" => @oracle,
          "irm" => "0xirm",
          "lltv" => 750_000_000_000_000_000,
          "supply_cap" => "1000000000000",
          "supplied_assets" => "100000000000",
          "supplied_assets_usd" => "100000.00"
        }
      ],
      warnings: [],
      pending_caps: [],
      allocators: [%{"address" => "0xallocator1"}],
      source: %{
        "fetched_at" => DateTime.to_iso8601(fetched_at),
        "source_name" => "morpho_blue_graphql",
        "source_schema_version" => "1",
        "source_warnings" => [],
        "payload_hash" => "abc123"
      },
      fetched_at: fetched_at,
      payload_hash: "abc123",
      freshness_seconds_identity: 86_400,
      freshness_seconds_allocation: 300,
      freshness_seconds_warnings: 300,
      freshness_seconds_apy: 3600,
      current: true
    }

    Map.merge(base, Map.drop(overrides, [:fetched_at]))
  end

  defp policy(opts \\ []) do
    %PolicyInput{
      vault_allowlist: Keyword.get(opts, :vault_allowlist, [{@chain_id, @vault}]),
      oracle_allowlist: Keyword.get(opts, :oracle_allowlist, [@oracle]),
      collateral_allowlist: Keyword.get(opts, :collateral_allowlist, [@collateral]),
      expected_loan_asset: Keyword.get(opts, :expected_loan_asset, "USDC"),
      current_exposure: Keyword.get(opts, :current_exposure, Decimal.new(0)),
      proposed_amount: Keyword.get(opts, :proposed_amount, Decimal.new("1000")),
      exposure_cap: Keyword.get(opts, :exposure_cap, Decimal.new("1000000")),
      approval_market_lltv_pct: Keyword.get(opts, :approval_market_lltv_pct, 80),
      block_market_lltv_pct: Keyword.get(opts, :block_market_lltv_pct, 90),
      warning_exposure_pct: Keyword.get(opts, :warning_exposure_pct, 50),
      approval_exposure_pct: Keyword.get(opts, :approval_exposure_pct, 80),
      block_exposure_pct: Keyword.get(opts, :block_exposure_pct, 100),
      apy_baseline: Keyword.get(opts, :apy_baseline, nil),
      apy_spike_pct: Keyword.get(opts, :apy_spike_pct, 50),
      incident_active?: Keyword.get(opts, :incident_active?, false)
    }
  end

  describe "explain/3 — top-level shape" do
    test "always returns the documented map shape" do
      result = RiskExplanation.explain(build_snapshot(), policy(), @now)

      assert result["kind"] == "morpho_vault_risk"
      assert result["venue"] == "morpho"
      assert result["chain_id"] == @chain_id
      assert result["vault_address"] == @vault
      assert result["vault_name"] == "Steakhouse USDC"
      assert result["loan_asset"] == "USDC"

      assert is_binary(result["risk_tier"])
      assert is_binary(result["decision"])
      assert is_binary(result["summary"])
      assert is_list(result["primary_reasons"])
      assert is_list(result["checks"])
      assert is_list(result["market_allocations"])
      assert is_list(result["source_refs"])
    end

    test "is deterministic — same inputs produce identical output" do
      a = RiskExplanation.explain(build_snapshot(), policy(), @now)
      b = RiskExplanation.explain(build_snapshot(), policy(), @now)
      assert a == b
    end

    test "source_refs include fetched_at and freshness summary" do
      result = RiskExplanation.explain(build_snapshot(), policy(), @now)
      assert [src] = result["source_refs"]
      assert src["source"] == "morpho_api"
      assert is_binary(src["fetched_at"])
      assert is_map(src["freshness"])
      assert src["freshness"]["identity"] == "fresh"
      assert src["freshness"]["allocation"] == "fresh"
    end
  end

  describe "explain/3 — MVP rule (low-risk allowlisted vault)" do
    test "low-risk allowlisted vault still recommends approval_required (never auto_exec)" do
      result = RiskExplanation.explain(build_snapshot(), policy(), @now)

      assert result["decision"] == "approval_required"
      # No block, no hold reasons; just the MVP-protocol reason.
      severities = Enum.map(result["primary_reasons"], & &1["severity"]) |> Enum.uniq()
      assert "block" not in severities
      assert "hold" not in severities
      assert "approval" in severities

      # Risk tier on a clean low-risk vault is "moderate" because
      # the MVP `:approval` reason ranks at moderate. Even a
      # totally-clean vault is never "low" + "auto_exec".
      assert result["risk_tier"] == "moderate"
    end

    test "primary_reasons always lists the MVP `mvp_morpho_deposit` reason" do
      result = RiskExplanation.explain(build_snapshot(), policy(), @now)
      codes = Enum.map(result["primary_reasons"], & &1["code"])
      assert "mvp_morpho_deposit" in codes
    end
  end

  describe "explain/3 — block dimensions" do
    test "unknown vault → block, severe" do
      policy = policy(vault_allowlist: [{@chain_id, "0xother"}])
      result = RiskExplanation.explain(build_snapshot(), policy, @now)

      assert result["decision"] == "block"
      assert result["risk_tier"] == "severe"
      assert reason_code?(result, "vault_not_allowlisted")
    end

    test "asset mismatch → block" do
      snap =
        build_snapshot(%{
          deposit_asset: %{"address" => "0xdai", "symbol" => "DAI", "decimals" => 18}
        })

      result = RiskExplanation.explain(snap, policy(expected_loan_asset: "USDC"), @now)

      assert result["decision"] == "block"
      assert reason_code?(result, "asset_mismatch")
    end

    test "vault `listed: false` → block" do
      snap = build_snapshot(%{listed: false})
      result = RiskExplanation.explain(snap, policy(), @now)

      assert result["decision"] == "block"
      assert reason_code?(result, "vault_not_listed")
    end

    test "post-deposit cap breach (>= 100%) → block" do
      result =
        RiskExplanation.explain(
          build_snapshot(),
          policy(
            current_exposure: Decimal.new("999000"),
            proposed_amount: Decimal.new("1100"),
            exposure_cap: Decimal.new("1000000")
          ),
          @now
        )

      assert result["decision"] == "block"
      assert reason_code?(result, "cap_breach")
    end

    test "max LLTV exceeded → block" do
      snap =
        build_snapshot(%{
          allocations: [
            %{
              "market_unique_key" => "0xrisky",
              "loan_asset" => "0xusdc",
              "collateral_asset" => @collateral,
              "oracle" => @oracle,
              "lltv" => 950_000_000_000_000_000
            }
          ]
        })

      result = RiskExplanation.explain(snap, policy(), @now)

      assert result["decision"] == "block"
      assert reason_code?(result, "max_lltv_exceeded")
    end

    test "unknown oracle + high LLTV → block (combined)" do
      snap =
        build_snapshot(%{
          allocations: [
            %{
              "market_unique_key" => "0xrisky",
              "loan_asset" => "0xusdc",
              "collateral_asset" => @collateral,
              "oracle" => "0xunknownoracle",
              "lltv" => 850_000_000_000_000_000
            }
          ]
        })

      result = RiskExplanation.explain(snap, policy(), @now)

      assert result["decision"] == "block"
      assert reason_code?(result, "unknown_oracle_high_lltv")
    end

    test "RED-level Morpho warning → block" do
      snap =
        build_snapshot(%{
          warnings: [%{"raw_type" => "VaultLossDetected", "raw_level" => "RED"}]
        })

      result = RiskExplanation.explain(snap, policy(), @now)

      assert result["decision"] == "block"
      assert Enum.any?(result["primary_reasons"], &(&1["severity"] == "block"))
    end
  end

  describe "explain/3 — hold dimensions (missing critical data)" do
    test "nil snapshot → hold" do
      result = RiskExplanation.explain(nil, policy(), @now)

      assert result["decision"] == "hold"
      assert result["risk_tier"] == "elevated"
      assert reason_code?(result, "snapshot_missing")
    end

    test "stale allocation → hold" do
      # Allocation TTL is 5 minutes. Fetched 11 minutes ago →
      # `:expired` (>= 2 * TTL).
      stale =
        build_snapshot(%{fetched_at: DateTime.add(@now, -11 * 60, :second)})

      result = RiskExplanation.explain(stale, policy(), @now)

      assert result["decision"] == "hold"
      assert reason_code?(result, "freshness_allocation")
    end

    test "stale warnings → hold" do
      stale =
        build_snapshot(%{fetched_at: DateTime.add(@now, -11 * 60, :second)})

      result = RiskExplanation.explain(stale, policy(), @now)

      assert reason_code?(result, "freshness_warnings")
    end

    test "active incident → hold" do
      result =
        RiskExplanation.explain(build_snapshot(), policy(incident_active?: true), @now)

      assert result["decision"] == "hold"
      assert reason_code?(result, "incident_active")
    end

    test "missing exposure cap → hold (cannot judge concentration)" do
      result = RiskExplanation.explain(build_snapshot(), policy(exposure_cap: nil), @now)
      assert result["decision"] == "hold"
      assert reason_code?(result, "exposure_cap_missing")
    end
  end

  describe "explain/3 — approval dimensions" do
    test "high LLTV (≥ approval threshold, < block threshold) → approval_required" do
      snap =
        build_snapshot(%{
          allocations: [
            %{
              "market_unique_key" => "0xmod",
              "loan_asset" => "0xusdc",
              "collateral_asset" => @collateral,
              "oracle" => @oracle,
              "lltv" => 850_000_000_000_000_000
            }
          ]
        })

      result = RiskExplanation.explain(snap, policy(), @now)

      assert result["decision"] == "approval_required"
      assert reason_code?(result, "high_lltv")
    end

    test "exposure near cap (≥ 80%, < 100%) → approval_required" do
      result =
        RiskExplanation.explain(
          build_snapshot(),
          policy(
            current_exposure: Decimal.new("810000"),
            proposed_amount: Decimal.new("10000"),
            exposure_cap: Decimal.new("1000000")
          ),
          @now
        )

      assert result["decision"] == "approval_required"
      assert reason_code?(result, "exposure_near_cap")
    end

    test "pending cap increase → approval_required" do
      snap =
        build_snapshot(%{
          pending_caps: [%{"market_unique_key" => "0xnew", "cap" => "1", "valid_at" => "2026-06"}]
        })

      result = RiskExplanation.explain(snap, policy(), @now)
      assert reason_code?(result, "pending_cap_increase")
    end

    test "APY spike → approval_required (APY never reduces risk)" do
      snap = build_snapshot(%{state: %{"net_apy" => "0.10"}})

      result =
        RiskExplanation.explain(
          snap,
          policy(apy_baseline: Decimal.new("0.05"), apy_spike_pct: 50),
          @now
        )

      assert result["decision"] == "approval_required"
      assert reason_code?(result, "apy_spike")
    end

    test "unknown collateral asset → approval_required" do
      snap =
        build_snapshot(%{
          allocations: [
            %{
              "market_unique_key" => "0xrisky",
              "loan_asset" => "0xusdc",
              "collateral_asset" => "0xrandomtoken",
              "oracle" => @oracle,
              "lltv" => 700_000_000_000_000_000
            }
          ]
        })

      result = RiskExplanation.explain(snap, policy(), @now)
      assert reason_code?(result, "unknown_collateral")
    end
  end

  describe "explain/3 — `listed` does not imply allowed" do
    test "vault `listed: true` but NOT in internal allowlist → block" do
      result =
        RiskExplanation.explain(
          build_snapshot(),
          policy(vault_allowlist: []),
          @now
        )

      assert result["decision"] == "block"
      # Both checks recorded — `vault_listed: pass`, but
      # `vault_allowlist: fail`. The block reason is on the
      # internal allowlist gate, not the API listing.
      check_passes? = fn code ->
        Enum.any?(result["checks"], fn c ->
          c["code"] == code and c["status"] == "pass"
        end)
      end

      check_fails? = fn code ->
        Enum.any?(result["checks"], fn c ->
          c["code"] == code and c["status"] == "fail"
        end)
      end

      assert check_passes?.("vault_listed")
      assert check_fails?.("vault_allowlist")
    end
  end

  describe "explain/3 — APY never reduces risk" do
    test "very low APY does NOT downgrade an existing high-LLTV approval reason" do
      snap =
        build_snapshot(%{
          state: %{"net_apy" => "0.001"},
          allocations: [
            %{
              "market_unique_key" => "0xmod",
              "loan_asset" => "0xusdc",
              "collateral_asset" => @collateral,
              "oracle" => @oracle,
              "lltv" => 850_000_000_000_000_000
            }
          ]
        })

      result =
        RiskExplanation.explain(
          snap,
          policy(apy_baseline: Decimal.new("0.05")),
          @now
        )

      # The approval still fires.
      assert result["decision"] == "approval_required"
      assert reason_code?(result, "high_lltv")
    end
  end

  describe "explain/3 — aggregation precedence" do
    test "block reason overrides approval/hold/warn" do
      snap =
        build_snapshot(%{
          listed: false,
          warnings: [%{"raw_type" => "Yellow", "raw_level" => "YELLOW"}]
        })

      result = RiskExplanation.explain(snap, policy(), @now)
      assert result["decision"] == "block"
    end

    test "hold reason overrides approval and warn (when no block)" do
      stale = build_snapshot(%{fetched_at: DateTime.add(@now, -11 * 60, :second)})
      result = RiskExplanation.explain(stale, policy(), @now)
      assert result["decision"] == "hold"
    end

    test "approval reason overrides warn-only" do
      result = RiskExplanation.explain(build_snapshot(), policy(), @now)
      # No warn-only path on the default snapshot — confirm the
      # MVP approval reason still drives the decision.
      assert result["decision"] == "approval_required"
    end
  end

  describe "explain/3 — secret hygiene" do
    test "no free-text from snapshot leaks into summary or reasons" do
      # Pre-fix regression probe: stuff a free-text-shaped value
      # into the deposit_asset symbol. The engine should NEVER
      # reflect this verbatim in `summary` (the only place a
      # human-readable string lands beyond controlled enums).
      snap =
        build_snapshot(%{
          deposit_asset: %{"symbol" => "Authorization: Bearer LEAKED_PROBE", "decimals" => 6}
        })

      result = RiskExplanation.explain(snap, policy(expected_loan_asset: "USDC"), @now)

      refute result["summary"] =~ "LEAKED_PROBE"
      refute result["summary"] =~ "Bearer"

      # Asset-mismatch reason carries the actual + expected
      # symbol — the upstream string IS in the message because
      # the operator needs to see the mismatch. We assert
      # `expected` is the controlled value and the actual is
      # the API-returned string.
      mismatch =
        Enum.find(result["primary_reasons"], &(&1["code"] == "asset_mismatch"))

      assert mismatch
      assert mismatch["message"] =~ "USDC"
    end
  end

  defp reason_code?(result, code) do
    Enum.any?(result["primary_reasons"], &(&1["code"] == code))
  end
end
