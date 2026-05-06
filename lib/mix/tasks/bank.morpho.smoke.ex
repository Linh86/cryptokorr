defmodule Mix.Tasks.Bank.Morpho.Smoke do
  @shortdoc "Run the Morpho deposits smoke (#209) — read-only Morpho risk + decision pipeline + audit/replay; no chain RPC, no Morpho HTTP"

  @moduledoc """
  Morpho deposits smoke (#209).

  Verifies the local Morpho vault risk + ERC-4626 deposit
  decision surfaces against the seeded sandbox-demo workspace
  and prints a concise per-check pass/fail report.

  Read-mostly with respect to the world outside `sandbox-demo`:

    * No `.env`, no `ADAPTER_*`, no `RPC_*`, no `MORPHO_*`
      environment reads.
    * No `Bank.AdapterClient` calls.
    * No `Bank.DefiVenues.Morpho.Client` HTTP calls — every
      snapshot is built in-process and persisted via
      `Bank.DefiVenues.Morpho.Snapshots.persist/2`.
    * No Oban jobs enqueued. No chain network. No HTTP outside
      the BEAM process.

  Within the demo workspace the smoke writes Morpho intents,
  vault snapshots, decision envelopes, and audit rows. Re-runs
  are idempotent — see `Bank.DefiVenues.Morpho.Smoke` for the
  per-row idempotency contract.

  Exits 0 on PASS and 1 on FAIL so a CI step can pick up the
  outcome without parsing stdout.

  ## Example

      # Seed the demo dataset first if you haven't:
      mix bank.demo.seed
      mix bank.morpho.smoke
  """

  use Mix.Task

  alias Bank.DefiVenues.Morpho.Smoke

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    case Smoke.run() do
      {:ok, report} ->
        print_report(report)
        :ok

      {:error, report} ->
        print_report(report)
        exit({:shutdown, 1})
    end
  end

  defp print_report(report) do
    Mix.shell().info("Bank Morpho deposits smoke")
    Mix.shell().info("  workspace : #{report.workspace_slug}")

    case report.workspace_id do
      nil -> Mix.shell().info("  id        : (not seeded)")
      id -> Mix.shell().info("  id        : #{id}")
    end

    Mix.shell().info("")

    Enum.each(report.checks, fn check ->
      tag =
        case check.status do
          :pass -> "PASS"
          :fail -> "FAIL"
        end

      Mix.shell().info("  [#{tag}] #{check.name} — #{check.detail}")
    end)

    Mix.shell().info("")
    Mix.shell().info("Result: #{result_label(report.status)} (#{report.passed}/#{report.total})")
    Mix.shell().info("No chain RPC, no Morpho HTTP, no execution dispatch.")
  end

  defp result_label(:pass), do: "PASS"
  defp result_label(:fail), do: "FAIL"
end
