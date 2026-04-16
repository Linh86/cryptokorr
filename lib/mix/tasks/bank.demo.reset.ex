defmodule Mix.Tasks.Bank.Demo.Reset do
  @shortdoc "Truncate the demo dataset and re-seed (dev/test/staging only)"

  @moduledoc """
  Destructively resets the demo dataset. Truncates every demo-owned
  table (counterparties, address_labels, policy_rules, delegations,
  agent_intents, decision_envelopes, execution_plans, audit_events,
  and their sidecars), then re-runs `Bank.Demo.seed/0`.

  ## Safety

    * Refuses to run in `:prod`. Only `:dev`, `:test`, and `:staging`
      are permitted.
    * Requires the `--confirm` flag. Without it the task prints the
      list of tables it would truncate and exits.

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
        DRY RUN — bank.demo.reset would truncate the following tables in #{env}:
          #{Enum.join(Bank.Demo.owned_tables(), "\n  ")}

        Pass --confirm to actually truncate and re-seed.
        """)

      true ->
        case Bank.Demo.reset(env: env, confirm: true) do
          :ok ->
            IO.puts("OK — demo dataset reset and re-seeded in #{env}")

          {:error, reason} ->
            Mix.raise("bank.demo.reset failed: #{inspect(reason)}")
        end
    end
  end
end
