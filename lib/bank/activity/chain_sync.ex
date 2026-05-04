defmodule Bank.Activity.ChainSync do
  @moduledoc """
  Read-only wallet/smart-account chain activity sync (#245).

  Pulls USDC transfer events from a configured RPC source and
  normalizes them into the `Bank.Activity` imported-activity
  ledger. **Strictly read-only**: this module never broadcasts a
  transaction, signs a payload, calls
  `Bank.AdapterClient`, creates an `ExecutionPlan`, or enqueues an
  Oban dispatch job. The only write surface is
  `Bank.Activity.create_imported_activity/1` plus the cursor row
  on this module's own table.

  ## Workspace boundary

  Every read/write is scoped by `workspace_id`. The cursor table
  is workspace-keyed (`chain_sync_cursors_uniq` on
  `(workspace_id, chain, source_type, address)`). Activity rows
  carry `workspace_id` per the existing
  `Bank.Activity.ImportedActivity` contract.

  ## Conservative reorg handling

  The sync window is `[cursor.last_block_number + 1, head_block -
  confirmations]` minus a small rewind buffer
  (`@reorg_rewind_blocks`) on every run. That overlap re-fetches
  the last few blocks each time so a chain reorg that rewrote them
  is observed as new events from the source — but the activity
  ledger's deterministic dedupe (per
  `Bank.Activity.compute_dedupe_key/1` on
  `(source_type, source_ref, occurred_at, asset, direction,
  amount)`) collapses the duplicates idempotently.

  ## Source failures

  Any RPC failure is captured as a fixed-shape sanitized label
  (`"rpc_unavailable"`, `"rpc_error_5xx"`, `"timeout"`,
  `"invalid_response"`, etc.) on the cursor's `:last_error` /
  `:last_error_at` columns. The cursor's `:last_block_number` is
  NOT advanced — the next sync attempt retries from the same
  point. Operators see the failure on the cursor row; nothing is
  logged with raw provider URL or token text.

  ## Test injection

  `sync_address/4` accepts `:rpc_fn` in opts — a 1-arity function
  that takes a request map (`%{method: ..., params: [...]}`) and
  returns `{:ok, body}` / `{:error, label}`. Tests use this to
  drive every branch deterministically without hitting the
  network. The default RPC implementation is
  `Bank.Activity.ChainSync.RpcSource.call/1`, which itself returns
  `{:error, "rpc_not_configured"}` when no `:base_url` is set
  (the production-safe default for environments without an RPC
  endpoint).
  """

  import Ecto.Query

  alias Bank.Activity
  alias Bank.Activity.ChainSyncCursor
  alias Bank.Activity.ChainSync.RpcSource
  alias Bank.Repo

  # Number of confirmed blocks below head we treat as "settled".
  # Anything within this window is considered reorg-vulnerable
  # and is not synced this round.
  @confirmations 12

  # Number of blocks below the last synced cursor we re-fetch on
  # every run. The overlap means a reorg that rewrote these blocks
  # surfaces as new events; ledger dedupe collapses any unchanged
  # duplicates without writing twice.
  @reorg_rewind_blocks 6

  # ERC-20 Transfer(address,address,uint256) topic.
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  @typedoc "RPC source result for a single eth_* call."
  @type rpc_result :: {:ok, term()} | {:error, String.t()}

  @typedoc "Sync result envelope."
  @type sync_result ::
          {:ok,
           %{
             inserted: non_neg_integer(),
             duplicates: non_neg_integer(),
             last_block: non_neg_integer()
           }}
          | {:error, atom() | String.t()}

  @doc """
  Sync USDC `Transfer` events for `address` on `chain` into the
  workspace's imported-activity ledger.

  ## Args

    * `workspace_id` — required binary UUID; refuses nil to avoid
      cross-workspace writes.
    * `chain` — string chain id (Phase 1 supports `"base-sepolia"`
      only).
    * `address` — wallet or smart-account address watched.
      Lowercased server-side; the cursor stores the lowercased
      form.
    * `opts`:
        * `:source_type` (default `:wallet_chain`) — must be one of
          `Bank.Activity.ChainSyncCursor.source_types/0`.
        * `:rpc_fn` — test injection (see moduledoc).
        * `:max_blocks` — cap on the `[from, to]` window per call;
          default 1_000. Hard-capped at 5_000 even when callers
          pass higher.
        * `:asset_address` — ERC-20 contract address of the asset
          watched (USDC). Required; refuses nil.
        * `:asset` — ledger-side asset symbol (default `"USDC"`).
        * `:asset_decimals` — token decimals (default `6` for USDC).
  """
  @spec sync_address(String.t() | nil, String.t() | nil, String.t() | nil, keyword()) ::
          sync_result()
  def sync_address(workspace_id, _chain, _address, _opts)
      when not is_binary(workspace_id),
      do: {:error, :invalid_workspace}

  def sync_address(_workspace_id, chain, _address, _opts)
      when not is_binary(chain) or chain != "base-sepolia",
      do: {:error, :unsupported_chain}

  def sync_address(_workspace_id, _chain, address, _opts)
      when not is_binary(address) or address == "",
      do: {:error, :invalid_address}

  def sync_address(workspace_id, chain, address, opts) do
    asset_address = Keyword.get(opts, :asset_address)

    if not is_binary(asset_address) or asset_address == "" do
      {:error, :missing_asset_address}
    else
      source_type = Keyword.get(opts, :source_type, :wallet_chain)
      rpc_fn = Keyword.get(opts, :rpc_fn, &RpcSource.call/1)
      max_blocks = opts |> Keyword.get(:max_blocks, 1_000) |> min(5_000) |> max(1)
      asset = Keyword.get(opts, :asset, "USDC")
      decimals = Keyword.get(opts, :asset_decimals, 6)
      lowered_address = String.downcase(address)

      do_sync(workspace_id, chain, lowered_address, %{
        source_type: source_type,
        rpc_fn: rpc_fn,
        max_blocks: max_blocks,
        asset: asset,
        decimals: decimals,
        asset_address: String.downcase(asset_address)
      })
    end
  end

  @doc """
  Read-only cursor lookup for inspection / operator UI surfaces.
  Returns `nil` if no cursor exists (no sync has ever run for
  this tuple). Workspace-scoped.
  """
  @spec get_cursor(String.t() | nil, String.t(), atom(), String.t()) ::
          ChainSyncCursor.t() | nil
  def get_cursor(nil, _chain, _source_type, _address), do: nil

  def get_cursor(workspace_id, _chain, _source_type, _address) when not is_binary(workspace_id),
    do: nil

  def get_cursor(workspace_id, chain, source_type, address)
      when is_binary(chain) and is_atom(source_type) and is_binary(address) do
    Repo.one(
      from c in ChainSyncCursor,
        where:
          c.workspace_id == ^workspace_id and
            c.chain == ^chain and
            c.source_type == ^source_type and
            c.address == ^String.downcase(address)
    )
  end

  @doc """
  Workspace-scoped list of every cursor row, newest update first.
  Suitable for the operator console (`SecurityLive` or future
  ops surface). Returns `[]` for nil/non-binary workspace_id.
  """
  @spec list_cursors(String.t() | nil) :: [ChainSyncCursor.t()]
  def list_cursors(nil), do: []
  def list_cursors(workspace_id) when not is_binary(workspace_id), do: []

  def list_cursors(workspace_id) when is_binary(workspace_id) do
    from(c in ChainSyncCursor,
      where: c.workspace_id == ^workspace_id,
      order_by: [desc: c.updated_at]
    )
    |> Repo.all()
  end

  # --- internals ---------------------------------------------------------

  defp do_sync(workspace_id, chain, address, %{source_type: source_type} = ctx) do
    cursor = upsert_cursor(workspace_id, chain, source_type, address)

    case ctx.rpc_fn.(%{method: "eth_blockNumber", params: []}) do
      {:ok, head_hex} when is_binary(head_hex) ->
        head = parse_hex_quantity(head_hex)
        run_window(cursor, head, chain, address, ctx)

      {:ok, _other} ->
        record_error(cursor, "invalid_response")
        {:error, :invalid_response}

      {:error, label} when is_binary(label) ->
        record_error(cursor, label)
        {:error, :rpc_unavailable}
    end
  end

  defp run_window(%ChainSyncCursor{} = cursor, head, chain, address, ctx) do
    confirmed_head = max(head - @confirmations, 0)
    from_block = max(cursor.last_block_number + 1 - @reorg_rewind_blocks, 0)

    cond do
      confirmed_head < from_block ->
        # Nothing settled to sync yet. Treat as a no-op success;
        # clear any prior error envelope.
        advance_cursor(cursor, cursor.last_block_number)
        {:ok, %{inserted: 0, duplicates: 0, last_block: cursor.last_block_number}}

      true ->
        to_block = min(confirmed_head, from_block + ctx.max_blocks - 1)
        fetch_and_apply(cursor, chain, address, from_block, to_block, ctx)
    end
  end

  defp fetch_and_apply(%ChainSyncCursor{} = cursor, chain, address, from_block, to_block, ctx) do
    request = %{
      method: "eth_getLogs",
      params: [
        %{
          "address" => ctx.asset_address,
          "fromBlock" => to_hex_quantity(from_block),
          "toBlock" => to_hex_quantity(to_block),
          "topics" => [
            @transfer_topic,
            address_topic_filters(address)
          ]
        }
      ]
    }

    case ctx.rpc_fn.(request) do
      {:ok, logs} when is_list(logs) ->
        apply_logs(cursor, chain, address, logs, to_block, ctx)

      {:ok, _other} ->
        record_error(cursor, "invalid_response")
        {:error, :invalid_response}

      {:error, label} when is_binary(label) ->
        record_error(cursor, label)
        {:error, :rpc_unavailable}
    end
  end

  defp apply_logs(%ChainSyncCursor{} = cursor, chain, address, logs, to_block, ctx) do
    {inserted, duplicates} =
      Enum.reduce(logs, {0, 0}, fn log, {ins, dup} ->
        case normalize_log(log, cursor.workspace_id, chain, address, ctx) do
          {:ok, attrs} ->
            case Activity.create_imported_activity(attrs) do
              {:ok, :inserted, _} -> {ins + 1, dup}
              {:ok, :duplicate, _} -> {ins, dup + 1}
              {:error, _changeset} -> {ins, dup}
            end

          :skip ->
            {ins, dup}
        end
      end)

    advance_cursor(cursor, to_block)
    {:ok, %{inserted: inserted, duplicates: duplicates, last_block: to_block}}
  end

  defp normalize_log(log, workspace_id, chain, address, ctx) when is_map(log) do
    with %{"topics" => [_event, from_topic, to_topic]} <- log,
         %{"data" => data} when is_binary(data) <- log,
         %{"transactionHash" => tx_hash} when is_binary(tx_hash) <- log,
         %{"logIndex" => log_index} when is_binary(log_index) <- log,
         %{"blockNumber" => block_hex} when is_binary(block_hex) <- log do
      from_addr = topic_to_address(from_topic)
      to_addr = topic_to_address(to_topic)

      case direction_for(address, from_addr, to_addr) do
        :skip ->
          :skip

        direction ->
          amount = parse_token_amount(data, ctx.decimals)

          attrs = %{
            workspace_id: workspace_id,
            source_type: ctx.source_type,
            source_ref: tx_hash <> ":" <> log_index,
            source_hash: tx_hash,
            occurred_at: pseudo_occurred_at(block_hex, log_index),
            asset: ctx.asset,
            chain: chain,
            amount: amount,
            direction: direction,
            from_address: from_addr,
            to_address: to_addr,
            tx_hash: tx_hash,
            provenance: "chain_rpc",
            confidence: :high,
            metadata: %{}
          }

          {:ok, attrs}
      end
    else
      _ -> :skip
    end
  end

  defp normalize_log(_, _, _, _, _), do: :skip

  defp upsert_cursor(workspace_id, chain, source_type, address) do
    case Repo.one(
           from c in ChainSyncCursor,
             where:
               c.workspace_id == ^workspace_id and
                 c.chain == ^chain and
                 c.source_type == ^source_type and
                 c.address == ^address
         ) do
      %ChainSyncCursor{} = cursor ->
        cursor

      nil ->
        attrs = %{
          workspace_id: workspace_id,
          chain: chain,
          source_type: source_type,
          address: address
        }

        case Repo.insert(ChainSyncCursor.create_changeset(%ChainSyncCursor{}, attrs)) do
          {:ok, cursor} ->
            cursor

          {:error, _cs} ->
            # Race: another process inserted between the SELECT
            # and the INSERT. Re-fetch.
            Repo.one!(
              from c in ChainSyncCursor,
                where:
                  c.workspace_id == ^workspace_id and
                    c.chain == ^chain and
                    c.source_type == ^source_type and
                    c.address == ^address
            )
        end
    end
  end

  defp advance_cursor(%ChainSyncCursor{} = cursor, last_block) do
    cursor
    |> ChainSyncCursor.advance_changeset(%{
      last_block_number: last_block,
      last_synced_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp record_error(%ChainSyncCursor{} = cursor, label) when is_binary(label) do
    cursor
    |> ChainSyncCursor.record_error_changeset(%{
      last_error: sanitize_error_label(label),
      last_error_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  # Hard-allowlisted error labels. Anything outside the list
  # collapses to "rpc_error" so an unsanitized RPC reason cannot
  # leak into the cursor.
  @allowed_error_labels ~w(rpc_unavailable rpc_error_4xx rpc_error_5xx timeout invalid_response rpc_not_configured rpc_error)
  defp sanitize_error_label(label) when label in @allowed_error_labels, do: label
  defp sanitize_error_label(_), do: "rpc_error"

  defp parse_hex_quantity("0x" <> rest), do: String.to_integer(rest, 16)
  defp parse_hex_quantity(s) when is_binary(s), do: String.to_integer(s, 16)

  defp to_hex_quantity(0), do: "0x0"

  defp to_hex_quantity(n) when is_integer(n) and n > 0,
    do: ("0x" <> Integer.to_string(n, 16)) |> String.downcase()

  # ERC-20 `Transfer(address indexed from, address indexed to, uint256 value)`.
  # We watch any transfer where `address` appears as `from` OR `to`.
  # eth_getLogs supports an array-of-arrays for indexed filters: passing
  # `[address_topic, address_topic]` means topic1 ∈ {addr} OR topic2 ∈ {addr}.
  # But because some RPC providers reject the OR shape, we ask for any
  # transfer touching the asset address and filter direction client-side.
  # This means the RPC returns the same logs we would have asked for in
  # both windows; client-side filter keeps it correct.
  defp address_topic_filters(_address), do: nil

  defp direction_for(watched, watched, _to), do: :outbound
  defp direction_for(watched, _from, watched), do: :inbound
  defp direction_for(_, _, _), do: :skip

  # Topic-encoded address: 32-byte left-padded hex. Returns the
  # checksum-less lowercased 0x-prefixed 20-byte address.
  defp topic_to_address("0x" <> rest) when byte_size(rest) == 64 do
    ("0x" <> String.slice(rest, 24, 40)) |> String.downcase()
  end

  defp topic_to_address(_), do: nil

  defp parse_token_amount("0x" <> rest, decimals) do
    int = String.to_integer(rest, 16)
    Decimal.div(Decimal.new(int), Decimal.new(pow10(decimals)))
  end

  defp parse_token_amount(_, _), do: Decimal.new(0)

  defp pow10(0), do: 1
  defp pow10(n) when n > 0, do: Enum.reduce(1..n, 1, fn _, acc -> acc * 10 end)

  # Without a separate `eth_getBlockByNumber` lookup we use the
  # block number as a deterministic time anchor. Operators get
  # log_index for sub-block ordering through `source_ref`. A
  # follow-up can plug in real block timestamps via batched
  # `eth_getBlockByNumber` once the indexer source lands.
  defp pseudo_occurred_at(block_hex, _log_index) do
    block = parse_hex_quantity(block_hex)
    DateTime.from_unix!(block, :second)
  end
end
