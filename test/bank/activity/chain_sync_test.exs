defmodule Bank.Activity.ChainSyncTest do
  @moduledoc """
  Tests for the read-only wallet/smart-account chain activity sync
  (#245). All tests use the injectable `:rpc_fn` opt — never live
  network — to drive every branch deterministically.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Ecto.Query

  alias Bank.Activity
  alias Bank.Activity.ChainSync
  alias Bank.Activity.ChainSyncCursor
  alias Bank.Activity.ImportedActivity
  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Repo

  @asset_address "0x036cbd53842c5426634e7929541ec2318f3dcf7e"
  @watched "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @sender "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @recipient "0xcccccccccccccccccccccccccccccccccccccccc"

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "chainsync-#{System.unique_integer([:positive])}",
        name: "ChainSync"
      })

    %{workspace: ws}
  end

  describe "sync_address/4 — happy path (#245)" do
    test "fixture inbound transfer is normalized into the imported ledger",
         %{workspace: ws} do
      head_block = 1_000

      transfer_log =
        log(
          tx_hash: "0xtx1",
          log_index: "0x0",
          block_number: 800,
          from: @sender,
          to: @watched,
          amount: 25 * 1_000_000
        )

      rpc_fn = canned_rpc(head_block, %{800 => [transfer_log]})

      assert {:ok, %{inserted: 1, duplicates: 0, last_block: last}} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn
               )

      # Cursor advanced to head - confirmations.
      assert last == head_block - 12

      [row] = Activity.list_imported_activities(workspace_id: ws.id)
      assert row.workspace_id == ws.id
      assert row.source_type == :wallet_chain
      assert row.chain == "base-sepolia"
      assert row.asset == "USDC"
      assert row.direction == :inbound
      assert row.from_address == @sender
      assert row.to_address == @watched
      assert row.tx_hash == "0xtx1"
      assert row.provenance == "chain_rpc"
      assert row.confidence == :high
      assert Decimal.equal?(row.amount, Decimal.new("25.000000"))
    end

    test "outbound transfer (watched is `from`) maps to direction :outbound",
         %{workspace: ws} do
      rpc_fn =
        canned_rpc(500, %{
          400 => [
            log(
              tx_hash: "0xtx-out",
              log_index: "0x1",
              block_number: 400,
              from: @watched,
              to: @recipient,
              amount: 7 * 1_000_000
            )
          ]
        })

      assert {:ok, %{inserted: 1}} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn
               )

      [row] = Activity.list_imported_activities(workspace_id: ws.id)
      assert row.direction == :outbound
      assert row.from_address == @watched
      assert row.to_address == @recipient
    end

    test "logs that don't involve the watched address are skipped",
         %{workspace: ws} do
      rpc_fn =
        canned_rpc(500, %{
          400 => [
            log(
              tx_hash: "0xtx-noise",
              log_index: "0x0",
              block_number: 400,
              from: @sender,
              to: @recipient,
              amount: 1
            )
          ]
        })

      assert {:ok, %{inserted: 0, duplicates: 0}} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn
               )

      assert Activity.list_imported_activities(workspace_id: ws.id) == []
    end
  end

  describe "sync_address/4 — duplicates and reorg (#245)" do
    test "running sync twice over the same fixture does not duplicate ledger rows",
         %{workspace: ws} do
      transfer =
        log(
          tx_hash: "0xtx-dup",
          log_index: "0x0",
          block_number: 800,
          from: @sender,
          to: @watched,
          amount: 5 * 1_000_000
        )

      rpc_fn = canned_rpc(1_000, %{800 => [transfer]})

      {:ok, _} =
        ChainSync.sync_address(ws.id, "base-sepolia", @watched,
          asset_address: @asset_address,
          rpc_fn: rpc_fn
        )

      # Second run — same RPC fixture. Cursor's reorg-rewind still
      # picks up the same window, but ledger dedupe collapses it.
      {:ok, %{inserted: ins2, duplicates: dup2}} =
        ChainSync.sync_address(ws.id, "base-sepolia", @watched,
          asset_address: @asset_address,
          rpc_fn: rpc_fn
        )

      # Either the rewind window includes the block (duplicate=1)
      # or it doesn't (no logs returned, inserted=0). Either way
      # ledger row count is exactly 1.
      assert ins2 == 0
      assert dup2 in [0, 1]

      assert Repo.aggregate(
               from(a in ImportedActivity, where: a.workspace_id == ^ws.id),
               :count,
               :id
             ) == 1
    end

    test "reorg-ish: same block resyncs but ledger stays at one row per dedupe key",
         %{workspace: ws} do
      transfer =
        log(
          tx_hash: "0xreorg-tx",
          log_index: "0x0",
          block_number: 800,
          from: @sender,
          to: @watched,
          amount: 10 * 1_000_000
        )

      rpc_fn = canned_rpc(1_000, %{800 => [transfer]})

      {:ok, _} =
        ChainSync.sync_address(ws.id, "base-sepolia", @watched,
          asset_address: @asset_address,
          rpc_fn: rpc_fn
        )

      # Simulate a chain that reorganized and surfaces the same
      # event again on the next sync. Idempotent ledger means no
      # duplicate row.
      {:ok, _} =
        ChainSync.sync_address(ws.id, "base-sepolia", @watched,
          asset_address: @asset_address,
          rpc_fn: rpc_fn
        )

      assert length(Activity.list_imported_activities(workspace_id: ws.id)) == 1
    end
  end

  describe "sync_address/4 — source failures are visible (#245)" do
    test "rpc transport error records sanitized cursor.last_error and does not crash",
         %{workspace: ws} do
      rpc_fn = fn _request -> {:error, "rpc_unavailable"} end

      assert {:error, :rpc_unavailable} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn
               )

      cursor = ChainSync.get_cursor(ws.id, "base-sepolia", :wallet_chain, @watched)
      assert cursor.last_error == "rpc_unavailable"
      assert %DateTime{} = cursor.last_error_at
      assert cursor.last_block_number == 0
      # No ledger rows on a source failure.
      assert Activity.list_imported_activities(workspace_id: ws.id) == []
    end

    test "unrecognized error labels collapse to fixed 'rpc_error' on the cursor",
         %{workspace: ws} do
      # An unexpected label (e.g. one a future RPC source returns)
      # MUST collapse to the allowlist instead of being persisted
      # raw — so a leak in a future caller cannot reach the cursor.
      rpc_fn = fn _request -> {:error, "https://[email protected] sk_live"} end

      assert {:error, :rpc_unavailable} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn
               )

      cursor = ChainSync.get_cursor(ws.id, "base-sepolia", :wallet_chain, @watched)
      assert cursor.last_error == "rpc_error"

      for needle <- ["https://", "secret", "sk_live"] do
        refute String.contains?(cursor.last_error, needle),
               "cursor.last_error must not leak #{needle}: #{inspect(cursor.last_error)}"
      end
    end

    test "successful sync after a prior error clears last_error / last_error_at",
         %{workspace: ws} do
      fail_fn = fn _ -> {:error, "rpc_unavailable"} end

      _ =
        ChainSync.sync_address(ws.id, "base-sepolia", @watched,
          asset_address: @asset_address,
          rpc_fn: fail_fn
        )

      cursor = ChainSync.get_cursor(ws.id, "base-sepolia", :wallet_chain, @watched)
      assert cursor.last_error == "rpc_unavailable"

      ok_fn = canned_rpc(1_000, %{})

      assert {:ok, _} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: ok_fn
               )

      cursor = ChainSync.get_cursor(ws.id, "base-sepolia", :wallet_chain, @watched)
      assert is_nil(cursor.last_error)
      assert is_nil(cursor.last_error_at)
      assert %DateTime{} = cursor.last_synced_at
    end
  end

  describe "sync_address/4 — workspace isolation (#245)" do
    test "workspace A's cursor + activity never surface in workspace B's view",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "chainsync-iso-#{System.unique_integer([:positive])}",
          name: "ChainSync ISO B"
        })

      transfer =
        log(
          tx_hash: "0xiso",
          log_index: "0x0",
          block_number: 600,
          from: @sender,
          to: @watched,
          amount: 1_000_000
        )

      rpc_fn = canned_rpc(800, %{600 => [transfer]})

      {:ok, _} =
        ChainSync.sync_address(ws_a.id, "base-sepolia", @watched,
          asset_address: @asset_address,
          rpc_fn: rpc_fn
        )

      # Workspace A sees its row + cursor; workspace B sees nothing.
      assert length(Activity.list_imported_activities(workspace_id: ws_a.id)) == 1
      assert Activity.list_imported_activities(workspace_id: ws_b.id) == []

      assert %ChainSyncCursor{} =
               ChainSync.get_cursor(ws_a.id, "base-sepolia", :wallet_chain, @watched)

      assert is_nil(ChainSync.get_cursor(ws_b.id, "base-sepolia", :wallet_chain, @watched))
      assert ChainSync.list_cursors(ws_b.id) == []
    end
  end

  describe "sync_address/4 — input validation (#245)" do
    test "nil workspace returns :invalid_workspace" do
      assert {:error, :invalid_workspace} =
               ChainSync.sync_address(nil, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: fn _ -> {:ok, "0x1"} end
               )
    end

    test "unsupported chain returns :unsupported_chain", %{workspace: ws} do
      assert {:error, :unsupported_chain} =
               ChainSync.sync_address(ws.id, "ethereum-mainnet", @watched,
                 asset_address: @asset_address,
                 rpc_fn: fn _ -> {:ok, "0x1"} end
               )
    end

    test "invalid address returns :invalid_address", %{workspace: ws} do
      assert {:error, :invalid_address} =
               ChainSync.sync_address(ws.id, "base-sepolia", "",
                 asset_address: @asset_address,
                 rpc_fn: fn _ -> {:ok, "0x1"} end
               )
    end

    test "missing asset_address returns :missing_asset_address", %{workspace: ws} do
      assert {:error, :missing_asset_address} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 rpc_fn: fn _ -> {:ok, "0x1"} end
               )
    end
  end

  describe "sync_address/4 — no chain side effects (#245)" do
    test "successful sync writes ledger rows but no Oban jobs / execution plans / audit events",
         %{workspace: ws} do
      transfer =
        log(
          tx_hash: "0xnosfx",
          log_index: "0x0",
          block_number: 700,
          from: @sender,
          to: @watched,
          amount: 1_000_000
        )

      rpc_fn = canned_rpc(900, %{700 => [transfer]})

      {:ok, _} =
        ChainSync.sync_address(ws.id, "base-sepolia", @watched,
          asset_address: @asset_address,
          rpc_fn: rpc_fn
        )

      # Activity row exists.
      assert length(Activity.list_imported_activities(workspace_id: ws.id)) == 1

      # No execution plans created.
      assert Repo.aggregate(ExecutionPlan, :count, :id) == 0

      # No audit events emitted by the sync path.
      assert Repo.aggregate(AuditEvent, :count, :id) == 0

      # No Oban jobs enqueued — this slice is read-only and does
      # NOT run as a worker.
      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
      refute_enqueued(worker: Bank.Runtime.Workers.GrantDelegation)
      refute_enqueued(worker: Bank.Runtime.Workers.RevokeDelegation)
    end
  end

  describe "get_cursor/4 + list_cursors/1" do
    test "return nil / [] for nil or non-binary workspace" do
      assert is_nil(ChainSync.get_cursor(nil, "base-sepolia", :wallet_chain, @watched))
      assert is_nil(ChainSync.get_cursor(:bogus, "base-sepolia", :wallet_chain, @watched))
      assert ChainSync.list_cursors(nil) == []
      assert ChainSync.list_cursors(:bogus) == []
    end
  end

  describe "sync_address/4 — initial sync window (#245 P2)" do
    test "fresh cursor on a high-head chain seeds from a recent confirmed range, not genesis",
         %{workspace: ws} do
      head = 5_000_000
      max_blocks = 1_000

      # The recent-window heuristic is
      # `from = max(confirmed_head - max_blocks + 1, 0)` =
      # 5_000_000 - 12 - 1_000 + 1 = 4_998_989. A near-head transfer
      # at block 4_999_500 should land in the first run. A genesis-
      # window transfer at block 100 must NOT.
      near_head_block = 4_999_500
      genesis_block = 100

      near_head =
        log(
          tx_hash: "0xnear-head",
          log_index: "0x0",
          block_number: near_head_block,
          from: @sender,
          to: @watched,
          amount: 50 * 1_000_000
        )

      genesis_log =
        log(
          tx_hash: "0xgenesis",
          log_index: "0x0",
          block_number: genesis_block,
          from: @sender,
          to: @watched,
          amount: 1
        )

      rpc_fn =
        canned_rpc(head, %{
          near_head_block => [near_head],
          genesis_block => [genesis_log]
        })

      assert {:ok, %{inserted: 1, last_block: last}} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn,
                 max_blocks: max_blocks
               )

      # Cursor advanced to head - confirmations (single-run window
      # exactly covers max_blocks at the tail of the chain).
      assert last == head - 12

      [row] = Activity.list_imported_activities(workspace_id: ws.id)
      assert row.tx_hash == "0xnear-head"
      refute row.tx_hash == "0xgenesis"
    end

    test ":start_block opt overrides the recent-window heuristic for known deployment block",
         %{workspace: ws} do
      head = 5_000_000

      old_block = 100

      old_log =
        log(
          tx_hash: "0xold",
          log_index: "0x0",
          block_number: old_block,
          from: @sender,
          to: @watched,
          amount: 1_000_000
        )

      rpc_fn = canned_rpc(head, %{old_block => [old_log]})

      # With :start_block = 50, the first run covers [50, 50 +
      # max_blocks - 1]. Block 100 must be picked up.
      assert {:ok, %{inserted: 1}} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn,
                 max_blocks: 1_000,
                 start_block: 50
               )

      [row] = Activity.list_imported_activities(workspace_id: ws.id)
      assert row.tx_hash == "0xold"
    end

    test "second sync after fresh-window seeding resumes from cursor and reorg-rewind, not genesis",
         %{workspace: ws} do
      head_1 = 5_000_000
      head_2 = 5_000_500

      first =
        log(
          tx_hash: "0xrun1",
          log_index: "0x0",
          block_number: 4_999_700,
          from: @sender,
          to: @watched,
          amount: 1_000_000
        )

      rpc_1 = canned_rpc(head_1, %{4_999_700 => [first]})

      {:ok, _} =
        ChainSync.sync_address(ws.id, "base-sepolia", @watched,
          asset_address: @asset_address,
          rpc_fn: rpc_1,
          max_blocks: 1_000
        )

      cursor = ChainSync.get_cursor(ws.id, "base-sepolia", :wallet_chain, @watched)
      assert cursor.last_block_number == head_1 - 12

      # On the second run, the next window is `[last_block + 1 -
      # rewind, head_2 - confirmations]`. Anything inside that
      # window — and only that — must surface.
      second_block = 5_000_400

      second =
        log(
          tx_hash: "0xrun2",
          log_index: "0x0",
          block_number: second_block,
          from: @sender,
          to: @watched,
          amount: 2_000_000
        )

      rpc_2 = canned_rpc(head_2, %{second_block => [second]})

      assert {:ok, %{inserted: 1, last_block: last2}} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_2,
                 max_blocks: 1_000
               )

      assert last2 == head_2 - 12
      assert length(Activity.list_imported_activities(workspace_id: ws.id)) == 2
    end
  end

  describe "sync_address/4 — block timestamps (#245 P2)" do
    test "occurred_at uses the real block timestamp, not block-number-as-unix-seconds",
         %{workspace: ws} do
      block_number = 800
      block_ts = 1_710_000_800

      transfer =
        log(
          tx_hash: "0xts",
          log_index: "0x0",
          block_number: block_number,
          from: @sender,
          to: @watched,
          amount: 1_000_000
        )

      rpc_fn = fn
        %{method: "eth_blockNumber"} ->
          {:ok, "0x3e8"}

        %{method: "eth_getLogs"} ->
          {:ok, [transfer]}

        %{method: "eth_getBlockByNumber", params: [block_hex, false]} ->
          assert parse_hex(block_hex) == block_number

          {:ok, %{"timestamp" => "0x" <> (Integer.to_string(block_ts, 16) |> String.downcase())}}
      end

      assert {:ok, %{inserted: 1}} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn
               )

      [row] = Activity.list_imported_activities(workspace_id: ws.id)
      # The DB column is utc_datetime_usec, so compare on the
      # underlying unix second to avoid microsecond-precision
      # noise.
      assert DateTime.to_unix(row.occurred_at, :second) == block_ts

      # Block-number-as-unix-seconds (the buggy P2 behavior) would
      # produce a 1970-era timestamp; assert we did NOT do that.
      refute DateTime.to_unix(row.occurred_at, :second) == block_number
      assert row.occurred_at.year >= 2024
    end

    test "multiple logs in the same block share one eth_getBlockByNumber call",
         %{workspace: ws} do
      block_number = 800
      block_ts = 1_710_000_800

      transfer_a =
        log(
          tx_hash: "0xa",
          log_index: "0x0",
          block_number: block_number,
          from: @sender,
          to: @watched,
          amount: 1_000_000
        )

      transfer_b =
        log(
          tx_hash: "0xb",
          log_index: "0x1",
          block_number: block_number,
          from: @watched,
          to: @recipient,
          amount: 2_000_000
        )

      counter = :counters.new(1, [])

      rpc_fn = fn
        %{method: "eth_blockNumber"} ->
          {:ok, "0x3e8"}

        %{method: "eth_getLogs"} ->
          {:ok, [transfer_a, transfer_b]}

        %{method: "eth_getBlockByNumber", params: [_block_hex, false]} ->
          :counters.add(counter, 1, 1)

          {:ok, %{"timestamp" => "0x" <> (Integer.to_string(block_ts, 16) |> String.downcase())}}
      end

      assert {:ok, %{inserted: 2}} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn
               )

      assert :counters.get(counter, 1) == 1
    end

    test "block-timestamp fetch failure records sanitized cursor.last_error and does not advance",
         %{workspace: ws} do
      transfer =
        log(
          tx_hash: "0xts-fail",
          log_index: "0x0",
          block_number: 800,
          from: @sender,
          to: @watched,
          amount: 1_000_000
        )

      rpc_fn = fn
        %{method: "eth_blockNumber"} ->
          {:ok, "0x3e8"}

        %{method: "eth_getLogs"} ->
          {:ok, [transfer]}

        %{method: "eth_getBlockByNumber", params: [_, false]} ->
          {:error, "timeout"}
      end

      assert {:error, :rpc_unavailable} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn
               )

      cursor = ChainSync.get_cursor(ws.id, "base-sepolia", :wallet_chain, @watched)
      assert cursor.last_error == "timeout"
      assert cursor.last_block_number == 0
      # Critically: no synthetic 1970 row was inserted.
      assert Activity.list_imported_activities(workspace_id: ws.id) == []
    end
  end

  describe "sync_address/4 — smart-account callback-backed import (#245)" do
    test "active delegation with on-chain anchors imports as :inbound ledger row",
         %{workspace: ws} do
      sa = "sa-grant-#{System.unique_integer([:positive])}"
      tx = "0xinstalltxhashgranted000000000000000000000000000000000000000000001"
      granted_at = DateTime.utc_now() |> DateTime.truncate(:second)

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :active,
          granted_at: granted_at,
          install_tx_hash: tx,
          kernel_version: "0.3.1"
        )

      assert {:ok, %{inserted: 1, duplicates: 0}} =
               ChainSync.sync_address(ws.id, "base-sepolia", sa,
                 source_type: :smart_account_chain
               )

      [row] = Activity.list_imported_activities(workspace_id: ws.id)
      assert row.workspace_id == ws.id
      assert row.source_type == :smart_account_chain
      assert row.chain == "base-sepolia"
      assert row.direction == :inbound
      assert row.tx_hash == tx
      assert row.from_address == nil
      assert row.to_address == sa
      assert row.provenance == "smart_account_callback"
      assert row.confidence == :high
      assert row.metadata["kind"] == "delegation.granted"
      assert row.metadata["smart_account_id"] == sa
      assert row.metadata["kernel_version"] == "0.3.1"
      assert Decimal.equal?(row.amount, Decimal.new(0))
    end

    test "revoked delegation imports as :outbound ledger row",
         %{workspace: ws} do
      sa = "sa-revoke-#{System.unique_integer([:positive])}"
      tx = "0xrevoketxhash000000000000000000000000000000000000000000000000002"
      revoked_at = DateTime.utc_now() |> DateTime.truncate(:second)

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :revoked,
          revoked_at: revoked_at,
          last_tx_hash: tx,
          last_reason: "operator_request"
        )

      assert {:ok, %{inserted: 1}} =
               ChainSync.sync_address(ws.id, "base-sepolia", sa,
                 source_type: :smart_account_chain
               )

      [row] = Activity.list_imported_activities(workspace_id: ws.id)
      assert row.direction == :outbound
      assert row.from_address == sa
      assert row.to_address == nil
      assert row.tx_hash == tx
      assert row.metadata["kind"] == "delegation.revoked"
      assert row.metadata["last_reason"] == "operator_request"
    end

    test "execution plan with confirmed final_outcome imports one row per tx_ref",
         %{workspace: ws} do
      sa = "sa-exec-#{System.unique_integer([:positive])}"
      tx_a = "0xexec-tx-a-0000000000000000000000000000000000000000000000000003"
      tx_b = "0xexec-tx-b-0000000000000000000000000000000000000000000000000004"

      _ =
        Bank.Fixtures.execution_plan(%{
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          asset: "USDC",
          tx_refs: [tx_a, tx_b],
          execution_status: :confirmed,
          final_outcome: :confirmed,
          final_reason: "ok"
        })

      assert {:ok, %{inserted: 2}} =
               ChainSync.sync_address(ws.id, "base-sepolia", sa,
                 source_type: :smart_account_chain
               )

      rows =
        Activity.list_imported_activities(workspace_id: ws.id)
        |> Enum.sort_by(& &1.tx_hash)

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.source_type == :smart_account_chain))
      assert Enum.all?(rows, &(&1.direction == :outbound))
      assert Enum.all?(rows, &(&1.from_address == sa))
      assert Enum.all?(rows, &(&1.metadata["kind"] == "execution.confirmed"))
      assert Enum.map(rows, & &1.tx_hash) == Enum.sort([tx_a, tx_b])
    end

    test "in-flight execution plan (no final_outcome) is NOT imported",
         %{workspace: ws} do
      sa = "sa-pending-#{System.unique_integer([:positive])}"

      _ =
        Bank.Fixtures.execution_plan(%{
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          tx_refs: ["0xpending-tx-000000000000000000000000000000000000000000000005"],
          execution_status: :pending_confirmation,
          final_outcome: nil
        })

      assert {:ok, %{inserted: 0, duplicates: 0}} =
               ChainSync.sync_address(ws.id, "base-sepolia", sa,
                 source_type: :smart_account_chain
               )

      assert Activity.list_imported_activities(workspace_id: ws.id) == []
    end

    test "rerunning the smart-account sync does not duplicate ledger rows",
         %{workspace: ws} do
      sa = "sa-idem-#{System.unique_integer([:positive])}"
      tx = "0xidempotent-tx-000000000000000000000000000000000000000000000006"
      granted_at = DateTime.utc_now() |> DateTime.truncate(:second)

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :active,
          granted_at: granted_at,
          install_tx_hash: tx
        )

      {:ok, _} =
        ChainSync.sync_address(ws.id, "base-sepolia", sa, source_type: :smart_account_chain)

      {:ok, %{inserted: ins2, duplicates: dup2}} =
        ChainSync.sync_address(ws.id, "base-sepolia", sa, source_type: :smart_account_chain)

      assert ins2 == 0
      assert dup2 == 1
      assert length(Activity.list_imported_activities(workspace_id: ws.id)) == 1
    end

    test "smart-account sync is workspace-scoped: ws-A activity does not leak into ws-B",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "chainsync-sa-iso-#{System.unique_integer([:positive])}",
          name: "ChainSync SA ISO"
        })

      sa = "sa-iso-#{System.unique_integer([:positive])}"
      tx = "0xiso-sa-tx-00000000000000000000000000000000000000000000000000007"
      granted_at = DateTime.utc_now() |> DateTime.truncate(:second)

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws_a.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :active,
          granted_at: granted_at,
          install_tx_hash: tx
        )

      {:ok, _} =
        ChainSync.sync_address(ws_a.id, "base-sepolia", sa, source_type: :smart_account_chain)

      # Even with the same smart_account_id, ws-B sees nothing.
      {:ok, %{inserted: 0}} =
        ChainSync.sync_address(ws_b.id, "base-sepolia", sa, source_type: :smart_account_chain)

      assert length(Activity.list_imported_activities(workspace_id: ws_a.id)) == 1
      assert Activity.list_imported_activities(workspace_id: ws_b.id) == []
    end

    test "no chain side effects: smart-account sync emits no Oban jobs / plans / audit events",
         %{workspace: ws} do
      sa = "sa-nosfx-#{System.unique_integer([:positive])}"
      tx = "0xno-sfx-tx-00000000000000000000000000000000000000000000000000008"

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :active,
          granted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          install_tx_hash: tx
        )

      audit_count_before = Repo.aggregate(AuditEvent, :count, :id)
      plan_count_before = Repo.aggregate(ExecutionPlan, :count, :id)

      {:ok, _} =
        ChainSync.sync_address(ws.id, "base-sepolia", sa, source_type: :smart_account_chain)

      # Sync wrote the imported_activity row, but did NOT emit
      # any audit event, did NOT create any new execution plan,
      # and did NOT enqueue any dispatch job.
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count_before
      assert Repo.aggregate(ExecutionPlan, :count, :id) == plan_count_before

      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
      refute_enqueued(worker: Bank.Runtime.Workers.GrantDelegation)
      refute_enqueued(worker: Bank.Runtime.Workers.RevokeDelegation)
    end

    test "no smart-account rows = no-op success with cursor advanced",
         %{workspace: ws} do
      sa = "sa-empty-#{System.unique_integer([:positive])}"

      assert {:ok, %{inserted: 0, duplicates: 0}} =
               ChainSync.sync_address(ws.id, "base-sepolia", sa,
                 source_type: :smart_account_chain
               )

      assert %ChainSyncCursor{} =
               cursor = ChainSync.get_cursor(ws.id, "base-sepolia", :smart_account_chain, sa)

      assert cursor.last_synced_at != nil
      assert is_nil(cursor.last_error)
    end
  end

  describe "sync_address/4 — smart-account first-sync grant retention (#245 P2)" do
    test "revoked delegation with both anchors imports BOTH grant and revoke rows on first run",
         %{workspace: ws} do
      sa = "sa-grant-then-revoke-#{System.unique_integer([:positive])}"
      grant_tx = "0xgrant-tx-00000000000000000000000000000000000000000000000000001"
      revoke_tx = "0xrevoke-tx-0000000000000000000000000000000000000000000000000002"
      granted_at = ~U[2026-01-01 12:00:00.000000Z]
      revoked_at = ~U[2026-02-01 12:00:00.000000Z]

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :revoked,
          granted_at: granted_at,
          install_tx_hash: grant_tx,
          revoked_at: revoked_at,
          last_tx_hash: revoke_tx,
          kernel_version: "0.3.1"
        )

      # First sync after the row is already terminal must still
      # import the original grant. Otherwise the on-chain history
      # is permanently lost from the ledger.
      assert {:ok, %{inserted: 2, duplicates: 0}} =
               ChainSync.sync_address(ws.id, "base-sepolia", sa,
                 source_type: :smart_account_chain
               )

      rows = Activity.list_imported_activities(workspace_id: ws.id)
      kinds = rows |> Enum.map(& &1.metadata["kind"]) |> Enum.sort()
      assert kinds == ["delegation.granted", "delegation.revoked"]

      grant_row = Enum.find(rows, &(&1.metadata["kind"] == "delegation.granted"))
      revoke_row = Enum.find(rows, &(&1.metadata["kind"] == "delegation.revoked"))

      assert grant_row.tx_hash == grant_tx
      assert grant_row.direction == :inbound
      assert grant_row.to_address == sa
      assert grant_row.from_address == nil

      assert revoke_row.tx_hash == revoke_tx
      assert revoke_row.direction == :outbound
      assert revoke_row.from_address == sa
      assert revoke_row.to_address == nil
    end

    test "second sync over the same revoked-with-grant row does not duplicate either ledger entry",
         %{workspace: ws} do
      sa = "sa-grant-revoke-idem-#{System.unique_integer([:positive])}"
      grant_tx = "0xidem-grant-000000000000000000000000000000000000000000000000003"
      revoke_tx = "0xidem-revoke-00000000000000000000000000000000000000000000000004"

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :revoked,
          granted_at: ~U[2026-01-01 12:00:00.000000Z],
          install_tx_hash: grant_tx,
          revoked_at: ~U[2026-02-01 12:00:00.000000Z],
          last_tx_hash: revoke_tx
        )

      {:ok, _} =
        ChainSync.sync_address(ws.id, "base-sepolia", sa, source_type: :smart_account_chain)

      assert {:ok, %{inserted: 0, duplicates: 2}} =
               ChainSync.sync_address(ws.id, "base-sepolia", sa,
                 source_type: :smart_account_chain
               )

      assert length(Activity.list_imported_activities(workspace_id: ws.id)) == 2
    end

    test "revoke_failed delegation also imports the prior grant",
         %{workspace: ws} do
      sa = "sa-revoke-failed-#{System.unique_integer([:positive])}"
      grant_tx = "0xrf-grant-tx-000000000000000000000000000000000000000000000000005"
      revoke_tx = "0xrf-revoke-tx-00000000000000000000000000000000000000000000000006"

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :revoke_failed,
          granted_at: ~U[2026-01-01 12:00:00.000000Z],
          install_tx_hash: grant_tx,
          last_tx_hash: revoke_tx
        )

      assert {:ok, %{inserted: 2}} =
               ChainSync.sync_address(ws.id, "base-sepolia", sa,
                 source_type: :smart_account_chain
               )

      kinds =
        Activity.list_imported_activities(workspace_id: ws.id)
        |> Enum.map(& &1.metadata["kind"])
        |> Enum.sort()

      assert kinds == ["delegation.granted", "delegation.revoke_failed"]
    end

    test "delegation with only revoke anchor (no install_tx_hash) emits only revoke",
         %{workspace: ws} do
      sa = "sa-no-grant-anchor-#{System.unique_integer([:positive])}"

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :revoked,
          last_tx_hash: "0xrevoke-only-00000000000000000000000000000000000000000000000007",
          revoked_at: ~U[2026-02-01 12:00:00.000000Z]
        )

      assert {:ok, %{inserted: 1}} =
               ChainSync.sync_address(ws.id, "base-sepolia", sa,
                 source_type: :smart_account_chain
               )

      [row] = Activity.list_imported_activities(workspace_id: ws.id)
      assert row.metadata["kind"] == "delegation.revoked"
    end
  end

  describe "sync_address/4 — smart-account reason metadata redaction (#245 P2)" do
    @secret_markers [
      "Bearer xyz123",
      "Authorization: token",
      "sk_live_AAAA",
      "sk_test_BBBB",
      "-----BEGIN PRIVATE KEY-----",
      "private_key=foo",
      "https://evil.example/?token=abc",
      "secret@example.com"
    ]

    test "delegation last_reason carrying secret markers is collapsed to '[REDACTED]'",
         %{workspace: ws} do
      for {leak, idx} <- Enum.with_index(@secret_markers) do
        sa = "sa-leak-d-#{idx}-#{System.unique_integer([:positive])}"
        revoke_tx = "0xleak-d-#{idx}-000000000000000000000000000000000000000000000000abc"

        _ =
          Bank.Fixtures.delegation(
            workspace_id: ws.id,
            smart_account_id: sa,
            chain: "base-sepolia",
            state: :revoked,
            revoked_at: ~U[2026-02-01 12:00:00.000000Z],
            last_tx_hash: revoke_tx,
            last_reason: "operator note: " <> leak <> " end"
          )

        {:ok, _} =
          ChainSync.sync_address(ws.id, "base-sepolia", sa, source_type: :smart_account_chain)

        row =
          Activity.list_imported_activities(workspace_id: ws.id)
          |> Enum.find(&(&1.metadata["smart_account_id"] == sa))

        assert row, "expected an imported row for #{sa}"
        assert row.metadata["last_reason"] == "[REDACTED]"

        for needle <- [
              "Bearer",
              "Authorization",
              "sk_live_",
              "sk_test_",
              "BEGIN PRIVATE KEY",
              "private_key",
              "https://",
              "secret@"
            ] do
          refute String.contains?(row.metadata["last_reason"], needle),
                 "marker #{inspect(needle)} leaked through last_reason for #{leak}"
        end
      end
    end

    test "execution final_reason carrying secret markers is collapsed to '[REDACTED]'",
         %{workspace: ws} do
      for {leak, idx} <- Enum.with_index(@secret_markers) do
        sa = "sa-leak-x-#{idx}-#{System.unique_integer([:positive])}"
        tx = "0xleak-x-#{idx}-tx-0000000000000000000000000000000000000000000000def"

        _ =
          Bank.Fixtures.execution_plan(%{
            workspace_id: ws.id,
            smart_account_id: sa,
            chain: "base-sepolia",
            asset: "USDC",
            tx_refs: [tx],
            execution_status: :reverted,
            final_outcome: :reverted,
            final_reason: "adapter said: " <> leak
          })

        {:ok, _} =
          ChainSync.sync_address(ws.id, "base-sepolia", sa, source_type: :smart_account_chain)

        row =
          Activity.list_imported_activities(workspace_id: ws.id)
          |> Enum.find(&(&1.metadata["smart_account_id"] == sa))

        assert row, "expected an imported row for #{sa}"
        assert row.metadata["final_reason"] == "[REDACTED]"

        for needle <- [
              "Bearer",
              "Authorization",
              "sk_live_",
              "sk_test_",
              "BEGIN PRIVATE KEY",
              "private_key",
              "https://",
              "secret@"
            ] do
          refute String.contains?(row.metadata["final_reason"], needle),
                 "marker #{inspect(needle)} leaked through final_reason for #{leak}"
        end
      end
    end

    test "benign reason text passes through with a length cap",
         %{workspace: ws} do
      sa = "sa-benign-#{System.unique_integer([:positive])}"
      tx = "0xbenign-tx-0000000000000000000000000000000000000000000000000000ee"

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :revoked,
          revoked_at: ~U[2026-02-01 12:00:00.000000Z],
          last_tx_hash: tx,
          last_reason: "operator_request"
        )

      {:ok, _} =
        ChainSync.sync_address(ws.id, "base-sepolia", sa, source_type: :smart_account_chain)

      [row] = Activity.list_imported_activities(workspace_id: ws.id)
      assert row.metadata["last_reason"] == "operator_request"
    end

    test "extremely long benign reason text is truncated, not redacted",
         %{workspace: ws} do
      sa = "sa-long-#{System.unique_integer([:positive])}"
      tx = "0xlong-tx-00000000000000000000000000000000000000000000000000000aa"
      huge = String.duplicate("a", 10_000)

      _ =
        Bank.Fixtures.delegation(
          workspace_id: ws.id,
          smart_account_id: sa,
          chain: "base-sepolia",
          state: :revoked,
          revoked_at: ~U[2026-02-01 12:00:00.000000Z],
          last_tx_hash: tx,
          last_reason: huge
        )

      {:ok, _} =
        ChainSync.sync_address(ws.id, "base-sepolia", sa, source_type: :smart_account_chain)

      [row] = Activity.list_imported_activities(workspace_id: ws.id)
      reason = row.metadata["last_reason"]
      assert is_binary(reason)
      assert byte_size(reason) <= 200
      assert reason != "[REDACTED]"
    end
  end

  describe "sync_address/4 — invalid source_type / malformed RPC hex (#245 hardening)" do
    test "unknown :source_type returns :invalid_source_type without writing a cursor",
         %{workspace: ws} do
      assert {:error, :invalid_source_type} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 source_type: :csv
               )

      # No cursor written for an invalid source_type.
      assert is_nil(ChainSync.get_cursor(ws.id, "base-sepolia", :csv, @watched))
    end

    test "malformed eth_blockNumber hex records sanitized 'invalid_response' instead of crashing",
         %{workspace: ws} do
      # A real RPC provider can return non-hex garbage on a bad day.
      # `String.to_integer/2` would raise ArgumentError; we must
      # surface a sanitized cursor error instead.
      rpc_fn = fn
        %{method: "eth_blockNumber"} -> {:ok, "0xZZZZ"}
        %{method: _} -> {:error, "rpc_unavailable"}
      end

      assert {:error, :invalid_response} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn
               )

      cursor = ChainSync.get_cursor(ws.id, "base-sepolia", :wallet_chain, @watched)
      assert cursor.last_error == "invalid_response"
      assert cursor.last_block_number == 0
      assert Activity.list_imported_activities(workspace_id: ws.id) == []
    end

    test "malformed eth_getBlockByNumber timestamp hex records sanitized error",
         %{workspace: ws} do
      transfer =
        log(
          tx_hash: "0xbadts",
          log_index: "0x0",
          block_number: 800,
          from: @sender,
          to: @watched,
          amount: 1_000_000
        )

      rpc_fn = fn
        %{method: "eth_blockNumber"} -> {:ok, "0x3e8"}
        %{method: "eth_getLogs"} -> {:ok, [transfer]}
        %{method: "eth_getBlockByNumber"} -> {:ok, %{"timestamp" => "0xQQQ"}}
      end

      assert {:error, :rpc_unavailable} =
               ChainSync.sync_address(ws.id, "base-sepolia", @watched,
                 asset_address: @asset_address,
                 rpc_fn: rpc_fn
               )

      cursor = ChainSync.get_cursor(ws.id, "base-sepolia", :wallet_chain, @watched)
      assert cursor.last_error == "invalid_response"
      assert Activity.list_imported_activities(workspace_id: ws.id) == []
    end
  end

  # ---- helpers ----

  # ERC-20 Transfer log shape produced by `eth_getLogs`.
  defp log(opts) do
    tx_hash = Keyword.fetch!(opts, :tx_hash)
    log_index = Keyword.fetch!(opts, :log_index)
    block_number = Keyword.fetch!(opts, :block_number)
    from_addr = Keyword.fetch!(opts, :from)
    to_addr = Keyword.fetch!(opts, :to)
    amount = Keyword.fetch!(opts, :amount)

    block_hex =
      "0x" <> (Integer.to_string(block_number, 16) |> String.downcase())

    %{
      "address" => @asset_address,
      "topics" => [
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        address_topic(from_addr),
        address_topic(to_addr)
      ],
      "data" => "0x" <> String.pad_leading(Integer.to_string(amount, 16), 64, "0"),
      "blockNumber" => block_hex,
      "transactionHash" => tx_hash,
      "logIndex" => log_index
    }
  end

  defp address_topic("0x" <> rest) do
    "0x" <> String.pad_leading(rest, 64, "0")
  end

  # Builds an `:rpc_fn` that responds to `eth_blockNumber` with
  # `head`, to `eth_getLogs` with the union of any logs whose
  # block_number falls inside the window, and to
  # `eth_getBlockByNumber` with a deterministic synthetic
  # timestamp `@base_block_ts + block` so multiple tests get
  # distinct, real `occurred_at` values without coupling to wall
  # clock. `logs_by_block` is a map `%{block_number => [log_map,
  # ...]}`.
  @base_block_ts 1_700_000_000

  defp canned_rpc(head, logs_by_block) do
    fn
      %{method: "eth_blockNumber"} ->
        {:ok, "0x" <> (Integer.to_string(head, 16) |> String.downcase())}

      %{method: "eth_getLogs", params: [%{"fromBlock" => from_hex, "toBlock" => to_hex}]} ->
        from = parse_hex(from_hex)
        to = parse_hex(to_hex)

        logs =
          logs_by_block
          |> Enum.filter(fn {b, _} -> b >= from and b <= to end)
          |> Enum.flat_map(fn {_, ls} -> ls end)

        {:ok, logs}

      %{method: "eth_getBlockByNumber", params: [block_hex, false]} ->
        block = parse_hex(block_hex)
        ts = @base_block_ts + block
        {:ok, %{"timestamp" => "0x" <> (Integer.to_string(ts, 16) |> String.downcase())}}
    end
  end

  defp parse_hex("0x" <> rest), do: String.to_integer(rest, 16)
end
