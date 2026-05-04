defmodule Mix.Tasks.Bank.Activity.Smoke do
  @shortdoc "Run the activity-import smoke (#247) — read-only, no chain RPC, no secrets"

  @moduledoc """
  Activity-import smoke (#247).

  Verifies the local activity-import surfaces against the seeded
  sandbox demo workspace and prints a concise pass/fail report.

  Read-only with respect to the world outside `sandbox-demo`: no
  `.env`, no chain RPC (the chain-sync check uses an injected
  `:rpc_fn` stub), no signing, no broadcast, no dispatch, no
  external HTTP calls. The database is the only external
  dependency. See `Bank.Activity.Smoke` for the check list.

  Exits 0 on PASS and 1 on FAIL so a CI step can pick up the
  outcome without parsing stdout.

  ## Example

      # Seed the demo dataset first if you haven't:
      mix bank.demo.seed
      mix bank.activity.smoke
  """

  use Mix.Task

  alias Bank.Activity.Smoke

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
    Mix.shell().info("Bank activity-import smoke")
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
