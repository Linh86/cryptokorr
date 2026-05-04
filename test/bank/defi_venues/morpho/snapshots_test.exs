defmodule Bank.DefiVenues.Morpho.SnapshotsTest do
  use Bank.DataCase, async: true

  alias Bank.DefiVenues.Morpho.PersistedVaultSnapshot
  alias Bank.DefiVenues.Morpho.Snapshots
  alias Bank.DefiVenues.Morpho.VaultSnapshot

  @chain_id 1
  @vault_address "0xbeef000000000000000000000000000000000099"

  defp build_snapshot(overrides \\ []) do
    fetched_at = Keyword.get(overrides, :fetched_at, ~U[2026-05-04 12:00:00.000000Z])
    payload_hash = Keyword.get(overrides, :payload_hash, "abc123")

    base = %VaultSnapshot{
      vault_address: @vault_address,
      name: "Steakhouse USDC",
      symbol: "steakUSDC",
      chain_id: @chain_id,
      network: "mainnet",
      listed: true,
      deposit_asset: %{address: "0xusdc", symbol: "USDC", decimals: 6},
      state: %{
        apy: "0.045",
        net_apy: "0.041",
        total_assets: "1234567",
        fee: "0.04",
        timelock: 86_400
      },
      allocations: [
        %{
          market_unique_key: "0xmarket1",
          loan_asset: "0xusdc",
          collateral_asset: "0xweth",
          oracle: "0xoracle",
          irm: "0xirm",
          lltv: 915_000_000_000_000_000,
          supply_cap: "1000000000000",
          supplied_assets: "456789000000",
          supplied_assets_usd: "456789.00"
        }
      ],
      warnings: [%{raw_type: "NotWhitelistedRisk", raw_level: "WARNING"}],
      pending_caps: [
        %{
          market_unique_key: "0xmarket2",
          cap: "5000000000000",
          valid_at: "2026-06-01T00:00:00Z"
        }
      ],
      allocators: [%{address: "0xallocator1"}],
      source: %{
        fetched_at: fetched_at,
        source_name: "morpho_blue_graphql",
        source_schema_version: "1",
        source_warnings: [],
        payload_hash: payload_hash
      }
    }

    Enum.reduce(overrides, base, fn
      {:fetched_at, _}, acc -> acc
      {:payload_hash, _}, acc -> acc
      {key, val}, acc -> Map.put(acc, key, val)
    end)
  end

  describe "persist/2 — first snapshot for a vault" do
    test "inserts a row with current: true and the normalized fields" do
      snap = build_snapshot()

      assert {:ok, %PersistedVaultSnapshot{} = row} = Snapshots.persist(snap)

      assert row.chain_id == @chain_id
      # Address is lowercased at the context boundary so a
      # mixed-case re-fetch dedupes.
      assert row.vault_address == String.downcase(@vault_address)
      assert row.network == "mainnet"
      assert row.listed == true
      assert row.current == true
      assert row.supersedes_id == nil
      assert row.payload_hash == "abc123"
      assert row.fetched_at == ~U[2026-05-04 12:00:00.000000Z]
      assert row.state["apy"] == "0.045"
      assert [%{"market_unique_key" => "0xmarket1"}] = row.allocations
      assert [%{"raw_type" => "NotWhitelistedRisk"}] = row.warnings
      assert [%{"market_unique_key" => "0xmarket2"}] = row.pending_caps
      assert [%{"address" => "0xallocator1"}] = row.allocators
    end

    test "stores per-field freshness TTL defaults from the design doc" do
      assert {:ok, row} = Snapshots.persist(build_snapshot())

      assert row.freshness_seconds_identity == 86_400
      assert row.freshness_seconds_allocation == 300
      assert row.freshness_seconds_warnings == 300
      assert row.freshness_seconds_apy == 3600
    end

    test "lowercases a mixed-case vault_address before insert" do
      snap = build_snapshot() |> Map.put(:vault_address, String.upcase(@vault_address))

      assert {:ok, row} = Snapshots.persist(snap)
      assert row.vault_address == String.downcase(@vault_address)
    end
  end

  describe "persist/2 — supersession" do
    test "a successor demotes the prior current row and links via supersedes_id" do
      first = build_snapshot(payload_hash: "hash-1")
      assert {:ok, prior} = Snapshots.persist(first)
      assert prior.current == true

      second = build_snapshot(payload_hash: "hash-2")
      assert {:ok, successor} = Snapshots.persist(second)

      assert successor.id != prior.id
      assert successor.current == true
      assert successor.supersedes_id == prior.id
      assert successor.payload_hash == "hash-2"

      # The prior row is demoted in the same transaction.
      reloaded_prior = Bank.Repo.get!(PersistedVaultSnapshot, prior.id)
      assert reloaded_prior.current == false
    end

    test "exactly one current row exists per vault after several supersessions" do
      for hash <- ["a", "b", "c", "d", "e"] do
        assert {:ok, _} = Snapshots.persist(build_snapshot(payload_hash: hash))
      end

      assert [%PersistedVaultSnapshot{}] = current_rows_for_vault(@vault_address)
    end
  end

  describe "persist/2 — payload-hash idempotency" do
    test "re-persisting the same body returns the existing row without inserting" do
      snap = build_snapshot(payload_hash: "stable-hash")

      assert {:ok, first} = Snapshots.persist(snap)
      assert {:ok, second} = Snapshots.persist(snap)

      assert second.id == first.id
      assert all_rows_count() == 1
    end

    test "a *different* `payload_hash` for the same vault inserts a successor" do
      assert {:ok, first} = Snapshots.persist(build_snapshot(payload_hash: "hash-x"))
      assert {:ok, second} = Snapshots.persist(build_snapshot(payload_hash: "hash-y"))

      refute second.id == first.id
      assert all_rows_count() == 2
    end
  end

  describe "get_current/2" do
    test "returns the current snapshot for the vault" do
      assert {:ok, row} = Snapshots.persist(build_snapshot(payload_hash: "got-it"))

      fetched = Snapshots.get_current(@chain_id, @vault_address)
      assert fetched.id == row.id
      assert fetched.current == true
    end

    test "returns nil when no snapshot has been persisted" do
      assert Snapshots.get_current(@chain_id, @vault_address) == nil
    end

    test "is case-insensitive on vault_address" do
      assert {:ok, row} = Snapshots.persist(build_snapshot())

      mixed = String.upcase(@vault_address)
      fetched = Snapshots.get_current(@chain_id, mixed)
      assert fetched.id == row.id
    end
  end

  describe "get/1 — replay by id" do
    test "returns a row even after it has been superseded" do
      assert {:ok, prior} = Snapshots.persist(build_snapshot(payload_hash: "h1"))
      assert {:ok, _successor} = Snapshots.persist(build_snapshot(payload_hash: "h2"))

      assert %PersistedVaultSnapshot{id: id, current: false} = Snapshots.get(prior.id)
      assert id == prior.id
    end
  end

  describe "freshness_for/3" do
    setup do
      assert {:ok, row} = Snapshots.persist(build_snapshot())
      %{row: row}
    end

    test ":fresh when now < fetched_at + ttl", %{row: row} do
      # `:apy` ttl is 1h. Bump now by 30 minutes.
      now = DateTime.add(row.fetched_at, 30 * 60, :second)
      assert Snapshots.freshness_for(row, :apy, now) == :fresh
    end

    test ":stale when fetched_at + ttl <= now < fetched_at + 2*ttl", %{row: row} do
      # `:warnings` ttl is 5m. Bump now by 6 minutes.
      now = DateTime.add(row.fetched_at, 6 * 60, :second)
      assert Snapshots.freshness_for(row, :warnings, now) == :stale
    end

    test ":expired when now >= fetched_at + 2*ttl", %{row: row} do
      # `:warnings` ttl is 5m. Bump now by 11 minutes (>= 2*5).
      now = DateTime.add(row.fetched_at, 11 * 60, :second)
      assert Snapshots.freshness_for(row, :warnings, now) == :expired
    end

    test ":identity is much longer-lived than :allocation", %{row: row} do
      # 6 hours later: identity (24h ttl) is fresh; allocation
      # (5m ttl) is expired.
      now = DateTime.add(row.fetched_at, 6 * 3600, :second)
      assert Snapshots.freshness_for(row, :identity, now) == :fresh
      assert Snapshots.freshness_for(row, :allocation, now) == :expired
    end
  end

  describe "freshness_summary/2" do
    test "returns one freshness state per documented field" do
      assert {:ok, row} = Snapshots.persist(build_snapshot())
      now = DateTime.add(row.fetched_at, 30 * 60, :second)

      summary = Snapshots.freshness_summary(row, now)

      assert Map.keys(summary) |> Enum.sort() == [:allocation, :apy, :identity, :warnings]
      assert summary.identity == :fresh
      assert summary.apy == :fresh
      assert summary.allocation == :expired
      assert summary.warnings == :expired
    end
  end

  describe "persist/2 — payload-hash stability" do
    test "the persisted row's payload_hash matches the source struct verbatim" do
      assert {:ok, row} = Snapshots.persist(build_snapshot(payload_hash: "deadbeef"))
      assert row.payload_hash == "deadbeef"
      assert row.source["payload_hash"] == "deadbeef"
    end
  end

  # --- helpers ---------------------------------------------------------

  defp current_rows_for_vault(addr) do
    addr_l = String.downcase(addr)

    Bank.Repo.all(
      from(s in PersistedVaultSnapshot,
        where:
          s.chain_id == ^@chain_id and s.vault_address == ^addr_l and
            s.current == true
      )
    )
  end

  defp all_rows_count do
    Bank.Repo.aggregate(PersistedVaultSnapshot, :count)
  end

  import Ecto.Query, only: [from: 2]
end
