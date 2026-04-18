defmodule Mix.Tasks.Bank.Smoke.Revoke do
  @shortdoc "Run the Base delegation revoke smoke check against a live adapter"

  @moduledoc """
  Dispatches a delegation revoke to the adapter for the given smart
  account and waits for the delegation row to transition to `:revoked`.
  Fails if the transition doesn't arrive inside the timeout.

  ## Required env

    * `ADAPTER_BASE_URL` / `ADAPTER_DISPATCH_SECRET` /
      `ADAPTER_CALLBACK_SECRET` — adapter connection (dispatch outbound,
      callback inbound)
    * `SMART_ACCOUNT_ID` — smart account with an active delegation

  ## Optional env

    * `REVOKE_REASON` — default `"smoke_test"`
    * `SMOKE_TIMEOUT_MS` — default `180000`

  ## Pass/fail

  Exits 0 on `{:ok, delegation}`, 1 otherwise. Prints the delegation id
  and final state in both cases.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    opts = [
      smart_account_id: env!("SMART_ACCOUNT_ID"),
      reason: env("REVOKE_REASON", "smoke_test"),
      timeout_ms: env("SMOKE_TIMEOUT_MS", "180000") |> String.to_integer()
    ]

    case Bank.Smoke.run_revoke(opts) do
      {:ok, delegation} ->
        IO.puts("""
        PASS — revoke smoke
          smart_account_id : #{delegation.smart_account_id}
          delegation_id    : #{delegation.delegation_id}
          state            : #{delegation.state}
          last_tx_hash     : #{delegation.last_tx_hash}
        """)

        :ok

      {:error, reason} ->
        IO.puts(:stderr, """
        FAIL — revoke smoke
          reason : #{inspect(reason)}
        """)

        exit({:shutdown, 1})
    end
  end

  defp env!(name) do
    case System.get_env(name) do
      nil -> Mix.raise("#{name} is required (see `mix help bank.smoke.revoke`)")
      "" -> Mix.raise("#{name} is required (see `mix help bank.smoke.revoke`)")
      value -> value
    end
  end

  defp env(name, default), do: System.get_env(name, default)
end
