defmodule Mix.Tasks.Bank.Kernel.Preflight do
  @moduledoc """
  Validate Kernel v3 provisioning inputs without touching chain state.

      mix bank.kernel.preflight
      mix bank.kernel.preflight --phase install
      mix bank.kernel.preflight --phase verify

  This task reads the current process environment, checks only presence
  and shape, and redacts private-key shaped values in all output. It
  never calls RPC, never signs, and never claims provisioning success.
  """

  use Mix.Task

  alias Bank.Delegations.Provisioning

  @shortdoc "Preflight Kernel v3 provisioning env without RPC or secrets output"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [phase: :string],
        aliases: [p: :phase]
      )

    if invalid != [] do
      Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end

    phase = Keyword.get(opts, :phase, "deploy")
    checked = Provisioning.preflight(System.get_env(), phase)

    print_preflight(checked)

    if checked.status == :blocked do
      Mix.raise("Kernel provisioning preflight blocked for phase=#{checked.phase}")
    end
  end

  defp print_preflight(checked) do
    Mix.shell().info("Kernel provisioning preflight")
    Mix.shell().info("  phase:    #{checked.phase}")
    Mix.shell().info("  chain_id: #{checked.chain_id}")
    Mix.shell().info("  mode:     #{checked.mode}")
    Mix.shell().info("  status:   #{checked.status}")

    case checked.problems do
      [] ->
        Mix.shell().info("  problems: none")

      problems ->
        Mix.shell().info("  problems:")

        Enum.each(problems, fn problem ->
          Mix.shell().info("    - #{problem.key} [#{problem.severity}]: #{problem.detail}")
        end)
    end

    Mix.shell().info("")
    Mix.shell().info("No RPC calls were made and no secret values were printed.")
  end
end
