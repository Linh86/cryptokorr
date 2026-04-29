defmodule Mix.Tasks.Bank.Demo.Seed do
  @shortdoc "Seed the sandbox demo dataset into the current environment"

  @moduledoc """
  Idempotently populates the curated sandbox demo dataset:
  `[Sandbox]`-prefixed counterparties, address labels, policy rules,
  a `sa_demo_01` delegation, and nine representative intents covering
  every state the runtime produces — submitted, decided (auto_exec /
  approval_required / hold), executing, executed, blocked, cancelled.

  Safe to run repeatedly; records are keyed so a second run is a
  no-op. Until issue #155 ships the `workspaces` table, every seeded
  row is implicitly scoped to `Bank.Demo.workspace_slug/0`.

  ## Example

      mix bank.demo.seed

  See `docs/demo.md` for the full walkthrough.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    :ok = Bank.Demo.seed()
    ids = Bank.Demo.identifiers()

    IO.puts("""
    OK — sandbox demo dataset seeded
      workspace      : #{ids.workspace_slug} (placeholder until #155)
      counterparties : #{Enum.join(ids.counterparty_names, ", ")}
      intents        : 9 (submitted-fresh, decided-pending-exec, payroll-confirmed,
                         partner-x-pending-approval, partner-x-approved, treasury-held,
                         treasury-executing, unknown-blocked, cancelled-pre-decision)
      smart account  : #{ids.smart_account_id}
      delegation     : #{ids.delegation_id} (active, base)
    """)
  end
end
