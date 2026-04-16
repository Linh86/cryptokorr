defmodule Mix.Tasks.Bank.Demo.Seed do
  @shortdoc "Seed the demo dataset into the current environment"

  @moduledoc """
  Idempotently populates the curated demo dataset: counterparties,
  address labels, policy rules, a delegation, and four representative
  intents (completed auto-exec, approved after review, blocked
  unknown-recipient, in-flight executing).

  Safe to run repeatedly; records are keyed so a second run is a no-op.

  ## Example

      mix bank.demo.seed

  See `docs/demo.md` for the full walkthrough.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    :ok = Bank.Demo.seed()

    IO.puts("""
    OK — demo dataset seeded
      counterparties : Payroll Provider, Treasury Ops, New Partner X, Unverified Recipient
      intents        : 4 (payroll-confirmed, partner-x-approved, unknown-blocked, treasury-executing)
      smart account  : sa_demo_01
      delegation     : del_demo_01 (active, base)
    """)
  end
end
