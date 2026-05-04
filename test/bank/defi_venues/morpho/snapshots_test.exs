defmodule Bank.DefiVenues.Morpho.SnapshotsTest do
  @moduledoc """
  Tests for `Bank.DefiVenues.Morpho.Snapshots` (#199).

  Cover:
    * persistence from a `%VaultSnapshot{}` fixture
    * idempotent re-import via `(workspace_id, payload_hash)`
    * payload hash stability
    * warnings + pending caps + allocations preservation
    * workspace isolation
    * freshness fresh / stale / expired across categories
  """

  use Bank.DataCase, async: false

  alias Bank.DefiVenues.Morpho.SnapshotRecord
  alias Bank.DefiVenues.Morpho.Snapshots
  alias Bank.DefiVenues.Morpho.VaultSnapshot

  @chain_id 1
  @vault_address "0x8eb67a509616cd6a7c1b3c8c21d48ff57df3d458"

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "morpho-snap-#{System.unique_integer([:positive])}",
        name: "Morpho Snap WS"
      })

    %{workspace: ws}
  end

  describe "create_from_snapshot/2 — happy path (#199)" do
    test "persists the in-memory VaultSnapshot fields onto a SnapshotRecord row",
         %{workspace: ws} do
      snap = vault_snapshot()

      assert {:ok, %SnapshotRecord{} = record} =
               Snapshots.create_from_snapshot(snap, workspace_id: ws.id)

      assert record.workspace_id == ws.id
      assert record.venue == "morpho"
      assert record.chain_id == @chain_id
      assert record.vault_address == String.downcase(@vault_address)
      assert record.fetched_at == snap.source.fetched_at
      assert record.payload_hash == snap.source.payload_hash

      # identity
      assert record.name == "Steakhouse USDC"
      assert record.symbol == "steakUSDC"
      assert record.listed == true
      assert record.network == "ethereum"

      # deposit asset (flattened)
      assert record.deposit_asset_address == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
      assert record.deposit_asset_symbol == "USDC"
      assert record.deposit_asset_decimals == 6

      # state — numeric strings preserved
      assert record.apy == "0.058"
      assert record.net_apy == "0.052"
      assert record.total_assets == "12345678901234"
      assert record.fee == "0.05"
      assert record.timelock == 86_400

      # bulk JSONB sections
      [alloc | _] = record.allocations["items"]
      assert alloc["market_unique_key"] =~ "0x"
      assert alloc["loan_asset"] == "USDC"
      assert alloc["collateral_asset"] == "wstETH"
      assert alloc["lltv"] == 86

      [warn | _] = record.warnings["items"]
      assert warn["raw_type"] == "vault_listed"
      assert warn["raw_level"] == "INFO"

      [pc | _] = record.pending_caps["items"]
      assert pc["cap"] == "20000000000000"
      assert pc["valid_at"] == "1714400000"

      [allocator | _] = record.allocators["items"]
      assert allocator["address"] =~ "0x"

      # source envelope
      assert record.source_name == "morpho_blue_graphql"
      assert record.source_schema_version == "v1.0"
      assert record.source_warnings == %{"items" => ["whitelisted is deprecated; use listed"]}
    end

    test "workspace_id is optional — workspace-agnostic snapshots persist with NULL" do
      snap = vault_snapshot()

      assert {:ok, %SnapshotRecord{workspace_id: nil}} =
               Snapshots.create_from_snapshot(snap)
    end

    test "correlation_id links the snapshot to a decision/intent for replay",
         %{workspace: ws} do
      correlation_id = Ecto.UUID.generate()

      assert {:ok, record} =
               Snapshots.create_from_snapshot(vault_snapshot(),
                 workspace_id: ws.id,
                 correlation_id: correlation_id
               )

      assert record.correlation_id == correlation_id

      # And the lookup helper finds it.
      assert [%SnapshotRecord{} = found] = Snapshots.get_by_correlation(correlation_id)
      assert found.id == record.id
    end
  end

  describe "create_from_snapshot/2 — idempotency (#199)" do
    test "re-importing the same payload returns {:duplicate, existing}",
         %{workspace: ws} do
      snap = vault_snapshot()

      assert {:ok, first} =
               Snapshots.create_from_snapshot(snap, workspace_id: ws.id)

      assert {:duplicate, second} =
               Snapshots.create_from_snapshot(snap, workspace_id: ws.id)

      assert first.id == second.id
    end

    test "two workspaces observing the same upstream payload get separate rows",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "morpho-snap-iso-#{System.unique_integer([:positive])}",
          name: "Morpho Snap ISO B"
        })

      snap = vault_snapshot()

      {:ok, a} = Snapshots.create_from_snapshot(snap, workspace_id: ws_a.id)
      {:ok, b} = Snapshots.create_from_snapshot(snap, workspace_id: ws_b.id)

      refute a.id == b.id
      assert a.payload_hash == b.payload_hash
    end

    test "workspace-agnostic re-import is also deduped on its own row" do
      snap = vault_snapshot()

      {:ok, first} = Snapshots.create_from_snapshot(snap)
      {:duplicate, second} = Snapshots.create_from_snapshot(snap)

      assert first.id == second.id
    end
  end

  describe "create_from_snapshot/2 — payload hash stability" do
    test "two snapshots with the same payload_hash dedupe to one row",
         %{workspace: ws} do
      shared_hash = String.duplicate("a", 64)

      snap_a = vault_snapshot(payload_hash: shared_hash, name: "A")
      snap_b = vault_snapshot(payload_hash: shared_hash, name: "B")

      {:ok, _} = Snapshots.create_from_snapshot(snap_a, workspace_id: ws.id)
      {:duplicate, _} = Snapshots.create_from_snapshot(snap_b, workspace_id: ws.id)
    end

    test "differing payload_hash → separate rows", %{workspace: ws} do
      snap_a = vault_snapshot(payload_hash: String.duplicate("a", 64))
      snap_b = vault_snapshot(payload_hash: String.duplicate("b", 64))

      {:ok, a} = Snapshots.create_from_snapshot(snap_a, workspace_id: ws.id)
      {:ok, b} = Snapshots.create_from_snapshot(snap_b, workspace_id: ws.id)

      refute a.id == b.id
    end
  end

  describe "lookup helpers" do
    test "latest_for_vault/3 returns the most recently fetched row",
         %{workspace: ws} do
      old =
        vault_snapshot(
          payload_hash: String.duplicate("1", 64),
          fetched_at: ~U[2026-01-01 00:00:00.000000Z]
        )

      new =
        vault_snapshot(
          payload_hash: String.duplicate("2", 64),
          fetched_at: ~U[2026-05-01 00:00:00.000000Z]
        )

      {:ok, _} = Snapshots.create_from_snapshot(old, workspace_id: ws.id)
      {:ok, new_record} = Snapshots.create_from_snapshot(new, workspace_id: ws.id)

      assert %SnapshotRecord{} =
               latest =
               Snapshots.latest_for_vault(@chain_id, @vault_address, workspace_id: ws.id)

      assert latest.id == new_record.id
    end

    test "list_for_workspace/2 returns workspace-scoped rows only",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "morpho-list-#{System.unique_integer([:positive])}",
          name: "Morpho List B"
        })

      {:ok, _} = Snapshots.create_from_snapshot(vault_snapshot(), workspace_id: ws_a.id)

      {:ok, _} =
        Snapshots.create_from_snapshot(
          vault_snapshot(payload_hash: String.duplicate("9", 64)),
          workspace_id: ws_b.id
        )

      ws_a_rows = Snapshots.list_for_workspace(ws_a.id)
      ws_b_rows = Snapshots.list_for_workspace(ws_b.id)

      assert length(ws_a_rows) == 1
      assert length(ws_b_rows) == 1
      assert hd(ws_a_rows).workspace_id == ws_a.id
      assert hd(ws_b_rows).workspace_id == ws_b.id
    end

    test "list_for_workspace/2 returns [] for nil / non-binary workspace" do
      assert Snapshots.list_for_workspace(nil) == []
      assert Snapshots.list_for_workspace(:bogus) == []
    end

    test "get_by_correlation/1 returns [] for nil / non-binary input" do
      assert Snapshots.get_by_correlation(nil) == []
      assert Snapshots.get_by_correlation(:bogus) == []
    end
  end

  describe "freshness/2 (#199)" do
    setup do
      now = ~U[2026-05-04 12:00:00.000000Z]
      %{now: now}
    end

    test "fresh values across all categories when fetched_at is now",
         %{workspace: ws, now: now} do
      {:ok, record} =
        Snapshots.create_from_snapshot(
          vault_snapshot(fetched_at: now),
          workspace_id: ws.id
        )

      assert %{
               vault_identity: :fresh,
               allocation: :fresh,
               warnings: :fresh,
               apy: :fresh
             } = Snapshots.freshness(record, now: now)
    end

    test "allocation + warnings flip to :stale at 6m, :expired at 11m",
         %{workspace: ws, now: now} do
      {:ok, record} =
        Snapshots.create_from_snapshot(
          vault_snapshot(fetched_at: DateTime.add(now, -6 * 60, :second)),
          workspace_id: ws.id
        )

      assert %{allocation: :stale, warnings: :stale} =
               Snapshots.freshness(record, now: now)

      {:ok, expired_record} =
        Snapshots.create_from_snapshot(
          vault_snapshot(
            payload_hash: String.duplicate("e", 64),
            fetched_at: DateTime.add(now, -11 * 60, :second)
          ),
          workspace_id: ws.id
        )

      assert %{allocation: :expired, warnings: :expired} =
               Snapshots.freshness(expired_record, now: now)
    end

    test "vault_identity stays :fresh until 24h, :stale through 48h, then :expired",
         %{workspace: ws, now: now} do
      {:ok, fresh_24h} =
        Snapshots.create_from_snapshot(
          vault_snapshot(
            payload_hash: String.duplicate("1", 64),
            fetched_at: DateTime.add(now, -23 * 3600, :second)
          ),
          workspace_id: ws.id
        )

      assert %{vault_identity: :fresh} = Snapshots.freshness(fresh_24h, now: now)

      {:ok, stale_36h} =
        Snapshots.create_from_snapshot(
          vault_snapshot(
            payload_hash: String.duplicate("2", 64),
            fetched_at: DateTime.add(now, -36 * 3600, :second)
          ),
          workspace_id: ws.id
        )

      assert %{vault_identity: :stale} = Snapshots.freshness(stale_36h, now: now)

      {:ok, expired_72h} =
        Snapshots.create_from_snapshot(
          vault_snapshot(
            payload_hash: String.duplicate("3", 64),
            fetched_at: DateTime.add(now, -72 * 3600, :second)
          ),
          workspace_id: ws.id
        )

      assert %{vault_identity: :expired} = Snapshots.freshness(expired_72h, now: now)
    end

    test "apy stays :fresh through 1h, :stale through 2h, then :expired",
         %{workspace: ws, now: now} do
      {:ok, fresh} =
        Snapshots.create_from_snapshot(
          vault_snapshot(
            payload_hash: String.duplicate("a", 64),
            fetched_at: DateTime.add(now, -50 * 60, :second)
          ),
          workspace_id: ws.id
        )

      assert %{apy: :fresh} = Snapshots.freshness(fresh, now: now)

      {:ok, stale} =
        Snapshots.create_from_snapshot(
          vault_snapshot(
            payload_hash: String.duplicate("b", 64),
            fetched_at: DateTime.add(now, -90 * 60, :second)
          ),
          workspace_id: ws.id
        )

      assert %{apy: :stale} = Snapshots.freshness(stale, now: now)

      {:ok, expired} =
        Snapshots.create_from_snapshot(
          vault_snapshot(
            payload_hash: String.duplicate("c", 64),
            fetched_at: DateTime.add(now, -3 * 3600, :second)
          ),
          workspace_id: ws.id
        )

      assert %{apy: :expired} = Snapshots.freshness(expired, now: now)
    end

    test "freshness/2 accepts per-call thresholds override",
         %{workspace: ws, now: now} do
      {:ok, record} =
        Snapshots.create_from_snapshot(
          vault_snapshot(fetched_at: DateTime.add(now, -2 * 3600, :second)),
          workspace_id: ws.id
        )

      # With the default threshold, allocation at 2h is :expired
      # (allocation max age is 5m, 2h > 2 * 5m).
      assert %{allocation: :expired} = Snapshots.freshness(record, now: now)

      # Override with a 4h threshold and the same record reads :fresh.
      assert %{allocation: :fresh} =
               Snapshots.freshness(record,
                 now: now,
                 freshness: %{allocation: 4 * 3600}
               )
    end

    test "freshness/2 returns nil for nil records" do
      assert Snapshots.freshness(nil, []) == nil
    end

    test "categories/0 returns the documented allowlist" do
      assert Snapshots.categories() == [:vault_identity, :allocation, :warnings, :apy]
    end
  end

  # --- helpers ----------------------------------------------------------

  defp vault_snapshot(opts \\ []) do
    %VaultSnapshot{
      vault_address: @vault_address,
      name: Keyword.get(opts, :name, "Steakhouse USDC"),
      symbol: "steakUSDC",
      chain_id: @chain_id,
      network: "ethereum",
      listed: true,
      deposit_asset: %{
        address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        symbol: "USDC",
        decimals: 6
      },
      state: %{
        apy: "0.058",
        net_apy: "0.052",
        total_assets: "12345678901234",
        fee: "0.05",
        timelock: 86_400
      },
      allocations: [
        %{
          market_unique_key: "0x1111111111111111111111111111111111111111111111111111111111111111",
          loan_asset: "USDC",
          collateral_asset: "wstETH",
          oracle: "0xoracle0000000000000000000000000000000001",
          irm: "0xirm00000000000000000000000000000000000001",
          lltv: 86,
          supply_cap: "10000000000000",
          supplied_assets: "4200000000000",
          supplied_assets_usd: "4200000.00"
        }
      ],
      warnings: [%{raw_type: "vault_listed", raw_level: "INFO"}],
      pending_caps: [
        %{
          market_unique_key: "0x2222222222222222222222222222222222222222222222222222222222222222",
          cap: "20000000000000",
          valid_at: "1714400000"
        }
      ],
      allocators: [%{address: "0xaaaa000000000000000000000000000000000000"}],
      source: %{
        fetched_at: Keyword.get(opts, :fetched_at, ~U[2026-04-29 10:00:00.000000Z]),
        source_name: "morpho_blue_graphql",
        source_schema_version: "v1.0",
        source_warnings: ["whitelisted is deprecated; use listed"],
        payload_hash: Keyword.get(opts, :payload_hash, String.duplicate("0", 64))
      }
    }
  end
end
