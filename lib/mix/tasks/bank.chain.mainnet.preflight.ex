defmodule Mix.Tasks.Bank.Chain.Mainnet.Preflight do
  @shortdoc "Run the read-only Base mainnet preflight (#179)"

  @moduledoc """
  Read-only Base mainnet preflight (#179).

  Wraps `Bank.Chains.MainnetPreflight.run/1` with a CLI-friendly
  PASS / FAIL line per check. Companion to `mix bank.kernel.preflight`
  (which validates env shape) and `mix bank.observability.smoke`
  (which validates the runtime observability surface).

  ## What it verifies

    * config presence — `BASE_RPC_URL`, `BUNDLER_RPC_URL`,
      `BASE_CHAIN_ID`, `SMART_ACCOUNT_ADDRESS` are non-empty;
    * declared chain id == 8453 (Base mainnet);
    * RPC `eth_chainId` round-trips and matches 8453;
    * `eth_getCode` at the canonical ERC-4337 v0.7 EntryPoint
      returns non-empty bytecode;
    * `SMART_ACCOUNT_ADDRESS` is a valid 20-byte 0x address;
    * `eth_getCode` at the smart account (informational —
      `:degraded` if the kernel is not yet deployed, not a hard
      fail because that's a separate provisioning step);
    * `eth_getBalance` at the smart account round-trips (we
      don't gate on amount; funding is the operator's job);
    * `BUNDLER_RPC_URL` is an http(s) URL.

  ## What it does NOT do

  Mirrors the safety posture of `mix bank.observability.smoke`:

    * No broadcast. No signing. No UserOp. No bundler RPC.
    * No `Bank.AdapterClient` dispatch.
    * No write-side runtime mutation.

  Every error detail is drawn from a fixed allowlist
  (`config_missing:<key>`, `chain_id_declared_mismatch`,
  `chain_id_rpc_mismatch`, `entrypoint_missing`,
  `transport_error`, `http_5xx`, `invalid_response`, …) — no
  raw URL, exception message, or RPC body is ever printed.

  ## Usage

      mix bank.chain.mainnet.preflight
      # → prints one line per check, exits non-zero on any :down /
      #   :unknown status.

  Opts:

    * `--quiet` — suppress per-check PASS lines; only print
      failures and the trailing summary.

  ## Exit codes

    * `0` — every check is `:ok` or `:not_configured` (a
      deliberately-absent dependency on local/dev is benign).
    * non-zero (`Mix.raise`) — at least one check is `:degraded`,
      `:down`, or `:unknown`.

  ## Example output

      [bank.chain.mainnet.preflight] running 8 checks
      [bank.chain.mainnet.preflight] PASS config_present
      [bank.chain.mainnet.preflight] PASS chain_id_declared
      [bank.chain.mainnet.preflight] PASS smart_account_address_shape
      [bank.chain.mainnet.preflight] PASS bundler_url_shape
      [bank.chain.mainnet.preflight] PASS chain_id_rpc
      [bank.chain.mainnet.preflight] PASS entrypoint_code
      [bank.chain.mainnet.preflight] PASS smart_account_code
      [bank.chain.mainnet.preflight] PASS smart_account_balance
      [bank.chain.mainnet.preflight] 8 / 8 PASS

  See also: `Bank.Chains.MainnetPreflight` moduledoc,
  `docs/runbooks/production-observability.md` § Base mainnet
  feature gate.
  """

  use Mix.Task

  @requirements ["app.start"]

  @check_order [
    :config_present,
    :chain_id_declared,
    :smart_account_address_shape,
    :bundler_url_shape,
    :chain_id_rpc,
    :entrypoint_code,
    :smart_account_code,
    :smart_account_balance
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: [quiet: :boolean])

    quiet? = Keyword.get(opts, :quiet, false)

    log("running #{length(@check_order)} checks", quiet?)

    %{checks: checks, status: status} = Bank.Chains.MainnetPreflight.run()

    Enum.each(@check_order, fn name ->
      result = Map.fetch!(checks, name)

      case result.status do
        s when s in [:ok, :not_configured] ->
          log("PASS #{name}#{detail_suffix(result)}", quiet?)

        :degraded ->
          IO.puts("[bank.chain.mainnet.preflight] WARN #{name} — #{result.detail || "no detail"}")

        bad when bad in [:down, :unknown] ->
          IO.puts("[bank.chain.mainnet.preflight] FAIL #{name} — #{result.detail || "no detail"}")
      end
    end)

    pass_count =
      checks
      |> Map.values()
      |> Enum.count(&(&1.status in [:ok, :not_configured]))

    total = map_size(checks)

    summary = "[bank.chain.mainnet.preflight] #{pass_count} / #{total} PASS"
    IO.puts(summary)

    if status in [:down, :degraded] do
      Mix.raise(
        "bank.chain.mainnet.preflight FAILED (overall status: #{status}; " <>
          "#{total - pass_count} of #{total} checks did not pass)"
      )
    end

    :ok
  end

  defp detail_suffix(%{detail: nil}), do: ""
  defp detail_suffix(%{detail: detail}), do: " (#{detail})"

  defp log(_msg, true), do: :ok
  defp log(msg, _), do: IO.puts("[bank.chain.mainnet.preflight] #{msg}")
end
