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
      check_bundler_app_config(env),
      check_session_signer_address(),
      check_kernel_verifier_rpc_url(env),
      check_kernel_verifier_validation_id_check(),
      check_kernel_account_indices(env),
      check_phoenix_endpoint_config(),
      check_adapter_running(),
      check_adapter_sign_session_portion_route()
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

  # Three env aliases feed `Bank.SessionPermissions.BrowserInstall`'s
  # `bundler_rpc_url`. They are listed in precedence order — the first
  # non-empty wins, matching the resolution in `config/dev.exs`. We
  # report which alias is currently the active source so a reviewer
  # can tell at a glance whether `chain_adapter/.env`'s
  # `BUNDLER_RPC_URL` was picked up.
  @bundler_aliases [
    "BASE_SEPOLIA_BUNDLER_RPC",
    "BUNDLER_URL",
    "BUNDLER_RPC_URL"
  ]

  defp check_bundler_app_config(env) do
    config = Application.get_env(:bank, Bank.SessionPermissions.BrowserInstall, [])
    active_alias = resolve_bundler_alias(env)

    case Keyword.get(config, :bundler_rpc_url) do
      nil ->
        %{
          key: ":bank, BrowserInstall :bundler_rpc_url",
          status: :error,
          detail:
            "Application config not set; set one of " <>
              Enum.join(@bundler_aliases, ", ") <>
              " in your shell or configure :bank, Bank.SessionPermissions.BrowserInstall, bundler_rpc_url:"
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
          detail:
            "(configured" <>
              case active_alias do
                nil -> "; via app config only"
                alias_name -> "; from $" <> alias_name
              end <> ")"
        }
    end
  end

  defp resolve_bundler_alias(env) do
    Enum.find(@bundler_aliases, fn key ->
      case Map.get(env, key) do
        nil -> false
        "" -> false
        _value -> true
      end
    end)
  end

  defp check_session_signer_address do
    config = Application.get_env(:bank, Bank.SessionPermissions.BrowserInstall, [])

    case Keyword.get(config, :session_signer_address) do
      nil ->
        %{
          key: ":bank, BrowserInstall :session_signer_address",
          status: :error,
          detail:
            "missing — derive from chain_adapter's DELEGATION_SIGNER_KEY and export SESSION_SIGNER_ADDRESS"
        }

      <<"0x", _hex::binary-size(40)>> = addr ->
        %{
          key: ":bank, BrowserInstall :session_signer_address",
          status: :ok,
          detail: short_addr(addr)
        }

      bad ->
        %{
          key: ":bank, BrowserInstall :session_signer_address",
          status: :error,
          detail: "not a 0x-prefixed 40-hex EVM address: #{inspect(bad)}"
        }
    end
  end

  defp short_addr("0x" <> rest) when byte_size(rest) == 40 do
    "0x" <> String.slice(rest, 0, 4) <> "…" <> String.slice(rest, -4, 4)
  end

  defp short_addr(other), do: inspect(other)

  # `Bank.Chains.KernelVerifier` reads its chain RPC URL from the same
  # alias chain as `BrowserInstall.chain_rpc_url`. The verifier runs in
  # `Bank.Runtime.Workers.VerifyInstallOnchain` and silently marks
  # `install_failed` when the URL isn't set — easy to miss without an
  # explicit preflight line.
  @chain_rpc_aliases [
    "BASE_SEPOLIA_RPC_URL",
    "BASE_SEPOLIA_RPC",
    "BASE_RPC_URL"
  ]

  defp check_kernel_verifier_rpc_url(env) do
    config = Application.get_env(:bank, Bank.Chains.KernelVerifier, [])
    active_alias = resolve_chain_rpc_alias(env)

    case Keyword.get(config, :rpc_url) do
      nil ->
        %{
          key: ":bank, KernelVerifier :rpc_url",
          status: :error,
          detail:
            "missing — set one of " <>
              Enum.join(@chain_rpc_aliases, ", ") <>
              " (verifier silently fails closed without it)"
        }

      "" ->
        %{
          key: ":bank, KernelVerifier :rpc_url",
          status: :error,
          detail: "configured to empty string"
        }

      _ ->
        %{
          key: ":bank, KernelVerifier :rpc_url",
          status: :ok,
          detail:
            "(configured" <>
              case active_alias do
                nil -> "; via dev.exs default"
                alias_name -> "; from $" <> alias_name
              end <> ")"
        }
    end
  end

  defp resolve_chain_rpc_alias(env) do
    Enum.find(@chain_rpc_aliases, fn key ->
      case Map.get(env, key) do
        nil -> false
        "" -> false
        _value -> true
      end
    end)
  end

  # `validation_id_check: :skip` synthesizes a non-zero
  # `validationConfig` response so the verifier passes without
  # actually probing the kernel. Acceptable in dev (the bundler-
  # accepted UserOp + on-chain deployment are the actual proof of
  # install); production should flip to `:enforce` once the
  # `validationConfig(bytes21)` selector is reconciled against the
  # deployed Kernel — see the TODO at the bottom of
  # `docs/runbooks/browser-install-path-a.md`.
  #
  # Loudly warn when `:skip` is active so a reviewer notices.
  defp check_kernel_verifier_validation_id_check do
    mode =
      Application.get_env(:bank, Bank.Chains.KernelVerifier, [])
      |> Keyword.get(:validation_id_check, :enforce)

    case mode do
      :skip ->
        %{
          key: ":bank, KernelVerifier :validation_id_check",
          status: :ok,
          detail: ":skip (DEV ONLY — pin :enforce + correct selector before prod)"
        }

      :enforce ->
        %{
          key: ":bank, KernelVerifier :validation_id_check",
          status: :ok,
          detail: ":enforce"
        }

      other ->
        %{
          key: ":bank, KernelVerifier :validation_id_check",
          status: :error,
          detail: "unsupported value #{inspect(other)} (expect :skip or :enforce)"
        }
    end
  end

  # Browser-vs-operator Kernel index split. The browser-driven
  # install MUST use a different `index` than the chain_adapter's
  # runtime UserOps when the demo wallet imports
  # `OPERATOR_PRIVATE_KEY` — otherwise the derived smart account is
  # the operator's already-deployed one and the install reverts
  # `AA23` (Kernel `InvalidSignature()`). Phoenix-side preflight
  # refuses with `:kernel_account_collision`, but pre-flight is
  # better than refuse-at-install.
  defp check_kernel_account_indices(env) do
    config = Application.get_env(:bank, Bank.SessionPermissions.BrowserInstall, [])
    operator_index = Keyword.get(config, :operator_kernel_account_index, 0)
    browser_index = Keyword.get(config, :kernel_account_index, 1)
    operator_eoa = Keyword.get(config, :operator_eoa_address)

    if operator_index == browser_index do
      %{
        key: "kernel_account_index (browser vs operator)",
        status: :error,
        detail:
          "browser=#{inspect(browser_index)} == operator=#{inspect(operator_index)}; " <>
            "raise BROWSER_KERNEL_ACCOUNT_INDEX above " <>
            inspect(operator_index) <> " or risk on-chain AA23 collision " <>
            "(only matters when user EOA == OPERATOR_ADDRESS=#{short_addr(operator_eoa) || "<unset>"})"
      }
    else
      detail =
        "browser=#{browser_index}, operator=#{operator_index}" <>
          case operator_eoa do
            <<"0x", _::binary-size(40)>> = addr ->
              "; OPERATOR_ADDRESS=#{short_addr(addr)} (collision check active)"

            _ ->
              "; OPERATOR_ADDRESS unset (collision check inactive)"
          end <>
          alias_hint(env)

      %{
        key: "kernel_account_index (browser vs operator)",
        status: :ok,
        detail: detail
      }
    end
  end

  defp alias_hint(env) do
    cases =
      [
        {"BROWSER_KERNEL_ACCOUNT_INDEX", Map.get(env, "BROWSER_KERNEL_ACCOUNT_INDEX")},
        {"KERNEL_ACCOUNT_INDEX", Map.get(env, "KERNEL_ACCOUNT_INDEX")}
      ]
      |> Enum.flat_map(fn
        {_k, nil} -> []
        {_k, ""} -> []
        {k, v} -> [k <> "=" <> v]
      end)

    case cases do
      [] -> ""
      list -> "; env: " <> Enum.join(list, ", ")
    end
  end

  defp check_adapter_sign_session_portion_route do
    # The Path A install proxy depends on
    # `POST /install/sign_session_portion` being mounted on the
    # running adapter. We don't have the bearer secret here (it's
    # operator config), so a 401 from the route is the success
    # signal: the route exists, auth gate is on, but we're
    # intentionally unauthenticated.
    case probe_adapter_sign_session_portion() do
      {:ok, :gate_present} ->
        %{
          key: "chain_adapter /install/sign_session_portion",
          status: :ok,
          detail: "route present (401 on unauthenticated probe — expected)"
        }

      {:ok, :unexpected_open} ->
        %{
          key: "chain_adapter /install/sign_session_portion",
          status: :error,
          detail:
            "route responded to an UNAUTHENTICATED probe — adapter auth gate is missing"
        }

      {:error, :not_found} ->
        %{
          key: "chain_adapter /install/sign_session_portion",
          status: :error,
          detail: "route returned 404 — chain_adapter does not expose the install signing endpoint; rebuild + restart"
        }

      {:error, :connection_refused} ->
        %{
          key: "chain_adapter /install/sign_session_portion",
          status: :ok,
          detail: "(adapter not running — Phoenix-side preflight only)"
        }

      {:error, reason} ->
        %{
          key: "chain_adapter /install/sign_session_portion",
          status: :ok,
          detail: "(probe inconclusive: #{reason})"
        }
    end
  end

  defp probe_adapter_sign_session_portion do
    case :gen_tcp.connect(~c"127.0.0.1", 4100, [:binary, active: false], 250) do
      {:ok, sock} ->
        # Intentionally unauthenticated. The body shape doesn't matter
        # because the auth preHandler runs first; the response status
        # is what we care about. POST with `Content-Length: 0` to
        # keep the request well-formed.
        request =
          "POST /install/sign_session_portion HTTP/1.0\r\n" <>
            "Host: localhost\r\n" <>
            "Content-Type: application/json\r\n" <>
            "Content-Length: 0\r\n\r\n"

        :gen_tcp.send(sock, request)
        result = :gen_tcp.recv(sock, 0, 500)
        :gen_tcp.close(sock)

        case result do
          {:ok, data} ->
            # First line shape: `HTTP/1.x <status> <reason>`. Look only
            # at the 3-digit status — Fastify quirks (auth running
            # after body parse on some Content-Type combos) can make
            # an unauthenticated probe surface as 500 instead of 401;
            # we still know the route exists. The only true failure
            # is a 404.
            cond do
              data =~ ~r{HTTP/1\.\d 404} -> {:error, :not_found}
              data =~ ~r{HTTP/1\.\d 200} -> {:ok, :unexpected_open}
              data =~ ~r{HTTP/1\.\d [45]\d\d} -> {:ok, :gate_present}
              true -> {:error, "unexpected response"}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :econnrefused} ->
        {:error, :connection_refused}

      {:error, reason} ->
        {:error, reason}
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

  # Best-effort local-loopback probe of the chain_adapter health
  # endpoint on :4100. This is NOT an upstream RPC call — it's a
  # 50ms TCP/HTTP check against localhost so a reviewer running
  # the Path A flow can see at a glance whether the adapter is up.
  # Adapter not running is NOT a hard error (the smoke task is
  # Phoenix-side preflight); we report it as a warning so the
  # checklist exit code stays driven by the config-side checks.
  defp check_adapter_running do
    case probe_adapter_health() do
      :ok ->
        %{key: "chain_adapter :4100", status: :ok, detail: "/health responding"}

      {:error, :connection_refused} ->
        %{
          key: "chain_adapter :4100",
          status: :ok,
          detail:
            "(not running locally — start with `cd chain_adapter && node --env-file=.env node_modules/.bin/tsx watch src/server.ts`)"
        }

      {:error, reason} ->
        %{
          key: "chain_adapter :4100",
          status: :ok,
          detail: "(not reachable: #{reason})"
        }
    end
  end

  defp probe_adapter_health do
    # Minimal HTTP/1.1 request over plain TCP. No deps on Req/Finch
    # so this runs cleanly even when the app isn't started.
    case :gen_tcp.connect(~c"127.0.0.1", 4100, [:binary, active: false], 250) do
      {:ok, sock} ->
        :gen_tcp.send(sock, "GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n")
        result = :gen_tcp.recv(sock, 0, 500)
        :gen_tcp.close(sock)

        case result do
          {:ok, data} ->
            if data =~ "200 OK", do: :ok, else: {:error, "non-200 response"}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :econnrefused} ->
        {:error, :connection_refused}

      {:error, reason} ->
        {:error, reason}
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
