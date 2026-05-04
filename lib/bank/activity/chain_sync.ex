defmodule Bank.Activity.ChainSync do
  @moduledoc """
  Read-only wallet/smart-account chain activity sync (#245).

  Two source-types share this module:

    * `:wallet_chain` — pulls USDC `Transfer` events for a watched
      EOA via JSON-RPC and normalizes them into the
      `Bank.Activity` imported-activity ledger.

    * `:smart_account_chain` — imports smart-account on-chain
      activity (delegation grants/revokes, executed plans) from
      this Phoenix instance's adapter-callback projections
      (`Bank.Delegations.Delegation` and
      `Bank.Decisions.ExecutionPlan`) into the same ledger. No
      RPC call is made; the durable callback stream is the
      authoritative source until the smart-account contract event
      ABI lands in this repo (see "Smart-account events" below).

  Both paths are **strictly read-only**: this module never
  broadcasts a transaction, signs a payload, calls
  `Bank.AdapterClient`, creates an `ExecutionPlan`, or enqueues an
  Oban dispatch job. The only write surface is
  `Bank.Activity.create_imported_activity/1` plus the cursor row
  on this module's own table.

  ## Workspace boundary

  Every read/write is scoped by `workspace_id`. The cursor table
  is workspace-keyed (`chain_sync_cursors_uniq` on
  `(workspace_id, chain, source_type, address)`). Activity rows
  carry `workspace_id` per the existing
  `Bank.Activity.ImportedActivity` contract. The smart-account
  path queries `delegations` and `execution_plans` with explicit
  `workspace_id` filters so rows from other tenants cannot leak.

  ## Wallet-chain initial sync window (#245 P2)

  A fresh cursor (`last_block_number == 0` and `last_synced_at ==
  nil`) is seeded from a recent-confirmed-range heuristic instead
  of genesis: `from_block = max(confirmed_head - max_blocks + 1,
  0)`. Callers can override with the `:start_block` opt for a
  known deployment block. After the first run, the cursor advances
  normally and the recent-window heuristic is not re-applied.

  ## Conservative reorg handling (wallet-chain)

  After the initial seeding, every subsequent sync window is
  `[cursor.last_block_number + 1 - @reorg_rewind_blocks,
  head_block - @confirmations]`. The rewind overlap re-fetches the
  last few blocks each time so a chain reorg that rewrote them is
  observed as new events from the source — but the activity
  ledger's deterministic dedupe (per
  `Bank.Activity.compute_dedupe_key/1` on `(source_type,
  source_ref, occurred_at, asset, direction, amount)`) collapses
  the duplicates idempotently.

  ## Block timestamps (wallet-chain, #245 P2)

  Each unique block touched by the imported logs is resolved via
  `eth_getBlockByNumber` exactly once per sync call. The real
  block timestamp is used for `occurred_at`. If the timestamp
  fetch fails, the run is treated as a source failure: the cursor
  records the sanitized error label and `last_block_number` is
  NOT advanced, so the next attempt retries the same window.

  ## Smart-account events

  The TS chain adapter is the authoritative producer of
  smart-account state transitions today: it watches the on-chain
  Kernel/ZeroDev contract, decodes the relevant events
  (delegation install/uninstall, executed user-operation), and
  posts a normalized callback to
  `POST /internal/adapter/callback`. Phoenix persists the result
  on `Bank.Delegations.Delegation` and
  `Bank.Decisions.ExecutionPlan` rows that carry the on-chain
  anchor (`install_tx_hash`, `last_tx_hash`, `tx_refs`, `chain`,
  outcome timestamps).

  This module reads those rows by
  `(workspace_id, chain, smart_account_id)` and projects them as
  imported-activity ledger rows with a fixed `provenance:
  "smart_account_callback"` and a deterministic `source_ref` so a
  re-run is idempotent. We do not parse arbitrary on-chain logs —
  only the hard-allowlisted projection fields documented below
  reach the ledger. When the smart-account contract ABI / event
  topic constants land in this repo a future iteration can swap
  the read-side from "callback projection" to "decoded event
  log" behind the same `:smart_account_chain` source type.

  ## Source failures

  Any wallet-chain RPC failure (transport, malformed hex, 4xx,
  5xx, timeout) is captured as a fixed-shape sanitized label
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
  drive every wallet-chain branch deterministically without
  hitting the network. The smart-account path doesn't use the
  RPC source at all (the adapter has already done the chain
  read), so `:rpc_fn` is ignored for `source_type:
  :smart_account_chain`.
  """

  import Ecto.Query

  alias Bank.Activity
  alias Bank.Activity.ChainSyncCursor
  alias Bank.Activity.ChainSync.RpcSource
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Delegations.Delegation
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

  # Fixed provenance string for smart-account callback-backed
  # imports. Searchable by operators / reconcilers.
  @smart_account_provenance "smart_account_callback"

  # Hard-allowlisted "kind" labels we project from the callback
  # state into ledger metadata. Anything outside this list is
  # ignored — preserves the read-only-projection invariant.
  @allowed_delegation_kinds ~w(delegation.granted delegation.revoked delegation.revoke_failed)
  @allowed_execution_kinds ~w(execution.confirmed execution.reverted execution.aborted)

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
  Sync chain activity for `address` on `chain` into the workspace's
  imported-activity ledger.

  ## Args

    * `workspace_id` — required binary UUID; refuses nil to avoid
      cross-workspace writes.
    * `chain` — string chain id (Phase 1 supports `"base-sepolia"`
      only).
    * `address` — for `:wallet_chain`, a 0x-prefixed 20-byte hex
      address (lowercased server-side). For
      `:smart_account_chain`, the adapter's free-form
      `smart_account_id` (used as-is for the
      `delegations` / `execution_plans` join).
    * `opts`:
        * `:source_type` (default `:wallet_chain`) — must be one of
          `Bank.Activity.ChainSyncCursor.source_types/0`.
        * `:rpc_fn` — wallet-chain test injection (see moduledoc).
          Ignored for `:smart_account_chain`.
        * `:max_blocks` — wallet-chain only; cap on the
          `[from, to]` window per call. Default 1_000. Hard-capped
          at 5_000.
        * `:asset_address` — wallet-chain only; ERC-20 contract
          address of the asset watched (USDC). Required for
          `:wallet_chain`.
        * `:asset` — wallet-chain ledger-side asset symbol
          (default `"USDC"`).
        * `:asset_decimals` — wallet-chain token decimals
          (default `6`).
        * `:start_block` — wallet-chain only; non-negative
          integer; explicit initial block for a fresh cursor.
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
    case Keyword.get(opts, :source_type, :wallet_chain) do
      :wallet_chain ->
        sync_wallet_chain(workspace_id, chain, address, opts)

      :smart_account_chain ->
        sync_smart_account_chain(workspace_id, chain, address, opts)

      _ ->
        {:error, :invalid_source_type}
    end
  end

  defp sync_wallet_chain(workspace_id, chain, address, opts) do
    asset_address = Keyword.get(opts, :asset_address)

    if not is_binary(asset_address) or asset_address == "" do
      {:error, :missing_asset_address}
    else
      rpc_fn = Keyword.get(opts, :rpc_fn, &RpcSource.call/1)
      max_blocks = opts |> Keyword.get(:max_blocks, 1_000) |> min(5_000) |> max(1)
      asset = Keyword.get(opts, :asset, "USDC")
      decimals = Keyword.get(opts, :asset_decimals, 6)
      start_block = sanitize_start_block(Keyword.get(opts, :start_block))
      lowered_address = String.downcase(address)

      do_sync_wallet(workspace_id, chain, lowered_address, %{
        source_type: :wallet_chain,
        rpc_fn: rpc_fn,
        max_blocks: max_blocks,
        asset: asset,
        decimals: decimals,
        asset_address: String.downcase(asset_address),
        start_block: start_block
      })
    end
  end

  # Smart-account path: callback-backed projection. Reads the
  # `delegations` + `execution_plans` rows the adapter callback
  # has already populated for this workspace + smart account, and
  # writes one ledger row per terminal/anchored state transition.
  # No RPC, no signing, no broadcast — just a workspace-scoped
  # `SELECT ... INSERT ... ON CONFLICT (dedupe_key) DO NOTHING`
  # via the existing `Bank.Activity.create_imported_activity/1`.
  defp sync_smart_account_chain(workspace_id, chain, smart_account_id, _opts) do
    cursor = upsert_cursor(workspace_id, chain, :smart_account_chain, smart_account_id)

    delegation_attrs =
      workspace_id
      |> fetch_delegations(chain, smart_account_id)
      |> Enum.flat_map(&delegation_to_attrs(&1, workspace_id, chain, smart_account_id))

    execution_attrs =
      workspace_id
      |> fetch_execution_plans(chain, smart_account_id)
      |> Enum.flat_map(&execution_to_attrs(&1, workspace_id, chain, smart_account_id))

    {inserted, duplicates} =
      Enum.reduce(delegation_attrs ++ execution_attrs, {0, 0}, fn attrs, {ins, dup} ->
        case Activity.create_imported_activity(attrs) do
          {:ok, :inserted, _} -> {ins + 1, dup}
          {:ok, :duplicate, _} -> {ins, dup + 1}
          {:error, _changeset} -> {ins, dup}
        end
      end)

    advance_cursor(cursor, cursor.last_block_number)

    {:ok,
     %{
       inserted: inserted,
       duplicates: duplicates,
       last_block: cursor.last_block_number
     }}
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
    if source_type in ChainSyncCursor.source_types() do
      Repo.one(
        from c in ChainSyncCursor,
          where:
            c.workspace_id == ^workspace_id and
              c.chain == ^chain and
              c.source_type == ^source_type and
              c.address == ^cursor_address(source_type, address)
      )
    else
      nil
    end
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

  # --- wallet-chain internals -------------------------------------------

  defp do_sync_wallet(workspace_id, chain, address, %{source_type: source_type} = ctx) do
    cursor = upsert_cursor(workspace_id, chain, source_type, address)

    case ctx.rpc_fn.(%{method: "eth_blockNumber", params: []}) do
      {:ok, head_hex} when is_binary(head_hex) ->
        case safe_parse_hex_quantity(head_hex) do
          {:ok, head} ->
            run_window(cursor, head, chain, address, ctx)

          :error ->
            # Malformed eth_blockNumber response (non-hex, empty,
            # missing 0x prefix) — sanitized "invalid_response"
            # rather than letting `String.to_integer/2` raise.
            record_error(cursor, "invalid_response")
            {:error, :invalid_response}
        end

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
    from_block = compute_from_block(cursor, confirmed_head, ctx)

    cond do
      confirmed_head < from_block ->
        # Nothing settled to sync yet. Treat as a no-op success;
        # advance the cursor to `from_block - 1` so a fresh cursor
        # records its initial position (and is no longer "fresh"
        # next call). Clears any prior error envelope.
        effective_last = max(from_block - 1, cursor.last_block_number)
        advance_cursor(cursor, effective_last)
        {:ok, %{inserted: 0, duplicates: 0, last_block: effective_last}}

      true ->
        to_block = min(confirmed_head, from_block + ctx.max_blocks - 1)
        fetch_and_apply(cursor, chain, address, from_block, to_block, ctx)
    end
  end

  # Fresh cursor: seed from configured `:start_block` or recent
  # confirmed range. Avoids the "first run pulls from genesis"
  # trap on a high-head chain.
  defp compute_from_block(
         %ChainSyncCursor{last_block_number: 0, last_synced_at: nil},
         confirmed_head,
         ctx
       ) do
    case ctx.start_block do
      n when is_integer(n) and n >= 0 -> n
      _ -> max(confirmed_head - ctx.max_blocks + 1, 0)
    end
  end

  defp compute_from_block(%ChainSyncCursor{} = cursor, _confirmed_head, _ctx) do
    max(cursor.last_block_number + 1 - @reorg_rewind_blocks, 0)
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
    case fetch_block_timestamps(logs, ctx) do
      {:ok, ts_by_block} ->
        {inserted, duplicates} =
          Enum.reduce(logs, {0, 0}, fn log, {ins, dup} ->
            case normalize_log(log, cursor.workspace_id, chain, address, ctx, ts_by_block) do
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

      {:error, label} ->
        record_error(cursor, label)
        {:error, :rpc_unavailable}
    end
  end

  # Per-call cache of block timestamps. Multiple logs in the same
  # block share one `eth_getBlockByNumber` lookup. A failure halts
  # the whole run as a source failure — we never persist a synthetic
  # 1970-era timestamp.
  defp fetch_block_timestamps(logs, ctx) do
    block_hexes =
      logs
      |> Enum.flat_map(fn
        %{"blockNumber" => b} when is_binary(b) -> [b]
        _ -> []
      end)
      |> Enum.uniq()

    Enum.reduce_while(block_hexes, {:ok, %{}}, fn block_hex, {:ok, acc} ->
      case ctx.rpc_fn.(%{method: "eth_getBlockByNumber", params: [block_hex, false]}) do
        {:ok, %{"timestamp" => ts_hex}} when is_binary(ts_hex) ->
          with {:ok, ts} <- safe_parse_hex_quantity(ts_hex),
               {:ok, dt} <- DateTime.from_unix(ts, :second) do
            {:cont, {:ok, Map.put(acc, block_hex, dt)}}
          else
            _ -> {:halt, {:error, "invalid_response"}}
          end

        {:ok, _other} ->
          {:halt, {:error, "invalid_response"}}

        {:error, label} when is_binary(label) ->
          {:halt, {:error, label}}
      end
    end)
  end

  defp normalize_log(log, workspace_id, chain, address, ctx, ts_by_block) when is_map(log) do
    with %{"topics" => [_event, from_topic, to_topic]} <- log,
         %{"data" => data} when is_binary(data) <- log,
         %{"transactionHash" => tx_hash} when is_binary(tx_hash) <- log,
         %{"logIndex" => log_index} when is_binary(log_index) <- log,
         %{"blockNumber" => block_hex} when is_binary(block_hex) <- log,
         %DateTime{} = occurred_at <- Map.get(ts_by_block, block_hex) do
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
            occurred_at: occurred_at,
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

  defp normalize_log(_, _, _, _, _, _), do: :skip

  # --- smart-account internals ------------------------------------------

  defp fetch_delegations(workspace_id, chain, smart_account_id) do
    Repo.all(
      from d in Delegation,
        where:
          d.workspace_id == ^workspace_id and
            d.chain == ^chain and
            d.smart_account_id == ^smart_account_id
    )
  end

  defp fetch_execution_plans(workspace_id, chain, smart_account_id) do
    Repo.all(
      from p in ExecutionPlan,
        where:
          p.workspace_id == ^workspace_id and
            p.chain == ^chain and
            p.smart_account_id == ^smart_account_id and
            fragment("array_length(?, 1) > 0", p.tx_refs)
    )
  end

  # Project a delegation row into 0..N ledger attrs. Grant and
  # revoke are emitted independently — the row is a mutable
  # projection that retains `install_tx_hash` / `granted_at` after
  # revocation, so a first-sync that lands after a delegation has
  # already been revoked still imports the original on-chain
  # grant. A revoked row with both anchors emits exactly two
  # activity attrs (one inbound grant, one outbound revoke). Each
  # attr is keyed by a kind-specific `source_ref` so dedupe
  # collapses idempotently across re-runs.
  defp delegation_to_attrs(%Delegation{} = d, workspace_id, chain, smart_account_id) do
    grant_attrs(d, workspace_id, chain, smart_account_id) ++
      revoke_attrs(d, workspace_id, chain, smart_account_id)
  end

  defp grant_attrs(%Delegation{} = d, workspace_id, chain, smart_account_id) do
    if is_binary(d.install_tx_hash) and not is_nil(d.granted_at) and
         "delegation.granted" in @allowed_delegation_kinds do
      [
        build_smart_account_attrs(
          workspace_id: workspace_id,
          chain: chain,
          smart_account_id: smart_account_id,
          source_ref:
            "delegation:" <>
              safe_string(d.delegation_id) <> ":granted:" <> d.install_tx_hash,
          tx_hash: d.install_tx_hash,
          occurred_at: d.granted_at,
          direction: :inbound,
          kind: "delegation.granted",
          extra_metadata: %{
            "delegation_id" => safe_string(d.delegation_id),
            "kernel_version" => d.kernel_version
          }
        )
      ]
    else
      []
    end
  end

  defp revoke_attrs(%Delegation{} = d, workspace_id, chain, smart_account_id) do
    if d.state in [:revoked, :revoke_failed] and is_binary(d.last_tx_hash) do
      kind = "delegation." <> Atom.to_string(d.state)

      if kind in @allowed_delegation_kinds do
        occurred_at = d.revoked_at || d.updated_at

        [
          build_smart_account_attrs(
            workspace_id: workspace_id,
            chain: chain,
            smart_account_id: smart_account_id,
            source_ref:
              "delegation:" <>
                safe_string(d.delegation_id) <>
                ":" <> Atom.to_string(d.state) <> ":" <> d.last_tx_hash,
            tx_hash: d.last_tx_hash,
            occurred_at: occurred_at,
            direction: :outbound,
            kind: kind,
            extra_metadata: %{
              "delegation_id" => safe_string(d.delegation_id),
              "last_reason" => sanitize_reason(d.last_reason)
            }
          )
        ]
      else
        []
      end
    else
      []
    end
  end

  # Project an execution plan into one ledger attr per `tx_ref`.
  # Only plans with a terminal `final_outcome` produce activity —
  # in-flight plans are not yet "happened on chain".
  defp execution_to_attrs(%ExecutionPlan{} = p, workspace_id, chain, smart_account_id) do
    if p.final_outcome in [:confirmed, :reverted, :aborted] and is_list(p.tx_refs) do
      kind = "execution." <> Atom.to_string(p.final_outcome)

      if kind in @allowed_execution_kinds do
        p.tx_refs
        |> Enum.with_index()
        |> Enum.flat_map(fn {tx_hash, idx} ->
          if is_binary(tx_hash) and tx_hash != "" do
            [
              build_smart_account_attrs(
                workspace_id: workspace_id,
                chain: chain,
                smart_account_id: smart_account_id,
                source_ref:
                  "execution:" <>
                    safe_string(p.id) <>
                    ":" <> Integer.to_string(idx) <> ":" <> tx_hash,
                tx_hash: tx_hash,
                occurred_at: p.updated_at,
                direction: :outbound,
                asset: p.asset || "USDC",
                kind: kind,
                extra_metadata: %{
                  "execution_plan_id" => safe_string(p.id),
                  "final_reason" => sanitize_reason(p.final_reason)
                }
              )
            ]
          else
            []
          end
        end)
      else
        []
      end
    else
      []
    end
  end

  defp build_smart_account_attrs(opts) do
    direction = Keyword.fetch!(opts, :direction)
    smart_account_id = Keyword.fetch!(opts, :smart_account_id)

    {from_address, to_address} =
      case direction do
        :inbound -> {nil, smart_account_id}
        :outbound -> {smart_account_id, nil}
      end

    base_metadata = %{
      "kind" => Keyword.fetch!(opts, :kind),
      "smart_account_id" => smart_account_id
    }

    metadata =
      opts
      |> Keyword.get(:extra_metadata, %{})
      |> Map.merge(base_metadata)

    %{
      workspace_id: Keyword.fetch!(opts, :workspace_id),
      source_type: :smart_account_chain,
      source_ref: Keyword.fetch!(opts, :source_ref),
      source_hash: Keyword.fetch!(opts, :tx_hash),
      occurred_at: Keyword.fetch!(opts, :occurred_at),
      asset: Keyword.get(opts, :asset, "delegation"),
      chain: Keyword.fetch!(opts, :chain),
      amount: Decimal.new(0),
      direction: direction,
      from_address: from_address,
      to_address: to_address,
      tx_hash: Keyword.fetch!(opts, :tx_hash),
      provenance: @smart_account_provenance,
      confidence: :high,
      metadata: metadata
    }
  end

  # --- shared cursor + helpers ------------------------------------------

  defp upsert_cursor(workspace_id, chain, source_type, address) do
    stored_address = cursor_address(source_type, address)

    case Repo.one(
           from c in ChainSyncCursor,
             where:
               c.workspace_id == ^workspace_id and
                 c.chain == ^chain and
                 c.source_type == ^source_type and
                 c.address == ^stored_address
         ) do
      %ChainSyncCursor{} = cursor ->
        cursor

      nil ->
        attrs = %{
          workspace_id: workspace_id,
          chain: chain,
          source_type: source_type,
          address: stored_address
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
                    c.address == ^stored_address
            )
        end
    end
  end

  # The wallet-chain path lowercases EOAs to keep cursors keyed
  # consistently. The smart-account path uses the adapter's
  # opaque `smart_account_id` verbatim — Phoenix never parses it.
  defp cursor_address(:wallet_chain, address) when is_binary(address),
    do: String.downcase(address)

  defp cursor_address(:smart_account_chain, address) when is_binary(address), do: address
  defp cursor_address(_, address) when is_binary(address), do: address

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

  defp sanitize_start_block(n) when is_integer(n) and n >= 0, do: n
  defp sanitize_start_block(_), do: nil

  # Free-text reason fields the adapter callback or operator can
  # write into (`Delegation.last_reason`,
  # `ExecutionPlan.final_reason`) are NOT a safe metadata source —
  # `Bank.Activity.redact_metadata/1` only redacts when the key
  # itself looks secret, so a value containing tokens / URLs /
  # PEM markers would land verbatim on `imported_activities`.
  # We therefore detect a small marker set (case-insensitive) and
  # collapse the whole value to a fixed `"[REDACTED]"` label
  # before persistence. Non-flagged text is bounded to a safe
  # length cap so a runaway free-text payload cannot bloat the
  # ledger row either.
  @reason_secret_markers [
    "bearer",
    "authorization",
    "sk_live_",
    "sk_test_",
    "begin private key",
    "private_key",
    "https://",
    "secret@"
  ]
  @reason_max_length 200
  defp sanitize_reason(nil), do: nil

  defp sanitize_reason(reason) when is_binary(reason) do
    lower = String.downcase(reason)

    if Enum.any?(@reason_secret_markers, &String.contains?(lower, &1)) do
      "[REDACTED]"
    else
      String.slice(reason, 0, @reason_max_length)
    end
  end

  defp sanitize_reason(_), do: nil

  # `String.to_integer/2` raises `ArgumentError` on empty / non-hex
  # input. Wrap it so a malformed RPC response (or fixture) becomes
  # a sanitized `:error` instead of crashing the sync process.
  defp safe_parse_hex_quantity("0x" <> rest), do: safe_parse_hex_quantity(rest)

  defp safe_parse_hex_quantity(s) when is_binary(s) and byte_size(s) > 0 do
    try do
      {:ok, String.to_integer(s, 16)}
    rescue
      ArgumentError -> :error
    end
  end

  defp safe_parse_hex_quantity(_), do: :error

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
    case safe_parse_hex_quantity(rest) do
      {:ok, int} -> Decimal.div(Decimal.new(int), Decimal.new(pow10(decimals)))
      :error -> Decimal.new(0)
    end
  end

  defp parse_token_amount(_, _), do: Decimal.new(0)

  defp pow10(0), do: 1
  defp pow10(n) when n > 0, do: Enum.reduce(1..n, 1, fn _, acc -> acc * 10 end)

  defp safe_string(nil), do: ""
  defp safe_string(s) when is_binary(s), do: s
  defp safe_string(other), do: to_string(other)
end
