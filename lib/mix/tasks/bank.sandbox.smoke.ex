defmodule Mix.Tasks.Bank.Sandbox.Smoke do
  @shortdoc "Run the Level 1 sandbox smoke (#240) — read-only, no chain, no secrets"

  @moduledoc """
  Automated Level 1 sandbox smoke (#240).

  Verifies the local no-chain product flow against the seeded
  sandbox demo dataset and prints a concise pass/fail report.

  Read-only by construction: no `.env`, no chain RPC, no signing,
  no broadcast, no dispatch. The database is the only external
  dependency. See `Bank.Sandbox.Smoke` for the check list.

  Exits 0 on PASS and 1 on FAIL so CI scripts can pick up either
  outcome without parsing stdout.

  ## Example

      # Seed the demo dataset first if you haven't:
      mix bank.demo.seed
      mix bank.sandbox.smoke
  """

  use Mix.Task

  alias Bank.Sandbox.Smoke

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
    Mix.shell().info("Bank L1 sandbox smoke")
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

    Mix.shell().info("No chain RPC, no secrets, no broadcast.")
  end

  defp result_label(:pass), do: "PASS"
  defp result_label(:fail), do: "FAIL"
end
