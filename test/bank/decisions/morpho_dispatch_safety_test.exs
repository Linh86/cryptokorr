defmodule Bank.Decisions.MorphoDispatchSafetyTest do
  @moduledoc """
  Per-gate coverage for `Bank.Decisions.MorphoDispatchSafety` (#206) —
  the centralized pre-dispatch gate every Morpho deposit dispatch
  path must call before handing the plan to the adapter.

  Each test exercises exactly one gate so a regression points to
  the failing gate, not the composition. Snapshot + rules loaders
  are passed via `:rules_loader` / `:snapshot_loader` opts so the
  tests stay deterministic and DB-free.
  """

  use ExUnit.Case, async: true

  alias Bank.Decisions.{ExecutionPlan, MorphoDispatchSafety}
  alias Bank.DefiVenues.Morpho.PersistedVaultSnapshot
  alias Bank.Policies.PolicyRule

  @vault "0xbeef000000000000000000000000000000000099"
  @other_vault "0xdead000000000000000000000000000000000001"
  @ws "11111111-1111-4111-8111-111111111111"
  @snap_id "22222222-2222-4222-8222-222222222222"
  @snap_hash "demo-hash-abc"

  defp build_plan(overrides \\ %{}) do
    base = %ExecutionPlan{
      id: "33333333-3333-4333-8333-333333333333",
      decision_id: "44444444-4444-4444-8444-444444444444",
      intent_id: "55555555-5555-4555-8555-555555555555",
      chain: "base-sepolia",
      asset: "USDC",
      smart_account_id: "sa_demo",
      execution_status: :prepared,
      workspace_id: @ws,
      steps: %{
        "kind" => "morpho_deposit",
        "vault_address" => @vault,
        "chain_id" => 84_532,
        "asset" => "USDC",
        "receiver" => "sa_demo",
        "snapshot_id" => @snap_id,
        "snapshot_payload_hash" => @snap_hash,
        "snapshot_fetched_at" => "2026-05-06T06:00:00.000000Z",
        "policy_rule_ids" => [],
        "decision_id" => "44444444-4444-4444-8444-444444444444",
        "approval_actor" => "user"
      }
    }

    Map.merge(base, overrides)
  end

  defp allowlisted_rule(vault_address) do
    %PolicyRule{
      rule_type: :allowed_vault,
      params: %{"vault_address" => vault_address}
    }
  end

  defp current_snapshot(payload_hash \\ @snap_hash) do
    %PersistedVaultSnapshot{
      id: @snap_id,
      chain_id: 84_532,
      vault_address: @vault,
      payload_hash: payload_hash,
      fetched_at: ~U[2026-05-06 06:00:00.000000Z],
      freshness_seconds_identity: 86_400,
      freshness_seconds_allocation: 300,
      freshness_seconds_warnings: 300,
      freshness_seconds_apy: 3600
    }
  end

  defp default_opts(extras \\ []) do
    Keyword.merge(
      [
        rules_loader: fn _ws -> [allowlisted_rule(@vault)] end,
        snapshot_loader: fn _ci, _va -> current_snapshot() end,
        now: ~U[2026-05-06 06:00:01.000000Z]
      ],
      extras
    )
  end

  describe "happy path" do
    test "returns :ok when all gates pass" do
      assert :ok = MorphoDispatchSafety.validate(build_plan(), default_opts())
    end
  end

  describe "chain gate" do
    test "rejects mainnet (chain: 'base') with :morpho_chain_not_supported" do
      plan = build_plan(%{chain: "base"})

      assert {:error, :morpho_chain_not_supported} =
               MorphoDispatchSafety.validate(plan, default_opts())
    end

    test "rejects unknown chains" do
      plan = build_plan(%{chain: "ethereum"})

      assert {:error, :morpho_chain_not_supported} =
               MorphoDispatchSafety.validate(plan, default_opts())
    end
  end

  describe "asset gate" do
    test "rejects non-USDC assets" do
      plan = build_plan(%{asset: "DAI"})

      assert {:error, :morpho_asset_not_supported} =
               MorphoDispatchSafety.validate(plan, default_opts())
    end
  end

  describe "vault allowlist gate" do
    test "rejects when the vault is not in the workspace allowlist" do
      opts = default_opts(rules_loader: fn _ws -> [allowlisted_rule(@other_vault)] end)

      assert {:error, :morpho_vault_not_allowlisted} =
               MorphoDispatchSafety.validate(build_plan(), opts)
    end

    test "is case-insensitive on address comparison" do
      mixed_case_vault =
        String.upcase(String.slice(@vault, 0..1)) <> String.upcase(String.slice(@vault, 2..-1//1))

      opts = default_opts(rules_loader: fn _ws -> [allowlisted_rule(mixed_case_vault)] end)
      assert :ok = MorphoDispatchSafety.validate(build_plan(), opts)
    end

    test "rejects when the workspace has zero rules" do
      opts = default_opts(rules_loader: fn _ws -> [] end)

      assert {:error, :morpho_vault_not_allowlisted} =
               MorphoDispatchSafety.validate(build_plan(), opts)
    end
  end

  describe "snapshot freshness gate" do
    test "rejects when no current snapshot exists" do
      opts = default_opts(snapshot_loader: fn _ci, _va -> nil end)

      assert {:error, :morpho_snapshot_missing} =
               MorphoDispatchSafety.validate(build_plan(), opts)
    end

    test "rejects when any freshness bucket is :expired" do
      # Identity TTL is 86_400; expired_cutoff is 2 * TTL. Force an
      # expiry by aging the snapshot way beyond 2x identity TTL.
      stale = %PersistedVaultSnapshot{
        current_snapshot()
        | fetched_at: ~U[2025-01-01 00:00:00.000000Z]
      }

      opts = default_opts(snapshot_loader: fn _ci, _va -> stale end)

      assert {:error, :morpho_snapshot_expired} =
               MorphoDispatchSafety.validate(build_plan(), opts)
    end

    test "tolerates :stale (between TTL and 2x TTL) on the tightest bucket" do
      # `freshness_seconds_allocation = 300` → fresh < 5m, stale
      # 5–10m, expired > 10m. At ~7 minutes past `fetched_at` every
      # bucket is either :fresh (identity 24h, apy 1h) or :stale
      # (allocation 5m, warnings 5m) — none are :expired yet.
      stale = %PersistedVaultSnapshot{
        current_snapshot()
        | fetched_at: ~U[2026-05-06 06:00:00.000000Z]
      }

      opts =
        default_opts(
          snapshot_loader: fn _ci, _va -> stale end,
          now: ~U[2026-05-06 06:07:00.000000Z]
        )

      # The plan has snapshot_payload_hash matching @snap_hash; the
      # current snapshot still has @snap_hash, so no drift either.
      # Just stale (degraded), not expired.
      assert :ok = MorphoDispatchSafety.validate(build_plan(), opts)
    end
  end

  describe "material drift gate" do
    test "rejects when current snapshot's payload_hash differs from the plan's captured hash" do
      drifted = current_snapshot("different-hash")
      opts = default_opts(snapshot_loader: fn _ci, _va -> drifted end)

      assert {:error, :morpho_snapshot_drifted} =
               MorphoDispatchSafety.validate(build_plan(), opts)
    end

    test "rejects when the plan has no captured snapshot_payload_hash (fail closed)" do
      plan = build_plan()
      plan = %ExecutionPlan{plan | steps: Map.put(plan.steps, "snapshot_payload_hash", nil)}

      assert {:error, :morpho_snapshot_drifted} =
               MorphoDispatchSafety.validate(plan, default_opts())
    end
  end

  describe "steps shape gate (defensive)" do
    test "rejects a plan with no steps" do
      plan = build_plan(%{steps: nil})
      assert {:error, :morpho_steps_missing} = MorphoDispatchSafety.validate(plan, default_opts())
    end

    test "rejects a plan whose steps.kind != 'morpho_deposit'" do
      plan = build_plan(%{steps: %{"kind" => "transfer"}})
      assert {:error, :morpho_steps_missing} = MorphoDispatchSafety.validate(plan, default_opts())
    end

    test "rejects a plan with empty vault_address" do
      plan = build_plan()
      plan = %ExecutionPlan{plan | steps: Map.put(plan.steps, "vault_address", "")}
      assert {:error, :morpho_steps_missing} = MorphoDispatchSafety.validate(plan, default_opts())
    end
  end
end
