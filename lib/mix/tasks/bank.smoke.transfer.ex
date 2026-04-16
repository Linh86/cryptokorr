defmodule Mix.Tasks.Bank.Smoke.Transfer do
  @shortdoc "Run the Base transfer smoke check against a live adapter"

  @moduledoc """
  Drives a tiny transfer intent all the way to `execution.confirmed`
  against the currently configured adapter. Fails if the plan doesn't
  reach a confirmed status inside the timeout.

  ## Required env

    * `ADAPTER_BASE_URL` — where Phoenix dispatches to
    * `ADAPTER_AUTH_SECRET` — matches the adapter's expected bearer
    * `SMART_ACCOUNT_ID` — funded smart account the adapter signs for
    * `DELEGATION_ID` — active delegation the adapter knows about
    * `TARGET_ADDRESS` — counterparty address to send to

  ## Optional env

    * `CHAIN` — default `"base"`
    * `ASSET` — default `"USDC"`
    * `AMOUNT` — decimal string, default `"1"` (minimum USDC)
    * `SMOKE_TIMEOUT_MS` — default `180000`

  ## Pass/fail

  Exits 0 on `{:ok, plan}`, 1 otherwise. Prints the plan id and final
  status in both cases so a deploy script can pick up either outcome.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    opts = [
      smart_account_id: env!("SMART_ACCOUNT_ID"),
      delegation_id: env!("DELEGATION_ID"),
      target_address: env!("TARGET_ADDRESS"),
      chain: env("CHAIN", "base"),
      asset: env("ASSET", "USDC"),
      amount: env("AMOUNT", "1"),
      timeout_ms: env("SMOKE_TIMEOUT_MS", "180000") |> String.to_integer()
    ]

    case Bank.Smoke.run_transfer(opts) do
      {:ok, plan} ->
        IO.puts("""
        PASS — transfer smoke
          plan_id           : #{plan.id}
          execution_status  : #{plan.execution_status}
          final_outcome     : #{plan.final_outcome}
          tx_refs           : #{inspect(plan.tx_refs)}
        """)

        :ok

      {:error, reason} ->
        IO.puts(:stderr, """
        FAIL — transfer smoke
          reason : #{inspect(reason)}
        """)

        exit({:shutdown, 1})
    end
  end

  defp env!(name) do
    case System.get_env(name) do
      nil -> Mix.raise("#{name} is required (see `mix help bank.smoke.transfer`)")
      "" -> Mix.raise("#{name} is required (see `mix help bank.smoke.transfer`)")
      value -> value
    end
  end

  defp env(name, default), do: System.get_env(name, default)
end
