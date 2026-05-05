defmodule Mix.Tasks.Bank.Notifications.Smoke do
  @shortdoc "Run the notifications smoke (#237) — read-mostly, no chain RPC, no real external delivery"

  @moduledoc """
  Notifications smoke (#237).

  Verifies the local notifications surface (#233 inbox + #234
  emitters + #236 preferences and delivery state) against the
  seeded sandbox-demo workspace and prints a concise per-check
  pass/fail report.

  Read-mostly with respect to the world outside `sandbox-demo`:

    * No `.env`, no `ADAPTER_*`, no `RPC_*` environment reads.
    * No `Bank.AdapterClient` calls.
    * No real SMTP / webhook / Telegram delivery — every
      channel routes to `Bank.Notifications.Channel.Stub`.
    * No Oban jobs enqueued. No chain network. No HTTP outside
      the BEAM process.

  Within the demo workspace the smoke writes inbox rows
  (`notifications`) and delivery rows (`notification_deliveries`)
  for the seeded `partner-x-pending-approval` and
  `treasury-held` intents. Re-runs are idempotent: the inbox
  row's `(workspace_id, dedupe_key)` unique constraint and the
  delivery row's `(notification_id, channel)` unique constraint
  collapse repeats; the `attempt_delivery/2` terminal-state
  guard from #236 P2 keeps a re-run from regressing a
  delivered row.

  Exits 0 on PASS and 1 on FAIL so a CI step can pick up the
  outcome without parsing stdout.

  ## Example

      # Seed the demo dataset first if you haven't:
      mix bank.demo.seed
      mix bank.notifications.smoke
  """

  use Mix.Task

  alias Bank.Notifications.Smoke

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
    Mix.shell().info("Bank notifications smoke")
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

    Mix.shell().info("No chain RPC, no secrets, no real external delivery.")
  end

  defp result_label(:pass), do: "PASS"
  defp result_label(:fail), do: "FAIL"
end
