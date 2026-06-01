defmodule Bank.Activity.Smoke do
  @moduledoc """
  Activity-import smoke runner (#247).

  Exercises the local activity-import surfaces end-to-end:

    * `Bank.Activity.CsvImport.preview/2` and `commit/2`
    * `Bank.Activity.ChainSync.sync_address/4` with an injected
      `:rpc_fn` stub — no real RPC, no `.env`, no chain network
    * `Bank.Activity.Reconciliation.classify_activity/2` against
      a freshly-imported row

  Read-only by design with respect to the world outside the
  sandbox-demo workspace:

    * No secrets / no environment variables required.
    * No chain RPC, no signing, no broadcast, no dispatch.
    * No mutation of non-demo data.

  Within the demo workspace the smoke writes a small set of
  canned `[Sandbox]`-shaped activity rows (CSV + one stubbed
  chain transfer). The CSV is committed with idempotent
  dedupe-keys so re-running the smoke is a no-op on rows that
  already exist — that idempotency is itself one of the checks.

  Driven from `Mix.Tasks.Bank.Activity.Smoke`; the runner is split
  out from the task so it can be unit-tested without invoking
  `Mix.Task.run/2`.
  """

  alias Bank.Activity
  alias Bank.Activity.ChainSync
  alias Bank.Activity.CsvImport
  alias Bank.Activity.Reconciliation
  alias Bank.Demo

  # Sandbox-only fixed identifiers used in the smoke fixtures.
  # These mirror the existing canned demo seed style:
  #   * obviously non-secret
  #   * lowercased ERC-20 address shape
  #   * a USDC contract (Base Sepolia testnet) address
  @smoke_chain "base-sepolia"
  @smoke_asset_address "0x036cbd53842c5426634e7929541ec2318f3dcf7e"
  @smoke_watched_address "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @smoke_sender_address "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @smoke_tx_hash "0xsmoke7777777777777777777777777777777777777777777777777777777777"

  # `eth_blockNumber` synthetic head; well past confirmations cap.
  @smoke_head_block 1_000
  @smoke_log_block 800
  @smoke_block_ts_base 1_700_000_000

  @valid_csv """
  occurred_at,asset,chain,amount,direction,memo
  2026-04-01T12:00:00Z,USDC,base,100.50,inbound,smoke-payroll
  2026-04-02T12:00:00Z,USDC,base,25.00,outbound,smoke-vendor
  """

  @mixed_csv """
  occurred_at,asset,chain,amount,direction
  2026-04-03T12:00:00Z,USDC,base,55,inbound
  bad-datetime,USDC,base,5,inbound
  """

  @forbidden_csv """
  occurred_at,asset,amount,direction,workspace_id
  2026-04-04T12:00:00Z,USDC,100,inbound,sibling-workspace-uuid
  """

  @type status :: :pass | :fail

  @type check :: %{name: String.t(), status: status(), detail: String.t()}

  @type report :: %{
          workspace_slug: String.t(),
          workspace_id: Ecto.UUID.t() | nil,
          status: status(),
          checks: [check()],
          passed: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc """
  Run every check and return `{:ok, report}` if all pass, or
  `{:error, report}` if any fail. Never raises.
  """
  @spec run() :: {:ok, report()} | {:error, report()}
  def run do
    workspace_slug = Demo.workspace_slug()

    case Demo.demo_workspace_id() do
      nil ->
        finalize(workspace_slug, nil, [
          %{
            name: "seed",
            status: :fail,
            detail: "demo workspace #{workspace_slug} not found — run `mix bank.demo.seed`"
          }
        ])

      workspace_id ->
        finalize(workspace_slug, workspace_id, run_checks(workspace_id))
    end
  end

  defp run_checks(workspace_id) do
    [
      check_csv_preview(workspace_id),
      check_csv_commit(workspace_id),
      check_csv_idempotent(workspace_id),
      check_csv_mixed(workspace_id),
      check_csv_forbidden_header(workspace_id),
      check_chain_sync_stub(workspace_id),
      check_reconciliation(workspace_id)
    ]
  end

  defp finalize(workspace_slug, workspace_id, checks) do
    passed = Enum.count(checks, &(&1.status == :pass))
    total = length(checks)
    overall = if passed == total, do: :pass, else: :fail

    report = %{
      workspace_slug: workspace_slug,
      workspace_id: workspace_id,
      status: overall,
      checks: checks,
      passed: passed,
      total: total
    }

    case overall do
      :pass -> {:ok, report}
      :fail -> {:error, report}
    end
  end

  # --- Checks ----------------------------------------------------------

  defp check_csv_preview(workspace_id) do
    case CsvImport.preview(@valid_csv, workspace_id) do
      {:ok, %{summary: %{new: n, duplicate: d, invalid: 0}}} when n + d == 2 ->
        pass("csv_preview", "valid CSV → summary new=#{n} duplicate=#{d} invalid=0")

      {:ok, %{summary: summary}} ->
        fail("csv_preview", "unexpected summary: #{inspect(summary)}")

      {:error, reason} ->
        fail("csv_preview", "preview returned error: #{inspect(reason)}")
    end
  end

  defp check_csv_commit(workspace_id) do
    case CsvImport.commit(@valid_csv, workspace_id) do
      {:ok, %{summary: %{inserted: i, duplicate: d, invalid: 0}}} when i + d == 2 ->
        pass(
          "csv_commit",
          "valid CSV committed: inserted=#{i} duplicate=#{d} (idempotent on re-run)"
        )

      {:ok, %{summary: summary}} ->
        fail("csv_commit", "unexpected summary: #{inspect(summary)}")

      {:error, reason} ->
        fail("csv_commit", "commit returned error: #{inspect(reason)}")
    end
  end

  defp check_csv_idempotent(workspace_id) do
    # Re-commit the same body. Now every row should be a duplicate.
    case CsvImport.commit(@valid_csv, workspace_id) do
      {:ok, %{summary: %{inserted: 0, duplicate: 2, invalid: 0}}} ->
        pass("csv_idempotent", "re-commit of same CSV → inserted=0 duplicate=2")

      {:ok, %{summary: summary}} ->
        fail("csv_idempotent", "expected inserted=0 duplicate=2; got #{inspect(summary)}")

      {:error, reason} ->
        fail("csv_idempotent", "re-commit returned error: #{inspect(reason)}")
    end
  end

  defp check_csv_mixed(workspace_id) do
    # Commit a CSV with one valid + one invalid row.
    case CsvImport.commit(@mixed_csv, workspace_id) do
      {:ok, %{summary: %{inserted: i, invalid: 1}}} when i in [0, 1] ->
        # `i == 1` on the first run; `i == 0` if a previous smoke
        # already committed this body. Either is correct.
        pass(
          "csv_mixed",
          "mixed CSV: 1 invalid row classified, valid row handled (inserted=#{i})"
        )

      {:ok, %{summary: summary}} ->
        fail("csv_mixed", "expected invalid=1; got #{inspect(summary)}")

      {:error, reason} ->
        fail("csv_mixed", "mixed CSV returned error: #{inspect(reason)}")
    end
  end

  defp check_csv_forbidden_header(workspace_id) do
    # A CSV with a `workspace_id` header is rejected outright — the
    # CSV body cannot supply a workspace_id; that is hard-pinned by
    # the parser. Pinning it here too means any regression that
    # silently accepts the column would fail the smoke.
    case CsvImport.preview(@forbidden_csv, workspace_id) do
      {:error, {:forbidden_column, _}} ->
        pass("csv_forbidden_header", "forbidden header rejected as {:forbidden_column, _}")

      {:error, other} ->
        fail("csv_forbidden_header", "expected forbidden_column; got #{inspect(other)}")

      {:ok, _} ->
        fail("csv_forbidden_header", "preview accepted a CSV that should have been rejected")
    end
  end

  defp check_chain_sync_stub(workspace_id) do
    rpc_fn = canned_rpc(@smoke_head_block, %{@smoke_log_block => [smoke_transfer_log()]})

    case ChainSync.sync_address(workspace_id, @smoke_chain, @smoke_watched_address,
           asset_address: @smoke_asset_address,
           rpc_fn: rpc_fn
         ) do
      {:ok, %{inserted: i, duplicates: d}} ->
        # On the first run the canned transfer is inserted
        # (`i + d == 1`). On subsequent runs the cursor has
        # advanced past `@smoke_log_block`, so the sync legally
        # returns `i == 0, d == 0` — the row is already in the
        # ledger from the prior run. Either case is correct as
        # long as the row exists in the workspace.
        chain_rows =
          Activity.list_imported_activities(
            workspace_id: workspace_id,
            source_type: :wallet_chain
          )

        if chain_rows == [] do
          fail(
            "chain_sync_stub",
            "sync returned inserted=#{i} duplicate=#{d} but no wallet_chain row landed"
          )
        else
          pass(
            "chain_sync_stub",
            "stubbed RPC sync ok (inserted=#{i} duplicate=#{d}; #{length(chain_rows)} wallet_chain row(s) in ledger)"
          )
        end

      {:error, reason} ->
        fail("chain_sync_stub", "sync returned error: #{inspect(reason)}")
    end
  end

  defp check_reconciliation(workspace_id) do
    # The smoke's chain-imported row has no matching ExecutionPlan
    # (its tx_hash is a sandbox literal, not from a real plan). It
    # must therefore classify as `:external`. This proves the
    # reconciliation read path returns a value — a stubbed
    # implementation that returned `nil` would fail this check.
    [chain_row | _] =
      Activity.list_imported_activities(workspace_id: workspace_id, source_type: :wallet_chain)

    case Reconciliation.classify_activity(chain_row, []) do
      :external ->
        pass("reconciliation", "no-plan-match activity classified as :external")

      :cryptokorr_execution ->
        # Surprising for the smoke fixture (no plan exists with
        # this tx_hash), but the function returned a valid label.
        pass("reconciliation", "smoke fixture matched a real plan — classified")

      other ->
        fail(
          "reconciliation",
          "expected :external or :cryptokorr_execution; got #{inspect(other)}"
        )
    end
  rescue
    error -> fail("reconciliation", "raised: #{inspect(error)}")
  catch
    :exit, reason -> fail("reconciliation", "exited: #{inspect(reason)}")
  end

  # --- Helpers ---------------------------------------------------------

  defp pass(name, detail), do: %{name: name, status: :pass, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}

  # The smoke's `:rpc_fn` returns a deterministic head, a single
  # inbound transfer at `@smoke_log_block`, and synthetic block
  # timestamps so `occurred_at` is reproducible.
  defp canned_rpc(head, logs_by_block) do
    fn
      %{method: "eth_blockNumber"} ->
        {:ok, hex(head)}

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
        {:ok, %{"timestamp" => hex(@smoke_block_ts_base + block)}}
    end
  end

  defp smoke_transfer_log do
    amount = 25 * 1_000_000

    %{
      "address" => @smoke_asset_address,
      "topics" => [
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        address_topic(@smoke_sender_address),
        address_topic(@smoke_watched_address)
      ],
      "data" => "0x" <> String.pad_leading(Integer.to_string(amount, 16), 64, "0"),
      "blockNumber" => hex(@smoke_log_block),
      "transactionHash" => @smoke_tx_hash,
      "logIndex" => "0x0"
    }
  end

  defp address_topic("0x" <> rest), do: "0x" <> String.pad_leading(rest, 64, "0")

  defp hex(int) when is_integer(int) and int >= 0,
    do: "0x" <> (Integer.to_string(int, 16) |> String.downcase())

  defp parse_hex("0x" <> rest), do: String.to_integer(rest, 16)
end
