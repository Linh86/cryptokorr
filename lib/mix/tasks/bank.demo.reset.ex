defmodule Mix.Tasks.Bank.Demo.Reset do
  @shortdoc "Scoped-delete the sandbox demo dataset and re-seed (dev/test/staging only)"

  @moduledoc """
  Resets the sandbox demo dataset by issuing targeted `DELETE`s
  against the rows `Bank.Demo.seed/0` produces — matched by
  `[Sandbox]` counterparty names, `sandbox-demo-*` agent ids, the
  `sa_demo_01` smart account, and the exact demo policy-rule specs.
  Non-demo rows in the same tables are preserved.

  `audit_events` is append-only at the DB layer and is not touched
  by the reset; old demo audit rows are left as orphans and the
  next seed writes fresh audit rows for the new intent uuids.

  ## Safety

    * Refuses to run in `:prod`. Only `:dev`, `:test`, and `:staging`
      are permitted.
    * Requires the `--confirm` flag. Without it the task prints the
      list of tables it would touch and exits.

  ## Example

      mix bank.demo.reset --confirm
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [confirm: :boolean])
    confirm? = Keyword.get(opts, :confirm, false)
    env = Mix.env()

    cond do
      env not in [:dev, :test, :staging] ->
        Mix.raise(
          "bank.demo.reset is not allowed in #{inspect(env)}; safe envs are dev/test/staging"
        )

      not confirm? ->
        IO.puts("""
        DRY RUN — bank.demo.reset would delete demo-tagged rows in #{env}
        from the following tables (audit_events is append-only and is left intact):
          #{Enum.join(Bank.Demo.owned_tables() -- ["audit_events"], "\n  ")}

        Pass --confirm to actually delete demo rows and re-seed.
        """)

      true ->
        case Bank.Demo.reset(env: env, confirm: true) do
          :ok ->
            IO.puts("OK — sandbox demo dataset reset and re-seeded in #{env}")

          {:error, reason} ->
            Mix.raise("bank.demo.reset failed: #{inspect(reason)}")
        end
    end
  end
end
