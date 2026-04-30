defmodule Mix.Tasks.Bank.WorkspaceBackfill do
  @shortdoc "Backfill workspace_id on legacy NULL rows (#158d-d)"

  @moduledoc """
  Idempotent, cursor-batched backfill of `workspace_id` on rows that
  pre-date workspace scoping (#158a–c). Wraps
  `Bank.Workspaces.Backfill`.

  Default behaviour is **dry-run** — the task counts what would
  change but writes nothing. Pass `--apply` to commit.

  ## Tables backfilled

  In dependency order:

    1. `execution_plans` — derived from `agent_intents.workspace_id`
       via `intent_id`.
    2. `delegations` — derived from the latest
       `execution_plans.workspace_id` for the same
       `smart_account_id`.
    3. `audit_events` — derived per-`subject_type` from the parent
       row's `workspace_id` (with one extra hop through
       `agent_intents` for `trust_assessment`, `simulation_report`,
       `decision_envelope`).

  Anchor tables (`agent_intents`, `counterparties`, `policy_rules`)
  are intentionally untouched — they have no FK chain to derive a
  workspace_id from. A future pass that picks a default workspace
  per installation can fill those.

  ## Options

    * `--apply` — actually write. Without it, dry-run.
    * `--batch-size N` (default 1000) — rows fetched/updated per
      page; each batch is its own transaction.
    * `--limit N` — cap total rows scanned across all batches.
    * `--table TABLE` — limit to one table. Otherwise all in scope
      run in dependency order.

  ## Examples

      # Dry-run all tables
      mix bank.workspace_backfill

      # Apply with a smaller batch size
      mix bank.workspace_backfill --apply --batch-size 200

      # Just delegations, capped at 100 rows
      mix bank.workspace_backfill --apply --table delegations --limit 100

  Re-running after data has been filled is safe — only NULL rows
  are touched, and a row whose parent is still NULL is left alone
  (counted under `skip_reasons`).
  """

  use Mix.Task

  alias Bank.Workspaces.Backfill

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          apply: :boolean,
          batch_size: :integer,
          limit: :integer,
          table: :string
        ]
      )

    apply? = Keyword.get(opts, :apply, false)
    batch_size = Keyword.get(opts, :batch_size, 1000)
    limit = Keyword.get(opts, :limit)
    table_filter = Keyword.get(opts, :table)

    tables = filter_tables(Backfill.tables(), table_filter)

    IO.puts(banner(apply?, tables, batch_size, limit))

    Enum.each(tables, fn table ->
      {:ok, stats} =
        Backfill.run(table,
          apply?: apply?,
          batch_size: batch_size,
          limit: limit
        )

      IO.puts(format_stats(stats))
    end)

    if not apply? do
      IO.puts("\nDry-run only. Re-run with --apply to commit.")
    end
  end

  defp filter_tables(all, nil), do: all

  defp filter_tables(all, name) do
    case Enum.find(all, &(Atom.to_string(&1) == name)) do
      nil ->
        Mix.raise(
          "Unknown --table #{inspect(name)}. Known: #{Enum.map_join(all, ", ", &Atom.to_string/1)}"
        )

      atom ->
        [atom]
    end
  end

  defp banner(apply?, tables, batch_size, limit) do
    """
    Bank.Workspaces.Backfill #{if apply?, do: "(APPLY)", else: "(dry-run)"}
      tables     : #{Enum.map_join(tables, ", ", &Atom.to_string/1)}
      batch_size : #{batch_size}
      limit      : #{limit || "no cap"}
    """
  end

  defp format_stats(%{table: :audit_events} = s) do
    """

    audit_events
      scanned : #{s.scanned}
      updated : #{s.updated}
      skipped : #{s.skipped}
    #{format_subject_breakdown(s.by_subject_type)}#{format_skip_reasons(s.skip_reasons)}\
    """
  end

  defp format_stats(s) do
    """

    #{s.table}
      scanned : #{s.scanned}
      updated : #{s.updated}
      skipped : #{s.skipped}
    #{format_skip_reasons(s.skip_reasons)}\
    """
  end

  defp format_subject_breakdown(map) when map_size(map) == 0, do: ""

  defp format_subject_breakdown(map) do
    rows =
      map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("\n", fn {st, %{scanned: sc, updated: up, skipped: sk}} ->
        "    - #{String.pad_trailing(st, 20)} scanned=#{sc} updated=#{up} skipped=#{sk}"
      end)

    "  by_subject_type:\n#{rows}\n"
  end

  defp format_skip_reasons(map) when map_size(map) == 0, do: ""

  defp format_skip_reasons(map) do
    rows =
      map
      |> Enum.sort_by(fn {k, _} -> Atom.to_string(k) end)
      |> Enum.map_join("\n", fn {reason, n} ->
        "    - #{String.pad_trailing(Atom.to_string(reason), 24)} #{n}"
      end)

    "  skip_reasons:\n#{rows}\n"
  end
end
