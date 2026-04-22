defmodule Mix.Tasks.Bank.Kernel.Receipt.Check do
  @moduledoc """
  Validate a Kernel v3 provisioning verification receipt file.

      mix bank.kernel.receipt.check /path/to/receipt.json

  The receipt is the no-secret handoff from #84 to #83. This task reads
  a local JSON file, validates that it contains the deployment fields
  required by `Bank.Delegations.Provisioning.validate_receipt/1`, and
  prints the normalized #83 handoff. It never calls RPC and never reads
  private keys.
  """

  use Mix.Task

  alias Bank.Delegations.Provisioning

  @shortdoc "Validate Kernel provisioning receipt JSON for the #84 -> #83 handoff"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case args do
      [path] ->
        check(path)

      _ ->
        Mix.raise("Usage: mix bank.kernel.receipt.check /path/to/receipt.json")
    end
  end

  defp check(path) do
    case Provisioning.validate_receipt_file(path) do
      {:ok, handoff} ->
        Mix.shell().info("Kernel provisioning receipt is valid")
        Mix.shell().info("  chain_id: #{handoff.chain_id}")
        Mix.shell().info("  smart_account_address: #{handoff.smart_account_address}")

        Mix.shell().info(
          "  permission_validator_address: #{handoff.permission_validator_address}"
        )

        Mix.shell().info("  kernel_factory_address: #{handoff.kernel_factory_address}")
        Mix.shell().info("  deployed_bytecode_keccak256: #{handoff.deployed_bytecode_keccak256}")
        Mix.shell().info("  artifact_source_hint: #{handoff.artifact_source_hint}")
        Mix.shell().info("  chain_explorer_url: #{handoff.chain_explorer_url}")
        Mix.shell().info("  next_issue: #{handoff.next_issue}")
        Mix.shell().info("")
        Mix.shell().info("No RPC calls were made and no secret values were read.")

      {:error, {:read_failed, reason}} ->
        Mix.raise("Could not read receipt file #{path}: #{reason}")

      {:error, {:decode_failed, reason}} ->
        Mix.raise("Receipt file #{path} is not valid JSON: #{Exception.message(reason)}")

      {:error, problems} ->
        print_problems(problems)
        Mix.raise("Kernel provisioning receipt is incomplete or malformed")
    end
  end

  defp print_problems(problems) do
    Mix.shell().info("Kernel provisioning receipt problems:")

    Enum.each(problems, fn problem ->
      Mix.shell().info("  - #{problem.key} [#{problem.severity}]: #{problem.detail}")
    end)
  end
end
