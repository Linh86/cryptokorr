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
  # `head` and to `eth_getLogs` with the union of any logs whose
  # block_number falls inside the window. `logs_by_block` is a map
  # `%{block_number => [log_map, ...]}`.
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
    end
  end

  defp parse_hex("0x" <> rest), do: String.to_integer(rest, 16)
end
