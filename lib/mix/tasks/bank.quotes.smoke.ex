defmodule Mix.Tasks.Bank.Quotes.Smoke do
  @shortdoc "Run the quote provider smoke (#177) — deterministic stub preview + ProviderHealth + /v1/health/deep rollup; no live network"

  @moduledoc """
  Quote provider smoke command (#177).

  Drives every read-only quote/simulation surface a fresh reviewer
  needs to inspect locally and prints a per-check pass/fail report.
  Automated counterpart to `docs/runbooks/quote-provider-degraded-mode.md`.

  Read-mostly:

    * No `.env`, no `ADAPTER_*`, no `RPC_*`, no `TENDERLY_*`
      reads.
    * No `Bank.Quotes.LiveProvider` HTTP — the smoke only
      exercises the in-process `Bank.Quotes.StubProvider`.
    * No `simulation_reports` inserts.
    * No Oban jobs enqueued.
    * Idempotent — `Bank.Quotes.ProviderHealth` ETS state is
      restored after the run so the smoke does not bleed into a
      long-running deployment's readiness payload.

  Exits 0 on PASS and 1 on FAIL so a CI step can pick up the
  outcome without parsing stdout.

  ## Example

      mix bank.quotes.smoke
      # => 7 / 7 PASS

  See `Bank.Quotes.Smoke` for the exact contract each check pins.
  """

  use Mix.Task

  alias Bank.Quotes.Smoke

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
    Mix.shell().info("Bank quote provider smoke")
    Mix.shell().info("")

    Enum.each(report.checks, fn check ->
      tag =
        case check.status do
          :pass -> "PASS"
          :fail -> "FAIL"
        end

      Mix.shell().info("  #{tag} #{check.name} — #{check.detail}")
    end)

    Mix.shell().info("")
    Mix.shell().info("#{report.passed} / #{report.total} #{result_label(report.status)}")
    Mix.shell().info("No live network, no `.env` reads, no Tenderly HTTP.")
  end

  defp result_label(:pass), do: "PASS"
  defp result_label(:fail), do: "FAIL"
end
