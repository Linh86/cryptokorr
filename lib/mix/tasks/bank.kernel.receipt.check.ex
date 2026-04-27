defmodule Mix.Tasks.Bank.Kernel.Receipt.Check do
  @moduledoc """
  DEFERRED — validate a Kernel v3 provisioning receipt.

      mix bank.kernel.receipt.check /path/to/receipt.json

  An earlier version of this task validated a deployment receipt
  whose shape (`permission_validator_address`,
  `validator_bytecode_keccak256`, etc.) was tied to a wrong-model
  assumption. ZeroDev's `@zerodev/permissions` does not produce
  such a single-validator receipt — see
  `docs/zerodev-permissions-integration.md` for the corrected model.

  Until the corrected receipt shape is decided alongside the
  ZeroDev SDK integration, this task surfaces the deferral and
  exits non-zero so an operator does not believe a malformed
  receipt is valid.

  IO + JSON-decode errors still fire before the deferral so the
  operator gets a sensible message when the file is missing or
  malformed.
  """

  use Mix.Task

  alias Bank.Delegations.Provisioning

  @shortdoc "Deferred — receipt format pending ZeroDev SDK integration"

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
      {:error, {:read_failed, reason}} ->
        Mix.raise("Could not read receipt file #{path}: #{reason}")

      {:error, {:decode_failed, reason}} ->
        Mix.raise("Receipt file #{path} is not valid JSON: #{Exception.message(reason)}")

      {:error, problems} ->
        print_problems(problems)
        Mix.raise("Receipt validation is deferred — see docs/zerodev-permissions-integration.md")
    end
  end

  defp print_problems(problems) do
    Mix.shell().info("Kernel provisioning receipt — deferred:")

    Enum.each(problems, fn problem ->
      Mix.shell().info("  - #{problem.key} [#{problem.severity}]: #{problem.detail}")
    end)
  end
end
