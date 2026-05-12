defmodule Mix.Tasks.Bank.BrowserInstall.E2e do
  @shortdoc "Drive a real install through chain_adapter→Pimlico→Base Sepolia (no browser, no MetaMask)"

  @moduledoc """
  Canonical regression check for the browser-signed install
  pipeline (Path A). Wraps
  `chain_adapter/scripts/install-e2e-simulator.ts` so it can be
  invoked from `mix` and from CI without remembering the env
  incantation.

      mix bank.browser_install.e2e

  ## What it does

  Generates a **fresh test EOA per run**, builds the install
  UserOp via the same ZeroDev SDK call sequence the browser hook
  uses (`signerToEcdsaValidator` → `toPermissionValidator` →
  `createKernelAccount` with `index: BigInt(BROWSER_KERNEL_ACCOUNT_INDEX)` →
  `createKernelAccountClient` with `paymaster: true`), calls the
  running chain_adapter's `POST /install/sign_session_portion` for
  the session-validator signature, and submits the doubly-signed
  UserOp to Pimlico. Exits 0 once the bundler returns a receipt
  with on-chain confirmation.

  No MetaMask. No browser. No Phoenix proxy hop. The test EOA
  signs the sudo portion in-process; everything downstream is
  identical to what the browser hook drives in production.

  ## What it never does

  - Sign anything as the operator user. The test EOA is fresh per
    run; the smart account it derives is deterministic but
    distinct from the operator's.
  - Mutate Phoenix state. Phoenix is not involved; the simulator
    talks directly to chain_adapter's signing endpoint (same
    auth Phoenix uses).
  - Touch a real user's wallet, binding, or delegation.

  ## Prerequisites

  - `chain_adapter` running on `:4100` (typically
    `cd chain_adapter && npm run dev`).
  - Env sourced from `chain_adapter/.env` AND
    `BASE_SEPOLIA_BUNDLER_RPC` exported (a `BUNDLER_RPC_URL`
    fallback works through the same alias chain in the simulator).
  - `npx` + `tsx` installed in `chain_adapter/node_modules` (a
    normal `npm install` in `chain_adapter/` provides both).

  ## Exit codes

  - `0` — UserOp confirmed on chain. The whole Path A chain is
    alive: chain_adapter signing endpoint, Pimlico paymaster +
    bundler, chain RPC for `eth_call` simulation, ZeroDev SDK
    wiring, kernel collision check.
  - non-zero — the simulator's `[install-sim:<step>]` log marks
    the precise step that broke. The simulator output is
    forwarded to this task's stdout.

  ## When to run

  - After **any** change to:
    - `assets/js/hooks/install_zerodev_client.js`,
      `assets/js/hooks/install_envelope_client.js`,
      `assets/js/hooks/session_permission_install.js`
    - `chain_adapter/src/install/*`, `chain_adapter/src/app.ts`,
      `chain_adapter/src/contracts/schemas.ts`
    - `lib/bank/session_permissions/browser_install.ex`,
      `lib/bank/chains/kernel_verifier.ex`,
      `lib/bank_web/controllers/wallet_bindings_install_controller.ex`,
      `lib/bank/adapter_client.ex`
  - On every CI run that touches the above.
  - As the **first** debugging step when an operator reports
    "install hangs" — distinguishes browser-only regressions
    (simulator passes) from pipeline regressions (simulator fails
    at the same step).
  """

  use Mix.Task

  @adapter_health_url "http://localhost:4100/health"
  @simulator_script "scripts/install-e2e-simulator.ts"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    with :ok <- check_simulator_present(),
         :ok <- check_adapter_reachable(),
         :ok <- run_simulator() do
      IO.puts(IO.ANSI.green() <> "✓ browser install E2E pipeline OK" <> IO.ANSI.reset())
      :ok
    else
      {:error, :simulator_missing, path} ->
        Mix.shell().error(
          "[mix bank.browser_install.e2e] cannot find #{path}; expected the simulator at " <>
            "chain_adapter/#{@simulator_script} (run from project root)"
        )

        exit({:shutdown, 2})

      {:error, :adapter_down} ->
        Mix.shell().error(
          "[mix bank.browser_install.e2e] chain_adapter is not reachable at " <>
            "#{@adapter_health_url}. Start it with `cd chain_adapter && npm run dev` and retry."
        )

        exit({:shutdown, 3})

      {:error, :simulator_failed, code, output} ->
        # The simulator already printed structured `[install-sim:<step>]`
        # logs on its way down; forward them verbatim so the operator can
        # see exactly where the chain broke.
        IO.write(output)

        Mix.shell().error(
          "[mix bank.browser_install.e2e] simulator exited with code #{code}; " <>
            "look for the last `[install-sim:<step>] FAILED` line above"
        )

        exit({:shutdown, code})
    end
  end

  defp check_simulator_present do
    path = Path.join(["chain_adapter", @simulator_script])
    if File.exists?(path), do: :ok, else: {:error, :simulator_missing, path}
  end

  defp check_adapter_reachable do
    # Pure-OTP TCP probe so we don't need `Req`/Finch started — the
    # task only runs `Mix.Task.run("app.config")` which loads but
    # doesn't start the app. A successful TCP connect to :4100 is
    # all we need; the simulator itself drives the real HTTP call
    # if this passes.
    case :gen_tcp.connect(~c"127.0.0.1", 4100, [:binary, active: false], 1_000) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} ->
        {:error, :adapter_down}
    end
  end

  defp run_simulator do
    # Run npx tsx in the chain_adapter dir so node_modules resolves.
    # The simulator reads its env from process env; whatever the
    # operator sourced before invoking mix is what it sees.
    #
    # We use `cmd_lines: false, into: ""` semantics via `cd:` +
    # explicit `:stderr_to_stdout` so the operator sees the
    # `[install-sim:<step>]` log lines that go to stderr alongside
    # the simulator's stdout in real time.
    {output, exit_code} =
      System.cmd(
        "npx",
        ["tsx", @simulator_script],
        cd: "chain_adapter",
        stderr_to_stdout: true
      )

    if exit_code == 0 do
      IO.write(output)
      :ok
    else
      {:error, :simulator_failed, exit_code, output}
    end
  end
end
