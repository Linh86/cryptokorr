defmodule Mix.Tasks.Bank.Morpho.DepositSmoke do
  @shortdoc "Run the explicit-confirmation Base Sepolia Morpho deposit smoke (#209) — broadcasts only with --confirm"

  @moduledoc """
  Explicit-confirmation Base Sepolia Morpho deposit smoke (#209).

  This is the LIVE counterpart to `mix bank.morpho.smoke` (which is
  read-only, in-process, never broadcasts). With `--confirm` this
  task drives the full #206 dispatch path against a real chain
  adapter and broadcasts an ERC-4337 UserOperation that performs an
  ERC-4626 USDC deposit into the workspace's allowlisted Morpho
  vault on Base Sepolia.

  Without `--confirm` the task prints the pre-flight checklist and
  exits non-zero. This is the default to make accidental invocation
  safe — CI pipelines that run `mix bank.*` tasks for any reason
  cannot accidentally trigger a broadcast.

  ## Hard safety boundaries

    * **Base Sepolia only.** `chain: "base"` is rejected closed at
      three independent layers (`Bank.Intents.normalize/1` boundary
      gate from #203 P2, the Phoenix dispatch
      `Bank.Decisions.MorphoDispatchSafety` from #206, and the TS
      adapter's `isSupportedMorphoDepositChain`). Mainnet is
      post-MVP.
    * **USDC only.**
    * **Allowlisted vault only.** The runner refuses to dispatch
      against a vault not in the workspace's active Morpho
      `:allowed_vault` rules.
    * **No `.env` source.** Required Phoenix-side config
      (`Bank.AdapterClient :base_url` / `:dispatch_secret` /
      `:callback_secret`) is presence-checked by name, never
      printed.
    * **No withdraw / redeem path.** This task exposes only the
      deposit flow. Withdraw is operator-only and tracked under
      #207.
    * **No arbitrary calldata.** The dispatch envelope built by
      `Bank.AdapterClient.dispatch_morpho_deposit/2` carries no
      calldata field on the wire; the adapter builds ERC-4626
      `deposit(assets, receiver)` and bounded
      `IERC20.approve(vault, amount)` calldata itself from the
      vault address + amount + receiver.
    * **No Oban enqueue.** The dispatch worker runs synchronously
      inside the smoke so the operator sees the outcome inline.

  ## Pre-flight checklist (refused mode)

  Run without `--confirm` to see the exact checklist this task
  prints. Summary:

    1. `mix bank.demo.seed` to ensure the demo workspace exists.
    2. The demo workspace has a Morpho `:allowed_vault` policy
       rule for the target vault.
    3. The demo workspace has a fresh persisted vault snapshot for
       that vault (drives the same code path the operator UI
       uses).
    4. Phoenix-side `Bank.AdapterClient` config present
       (presence-only check; values never printed):
       `:base_url`, `:dispatch_secret`, `:callback_secret`.
    5. The TS chain_adapter is running, configured for Base
       Sepolia (chain_id 84_532), with `BASE_RPC_URL`,
       `BUNDLER_RPC_URL`, and a smart account funded with USDC.
       The runner cannot assert the adapter side — operator
       must verify before `--confirm`.

  ## Live-mode artifacts

  On success the task prints (no secrets):

  ```
  intent_id          : <uuid>
  decision_id        : <uuid>
  plan_id            : <uuid>
  execution_status   : :prepared | :signing | :broadcasting | :pending_confirmation | :confirmed
  tx_refs            : [<userop_hash>, <on-chain hash>, ...]
  chain              : base-sepolia
  asset              : USDC
  vault_address      : 0x...
  ```

  Capture `tx_refs` (especially the on-chain hash and block number
  the adapter callback writes) for the operator's deployment log.

  ## Failure modes

    * `:phoenix_env` — Bank.AdapterClient config is missing keys.
      Set the keys in `config/runtime.exs` (operator-supplied
      values) and re-run.
    * `:demo_workspace :not_seeded` — run `mix bank.demo.seed`.
    * `:vault_allowlist :no_rule` — add an `:allowed_vault` rule
      for the target vault to the demo workspace.
    * `:snapshot :missing` — ingest a vault snapshot via the
      operator path before running the smoke.
    * `:intent_submit` / `:evaluate` / `:approve` /
      `:request_manual_execution` — see the structured reason;
      these surface the same vocabulary the operator UI uses.
    * `:dispatch :adapter_unavailable` — the TS adapter is not
      reachable; check `Bank.AdapterClient :base_url` and that
      the adapter is running.
    * `:dispatch {:adapter_rejected, status, body}` — the adapter
      refused (chain mismatch, etc.); inspect the structured
      `body` for the safe failure reason.

  ## Examples

      # See the pre-flight checklist; no broadcast.
      mix bank.morpho.deposit_smoke

      # Live broadcast (operator consent rides on --confirm).
      mix bank.morpho.deposit_smoke --confirm
  """

  use Mix.Task

  alias Bank.DefiVenues.Morpho.DepositSmoke

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _invalid} =
      OptionParser.parse(argv, switches: [confirm: :boolean], aliases: [c: :confirm])

    confirm? = Keyword.get(opts, :confirm, false)

    case DepositSmoke.run(confirm: confirm?) do
      {:ok, report} ->
        print_report(report)
        :ok

      {:error, report} ->
        print_report(report)
        exit({:shutdown, 1})

      {:refused, report} ->
        print_report(report)
        exit({:shutdown, 1})
    end
  end

  defp print_report(%{mode: :refused} = report) do
    Mix.shell().info("Bank Morpho deposit smoke — REFUSED (no --confirm)")
    Mix.shell().info("")
    Mix.shell().info("This task broadcasts a real Base Sepolia ERC-4626 USDC deposit.")
    Mix.shell().info("Re-run with `--confirm` to proceed; review the checklist below first.")
    Mix.shell().info("")
    Mix.shell().info("Pre-flight checklist:")
    Mix.shell().info("")
    print_checks(report.checks)
    Mix.shell().info("")
    Mix.shell().info("Result: REFUSED (re-run with --confirm)")
  end

  defp print_report(%{mode: :live} = report) do
    label = label_for(report.status)
    Mix.shell().info("Bank Morpho deposit smoke — #{label}")
    Mix.shell().info("")
    print_checks(report.checks)
    Mix.shell().info("")
    Mix.shell().info("Artifacts:")
    print_artifacts(report.artifacts)
    Mix.shell().info("")

    case report do
      %{status: :pass} ->
        Mix.shell().info("Result: PASS")

      %{status: :fail, reason: reason} ->
        Mix.shell().info("Result: FAIL (#{reason})")
    end
  end

  defp print_checks(checks) do
    Enum.each(checks, fn check ->
      tag =
        case check.status do
          :pass -> "PASS"
          :fail -> "FAIL"
          :info -> "INFO"
        end

      Mix.shell().info("  [#{tag}] #{check.name} — #{check.detail}")
    end)
  end

  defp print_artifacts(artifacts) do
    Mix.shell().info("  intent_id        : #{format_field(artifacts.intent_id)}")
    Mix.shell().info("  decision_id      : #{format_field(artifacts.decision_id)}")
    Mix.shell().info("  plan_id          : #{format_field(artifacts.plan_id)}")
    Mix.shell().info("  execution_status : #{format_field(artifacts.execution_status)}")
    Mix.shell().info("  tx_refs          : #{format_tx_refs(artifacts.tx_refs)}")
    Mix.shell().info("  chain            : #{artifacts.chain}")
    Mix.shell().info("  asset            : #{artifacts.asset}")
    Mix.shell().info("  vault_address    : #{format_field(artifacts.vault_address)}")
  end

  defp format_field(nil), do: "(unset)"
  defp format_field(value), do: to_string(value)

  defp format_tx_refs([]), do: "(none)"
  defp format_tx_refs(refs) when is_list(refs), do: Enum.join(refs, ", ")

  defp label_for(:pass), do: "PASS"
  defp label_for(:fail), do: "FAIL"
  defp label_for(:refused), do: "REFUSED"
end
