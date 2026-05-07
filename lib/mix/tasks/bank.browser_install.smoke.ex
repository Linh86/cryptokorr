defmodule Mix.Tasks.Bank.BrowserInstall.Smoke do
  @shortdoc "Browser ZeroDev install smoke — preflight checklist (no signing, no broadcast)"

  @moduledoc """
  Reviewer preflight for the browser-signed ZeroDev session-permission
  install on Base Sepolia. Pairs with
  [`docs/runbooks/browser-signed-install-smoke.md`](../../docs/runbooks/browser-signed-install-smoke.md).

      mix bank.browser_install.smoke

  ## What it does

  - Reads the parent process environment via `System.get_env/0`. No
    `.env` sourcing.
  - Validates that the Phoenix endpoint is configured, that
    `Bank.SessionPermissions.BrowserInstall` has a `bundler_rpc_url`,
    that the configured chain id (or default 84532) is Base Sepolia,
    and that the operator has set the env vars a Path B reviewer
    needs (`OPERATOR_API_KEY`, `BANK_ENDPOINT`, `BASE_RPC_URL`,
    `BUNDLER_RPC_URL`).
  - Prints a redacted summary and the reviewer checklist mirroring
    the runbook's Path A steps.

  ## What it never does

  - Sign anything. The user EOA signs the install in the wallet
    (Path A) or `cast` / SDK (Path B). Phoenix never signs.
  - Broadcast anything. No bundler call, no chain RPC call.
  - Print any full secret. API keys are reduced to a `cb_***...`
    prefix; URLs that embed an API key are reported as
    `(configured)` only.
  - Source `.env`. Set env in your shell before invoking.

  Any `--confirm` / `--broadcast` style argument is **refused** with
  a clear error. Signing and broadcasting are the browser hook's
  job (Path A) or the reviewer's manual `cast` / dev-console SDK
  call (Path B). They are not a Mix task's job.

  ## Exit codes

  - `0` — every required env var is set and chain config resolves
    to Base Sepolia (84532).
  - non-zero — at least one required check failed; see stderr.
  """

  use Mix.Task

  @forbidden_args ~w(--confirm --broadcast --send --sign --execute)
  @base_sepolia_chain_id 84532

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case maybe_refuse_confirm(args) do
      :ok ->
        env = System.get_env()
        results = collect_checks(env)

        IO.puts(format_summary(results))
        IO.puts(format_checklist())
        IO.puts(closing_note())

        case Enum.filter(results, &(&1.status == :error)) do
          [] -> :ok
          _failures -> exit({:shutdown, 1})
        end

      {:refuse, refused} ->
        IO.puts(:stderr, refusal_message(refused))
        exit({:shutdown, 2})
    end
  end

  # --- arg handling ----------------------------------------------------

  defp maybe_refuse_confirm(args) do
    case Enum.find(args, fn arg -> arg in @forbidden_args end) do
      nil -> :ok
      refused -> {:refuse, refused}
    end
  end

  defp refusal_message(arg) do
    """
    bank.browser_install.smoke refused argument: #{arg}

    This task is preflight-only. It does not sign or broadcast
    anything. Signing the install UserOperation is the browser
    hook's job (Path A in docs/runbooks/browser-signed-install-smoke.md)
    or the reviewer's manual `cast` / SDK call (Path B). It is
    never a Mix task's job.

    To run the preflight checks, invoke without arguments:

        mix bank.browser_install.smoke
    """
  end

  # --- env / config checks ---------------------------------------------

  defp collect_checks(env) do
    [
      check_env_var(env, "BANK_ENDPOINT", &report_url/1),
      check_env_var(env, "OPERATOR_API_KEY", &report_api_key/1),
      check_env_var(env, "BASE_RPC_URL", &report_url/1),
      check_env_var(env, "BUNDLER_RPC_URL", &report_url/1),
      check_chain_id(env),
      check_bundler_app_config(),
      check_phoenix_endpoint_config()
    ]
  end

  defp check_env_var(env, key, redactor) do
    case Map.get(env, key) do
      nil ->
        %{
          key: key,
          status: :error,
          detail: "missing — set #{key} in your shell before running"
        }

      "" ->
        %{key: key, status: :error, detail: "empty"}

      value ->
        %{key: key, status: :ok, detail: redactor.(value)}
    end
  end

  defp check_chain_id(env) do
    raw = Map.get(env, "BASE_SEPOLIA_CHAIN_ID") || Map.get(env, "BASE_CHAIN_ID")

    case raw do
      nil ->
        %{
          key: "BASE_SEPOLIA_CHAIN_ID",
          status: :ok,
          detail: "#{@base_sepolia_chain_id} (default; not set)"
        }

      value ->
        case Integer.parse(value) do
          {@base_sepolia_chain_id, ""} ->
            %{
              key: "BASE_SEPOLIA_CHAIN_ID",
              status: :ok,
              detail: "#{@base_sepolia_chain_id}"
            }

          {other, ""} ->
            %{
              key: "BASE_SEPOLIA_CHAIN_ID",
              status: :error,
              detail:
                "got #{other}; this runbook is Base Sepolia only (#{@base_sepolia_chain_id})"
            }

          _ ->
            %{
              key: "BASE_SEPOLIA_CHAIN_ID",
              status: :error,
              detail: "not an integer: #{inspect(value)}"
            }
        end
    end
  end

  defp check_bundler_app_config do
    config = Application.get_env(:bank, Bank.SessionPermissions.BrowserInstall, [])

    case Keyword.get(config, :bundler_rpc_url) do
      nil ->
        %{
          key: ":bank, BrowserInstall :bundler_rpc_url",
          status: :error,
          detail:
            "Application config not set; configure :bank, Bank.SessionPermissions.BrowserInstall, bundler_rpc_url:"
        }

      "" ->
        %{
          key: ":bank, BrowserInstall :bundler_rpc_url",
          status: :error,
          detail: "Application config is empty"
        }

      _value ->
        %{
          key: ":bank, BrowserInstall :bundler_rpc_url",
          status: :ok,
          detail: "(configured)"
        }
    end
  end

  defp check_phoenix_endpoint_config do
    case Application.get_env(:bank, BankWeb.Endpoint) do
      nil ->
        %{
          key: ":bank, BankWeb.Endpoint",
          status: :error,
          detail: "Endpoint config missing"
        }

      _ ->
        %{
          key: ":bank, BankWeb.Endpoint",
          status: :ok,
          detail: "(configured)"
        }
    end
  end

  # --- redactors -------------------------------------------------------

  defp report_url(value) when is_binary(value) do
    cond do
      value =~ ~r/[?&](api[-_]?key|apikey)=/i ->
        "(configured; key in URL — treat as sensitive)"

      String.starts_with?(value, "http://") or String.starts_with?(value, "https://") ->
        value

      true ->
        "(configured)"
    end
  end

  defp report_api_key(value) when is_binary(value) do
    cond do
      String.starts_with?(value, "cb_") and String.length(value) >= 11 ->
        String.slice(value, 0, 11) <> "***"

      String.length(value) >= 8 ->
        String.slice(value, 0, 4) <> "***"

      true ->
        "***"
    end
  end

  # --- output formatting ----------------------------------------------

  defp format_summary(results) do
    [
      "Browser ZeroDev install smoke — preflight only",
      "  (this task does not sign, broadcast, or modify chain state)",
      ""
      | Enum.map(results, &format_result/1)
    ]
    |> Enum.join("\n")
  end

  defp format_result(%{key: key, status: :ok, detail: detail}) do
    "  #{pad(key)} #{detail}  ok"
  end

  defp format_result(%{key: key, status: :error, detail: detail}) do
    "  #{pad(key)} #{detail}  ERROR"
  end

  defp pad(key) do
    width = 38

    if String.length(key) >= width do
      key <> ":"
    else
      String.pad_trailing(key <> ":", width)
    end
  end

  defp format_checklist do
    """

    Reviewer checklist (mirrors docs/runbooks/browser-signed-install-smoke.md):
      1. Connect wallet on Base Sepolia (84532) at $BANK_ENDPOINT/.
      2. Sign the EIP-191 binding challenge (personal_sign).
      3. Click "Install session permission" and approve the
         EIP-712 install signature in your wallet (the user's EOA
         is the only signer; OPERATOR_PRIVATE_KEY is not involved).
      4. Wait for "Smart Account Delegation" to flip to Active
         (~10–30 s after the bundler receipt).
      5. Confirm the audit trail shows, in order, for the binding:
           delegation.install_envelope_issued
           delegation.install_signed_by_user
           delegation.install_broadcast
           delegation.install_confirmed_onchain

    Failure-mode contract:
      - Wrong chain → wrong_chain refusal in the LiveView; no audit row.
      - User rejection → install_failed reason: "user_rejected".
      - Bundler 5xx → install_failed reason: "bundler_unavailable".
      - Receipt revert → install_failed reason: "userop_reverted".
      - Hook timeout → install_failed reason: "attestation_timeout".
      - On-chain mismatch → install_failed last_reason:
        "install_failed:onchain_state_mismatch".
    """
  end

  defp closing_note do
    """
    No RPC calls were made.
    No bundler calls were made.
    No secret values were printed.
    No chain state was modified.
    """
  end
end
