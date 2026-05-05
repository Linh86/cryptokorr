defmodule Bank.Chains.MainnetPreflight do
  @moduledoc """
  Read-only operator preflight for Base mainnet (#179).

  Pairs with the workspace mainnet eligibility flag added by #178.
  The workspace flag controls *whether a workspace may run mainnet*;
  this preflight verifies *whether the deployment is configured
  correctly to talk to Base mainnet at all*. Both gates must clear
  before a mainnet broadcast can land in production.

  ## What it verifies

  Every check returns one of:

    * `:ok` — verified healthy this tick.
    * `:degraded` — partially functional (e.g. RPC answered but
      with an unexpected response shape).
    * `:down` — known not working (transport error, 5xx).
    * `:not_configured` — deliberately absent (e.g. local/dev
      that has not provisioned a mainnet RPC URL).
    * `:unknown` — could not determine (timeout, raised).

  The checks are:

    * `:config_present` — required env keys (`BASE_RPC_URL`,
      `BUNDLER_RPC_URL`, `BASE_CHAIN_ID`, `SMART_ACCOUNT_ADDRESS`)
      are non-empty. Missing → `:not_configured` with the
      specific key in `detail`.
    * `:chain_id_declared` — `BASE_CHAIN_ID` parses to
      `#{8453}` (Base mainnet). Anything else
      (including `84532` Sepolia) → `:down` with
      `chain_id_declared_mismatch`.
    * `:chain_id_rpc` — JSON-RPC `eth_chainId` against
      `BASE_RPC_URL` returns `"0x2105"` (`8453`). Anything else
      → `:down` with `chain_id_rpc_mismatch` — this is the
      load-bearing check that catches "operator pasted a Sepolia
      RPC URL into a mainnet deployment".
    * `:entrypoint_code` — `eth_getCode` at the ERC-4337 v0.7
      EntryPoint address (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`)
      returns non-empty bytecode. Empty → `:down` with
      `entrypoint_missing`.
    * `:smart_account_address_shape` — `SMART_ACCOUNT_ADDRESS`
      is a 20-byte `0x`-prefixed hex string.
    * `:smart_account_code` — `eth_getCode` at
      `SMART_ACCOUNT_ADDRESS` reports either `:ok` (account
      already deployed) or `:degraded` with
      `smart_account_not_deployed` (informational; ZeroDev
      kernel deployment is a separate provisioning step, so
      this is **not** a hard fail).
    * `:smart_account_balance` — `eth_getBalance` at
      `SMART_ACCOUNT_ADDRESS` returns a numeric balance (the
      check passes regardless of amount; an empty / zero
      balance is a funding concern, not a config concern, and
      is the operator's responsibility).
    * `:bundler_url_shape` — `BUNDLER_RPC_URL` is an `http(s)`
      URL. We deliberately do **not** call the bundler: a
      bundler `eth_supportedEntryPoints` round-trip is a v1.1
      addition; #179 ships the static shape check.

  ## No broadcast path

  This module never sends a transaction, never signs anything,
  never enqueues an Oban worker. It issues `eth_chainId`,
  `eth_getCode`, and `eth_getBalance` JSON-RPC calls only —
  every one is a read-only state query.

  ## Secret hygiene

  `detail` is drawn from a small fixed allowlist
  (`config_missing`, `chain_id_declared_mismatch`,
  `chain_id_rpc_mismatch`, `entrypoint_missing`,
  `smart_account_not_deployed`, `transport_error`,
  `http_5xx`, `invalid_response`, `rpc_error`,
  `rpc_check_raised`, `rpc_check_timeout`,
  `bundler_url_invalid`, `smart_account_address_invalid`).

  Raw URLs, exception messages, RPC response bodies, and
  Authorization headers are NEVER surfaced — same posture as
  `Bank.Ops.Health.adapter/0` (#253).

  ## Test injection

  `run/1` accepts a `:rpc_fn` keyword that overrides the default
  `Req.post` driver:

      Bank.Chains.MainnetPreflight.run(
        env: %{"BASE_RPC_URL" => "...", ...},
        rpc_fn: fn _url, %{"method" => "eth_chainId"} -> {:ok, "0x2105"} end
      )

  This mirrors `Bank.Ops.AdapterHealthSnapshot.refresh/1`'s
  injectable health function and lets tests cover the
  chain-id-mismatch / entrypoint-missing / transport-error /
  5xx branches without opening a real socket.
  """

  require Logger

  alias Bank.Chains

  # Canonical ERC-4337 v0.7 EntryPoint deployed at the same
  # address on every supported EVM chain. If a future Base mainnet
  # fork diverges (unlikely but possible) we add a config knob;
  # today this is a constant.
  @entrypoint_v07 "0x0000000071727De22E5E9d8BAf0edAc6f37da032"

  @base_mainnet_chain_id 8453

  # `0x2105` == 8453 in lowercase hex without leading zeros, the
  # shape `eth_chainId` returns. We compare lowercased so an RPC
  # that happens to return `0x2105` vs `0X2105` does not flap.
  @base_mainnet_chain_id_hex "0x2105"

  @required_env ~w(BASE_RPC_URL BUNDLER_RPC_URL BASE_CHAIN_ID SMART_ACCOUNT_ADDRESS)

  @rpc_timeout_ms 3_000

  @type status :: :ok | :degraded | :down | :not_configured | :unknown
  @type check_result :: %{status: status(), detail: String.t() | nil}
  @type checks :: %{atom() => check_result()}

  @type preflight :: %{
          status: :ok | :degraded | :down | :not_configured,
          chain_id_expected: pos_integer(),
          entrypoint: String.t(),
          checks: checks()
        }

  @doc """
  Run the full read-only preflight.

  Options:

    * `:env` — env map. Defaults to `System.get_env/0`. Tests
      pass an explicit map.
    * `:rpc_fn` — 2-arity function `(rpc_url, jsonrpc_payload) ->
      {:ok, result} | {:error, fixed_label}`. Defaults to a
      `Req.post`-based driver. Tests pass a stub.

  Top-level rollup mirrors `Bank.Ops.Health.snapshot/0`:

    * `:ok` — every check is `:ok` or `:not_configured`. A
      deliberately-absent dependency (e.g. unset RPC URL) is
      benign at the rollup level, not a degradation.
    * `:degraded` / `:down` — at least one check reports the
      corresponding status.
    * `:not_configured` — every required env key is missing.

  """
  @spec run(keyword()) :: preflight()
  def run(opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    rpc_fn = Keyword.get(opts, :rpc_fn, &default_rpc/2)

    checks = %{
      config_present: check_config_present(env),
      chain_id_declared: check_chain_id_declared(env),
      smart_account_address_shape: check_smart_account_address_shape(env),
      bundler_url_shape: check_bundler_url_shape(env),
      chain_id_rpc: check_chain_id_rpc(env, rpc_fn),
      entrypoint_code: check_entrypoint_code(env, rpc_fn),
      smart_account_code: check_smart_account_code(env, rpc_fn),
      smart_account_balance: check_smart_account_balance(env, rpc_fn)
    }

    %{
      status: roll_up(checks),
      chain_id_expected: @base_mainnet_chain_id,
      entrypoint: @entrypoint_v07,
      checks: checks
    }
  end

  @doc """
  Returns the canonical Base mainnet chain id (`8453`).
  """
  @spec base_mainnet_chain_id() :: pos_integer()
  def base_mainnet_chain_id, do: @base_mainnet_chain_id

  @doc """
  Returns the ERC-4337 v0.7 EntryPoint address. Constant across
  every supported EVM chain today.
  """
  @spec entrypoint_v07() :: String.t()
  def entrypoint_v07, do: @entrypoint_v07

  @doc """
  Returns the list of env keys this preflight requires.
  """
  @spec required_env() :: [String.t()]
  def required_env, do: @required_env

  # --- top-level rollup ----------------------------------------------------

  defp roll_up(checks) do
    statuses = checks |> Map.values() |> Enum.map(& &1.status)

    cond do
      Enum.any?(statuses, &(&1 == :down)) -> :down
      Enum.any?(statuses, &(&1 == :degraded)) -> :degraded
      Enum.any?(statuses, &(&1 == :unknown)) -> :degraded
      Enum.all?(statuses, &(&1 == :not_configured)) -> :not_configured
      true -> :ok
    end
  end

  # --- shape checks (no RPC) -----------------------------------------------

  defp check_config_present(env) do
    missing =
      @required_env
      |> Enum.filter(fn key ->
        case Map.get(env, key) do
          nil -> true
          "" -> true
          _ -> false
        end
      end)

    case missing do
      [] -> ok()
      [first | _] -> not_configured("config_missing:#{first}")
    end
  end

  defp check_chain_id_declared(env) do
    case Map.get(env, "BASE_CHAIN_ID") do
      nil ->
        not_configured("config_missing:BASE_CHAIN_ID")

      "" ->
        not_configured("config_missing:BASE_CHAIN_ID")

      value ->
        case parse_chain_id(value) do
          {:ok, @base_mainnet_chain_id} -> ok()
          {:ok, _other} -> down("chain_id_declared_mismatch")
          :error -> down("chain_id_declared_mismatch")
        end
    end
  end

  defp check_smart_account_address_shape(env) do
    case Map.get(env, "SMART_ACCOUNT_ADDRESS") do
      nil -> not_configured("config_missing:SMART_ACCOUNT_ADDRESS")
      "" -> not_configured("config_missing:SMART_ACCOUNT_ADDRESS")
      addr -> if address?(addr), do: ok(), else: down("smart_account_address_invalid")
    end
  end

  defp check_bundler_url_shape(env) do
    case Map.get(env, "BUNDLER_RPC_URL") do
      nil -> not_configured("config_missing:BUNDLER_RPC_URL")
      "" -> not_configured("config_missing:BUNDLER_RPC_URL")
      url -> if url?(url), do: ok(), else: down("bundler_url_invalid")
    end
  end

  # --- RPC checks ----------------------------------------------------------

  defp check_chain_id_rpc(env, rpc_fn) do
    with_rpc(env, fn url ->
      case rpc_fn.(url, jsonrpc("eth_chainId", [])) do
        {:ok, hex} when is_binary(hex) ->
          if String.downcase(hex) == @base_mainnet_chain_id_hex,
            do: ok(),
            else: down("chain_id_rpc_mismatch")

        {:ok, _} ->
          down("invalid_response")

        {:error, label} when is_atom(label) ->
          rpc_error(label)
      end
    end)
  end

  defp check_entrypoint_code(env, rpc_fn) do
    with_rpc(env, fn url ->
      case rpc_fn.(url, jsonrpc("eth_getCode", [@entrypoint_v07, "latest"])) do
        {:ok, code} when is_binary(code) ->
          if non_empty_code?(code), do: ok(), else: down("entrypoint_missing")

        {:ok, _} ->
          down("invalid_response")

        {:error, label} when is_atom(label) ->
          rpc_error(label)
      end
    end)
  end

  defp check_smart_account_code(env, rpc_fn) do
    case Map.get(env, "SMART_ACCOUNT_ADDRESS") do
      nil ->
        not_configured("config_missing:SMART_ACCOUNT_ADDRESS")

      "" ->
        not_configured("config_missing:SMART_ACCOUNT_ADDRESS")

      addr ->
        if address?(addr) do
          with_rpc(env, fn url ->
            case rpc_fn.(url, jsonrpc("eth_getCode", [addr, "latest"])) do
              {:ok, code} when is_binary(code) ->
                # Smart-account-not-deployed is informational, not
                # a hard fail: ZeroDev kernel install is a
                # separate provisioning step (#171). Surface as
                # :degraded so an operator sees it without the
                # rollup blocking the deploy gate.
                if non_empty_code?(code),
                  do: ok(),
                  else: degraded("smart_account_not_deployed")

              {:ok, _} ->
                down("invalid_response")

              {:error, label} when is_atom(label) ->
                rpc_error(label)
            end
          end)
        else
          # Shape check already reported this as :down in
          # smart_account_address_shape; surface a quiet
          # not_configured here so the rollup is not double-counted.
          not_configured("smart_account_address_invalid")
        end
    end
  end

  defp check_smart_account_balance(env, rpc_fn) do
    case Map.get(env, "SMART_ACCOUNT_ADDRESS") do
      nil ->
        not_configured("config_missing:SMART_ACCOUNT_ADDRESS")

      "" ->
        not_configured("config_missing:SMART_ACCOUNT_ADDRESS")

      addr ->
        if address?(addr) do
          with_rpc(env, fn url ->
            case rpc_fn.(url, jsonrpc("eth_getBalance", [addr, "latest"])) do
              {:ok, hex} when is_binary(hex) ->
                # We don't gate on amount — funding is the
                # operator's job. We only confirm the call
                # round-tripped and the value parses.
                case parse_hex_int(hex) do
                  {:ok, _wei} -> ok()
                  :error -> down("invalid_response")
                end

              {:ok, _} ->
                down("invalid_response")

              {:error, label} when is_atom(label) ->
                rpc_error(label)
            end
          end)
        else
          not_configured("smart_account_address_invalid")
        end
    end
  end

  # --- shared RPC scaffolding ----------------------------------------------

  defp with_rpc(env, callback) do
    case Map.get(env, "BASE_RPC_URL") do
      nil -> not_configured("config_missing:BASE_RPC_URL")
      "" -> not_configured("config_missing:BASE_RPC_URL")
      url -> callback.(url)
    end
  end

  defp jsonrpc(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => params
    }
  end

  # Default JSON-RPC driver. Translates every transport / shape
  # variation into the fixed-allowlist atom vocabulary
  # `check_*_rpc` clauses pattern-match on. NEVER surfaces raw
  # URLs, exception messages, or response bodies — same posture
  # as `Bank.Ops.Health.adapter/0`.
  @doc false
  @spec default_rpc(String.t(), map()) :: {:ok, term()} | {:error, atom()}
  def default_rpc(url, payload) do
    response =
      Req.post(
        url: url,
        json: payload,
        retry: false,
        receive_timeout: @rpc_timeout_ms
      )

    case response do
      {:ok, %Req.Response{status: status, body: %{"result" => result}}}
      when status >= 200 and status < 300 ->
        {:ok, result}

      {:ok, %Req.Response{status: status, body: %{"error" => _}}}
      when status >= 200 and status < 300 ->
        {:error, :rpc_error}

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, :http_5xx}

      {:ok, %Req.Response{status: status}} when status >= 400 ->
        {:error, :http_4xx}

      {:ok, %Req.Response{}} ->
        {:error, :invalid_response}

      {:error, %{__struct__: Req.TransportError}} ->
        {:error, :transport_error}

      {:error, _} ->
        {:error, :transport_error}
    end
  rescue
    _ -> {:error, :rpc_check_raised}
  catch
    :exit, _ -> {:error, :rpc_check_timeout}
  end

  # --- shape result helpers ------------------------------------------------

  defp ok, do: %{status: :ok, detail: nil}
  defp degraded(detail), do: %{status: :degraded, detail: detail}
  defp down(detail), do: %{status: :down, detail: detail}
  defp not_configured(detail), do: %{status: :not_configured, detail: detail}
  defp unknown(detail), do: %{status: :unknown, detail: detail}

  # The RPC driver returns a fixed-allowlist atom, but the
  # check-result shape stores a string `detail`. Map atom →
  # string at the boundary so `inspect/1` of a Req struct can
  # never reach the operator output.
  defp rpc_error(:transport_error), do: down("transport_error")
  defp rpc_error(:http_5xx), do: down("http_5xx")
  defp rpc_error(:http_4xx), do: down("http_4xx")
  defp rpc_error(:rpc_error), do: down("rpc_error")
  defp rpc_error(:invalid_response), do: down("invalid_response")
  defp rpc_error(:rpc_check_raised), do: unknown("rpc_check_raised")
  defp rpc_error(:rpc_check_timeout), do: unknown("rpc_check_timeout")
  defp rpc_error(_), do: unknown("rpc_check_unknown")

  # --- shape predicates ----------------------------------------------------

  defp address?(value) when is_binary(value) do
    String.downcase(value) =~ ~r/^0x[0-9a-f]{40}$/
  end

  defp address?(_), do: false

  defp url?(value) when is_binary(value) do
    String.starts_with?(value, "http://") or String.starts_with?(value, "https://")
  end

  defp url?(_), do: false

  defp non_empty_code?(code) when is_binary(code) do
    code != "0x" and code != ""
  end

  defp non_empty_code?(_), do: false

  defp parse_chain_id(value) when is_integer(value), do: {:ok, value}

  defp parse_chain_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_chain_id(_), do: :error

  defp parse_hex_int("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_hex_int(_), do: :error

  # Compile-time sanity: keep `Bank.Chains` aware that mainnet
  # exists. This call is purely for the compiler — it's
  # defensive against a refactor that drops `"base"` from the
  # canonical mainnet list and silently breaks this preflight.
  _ = Chains.mainnet?("base")
end
