defmodule Bank.Chains.BalanceReader do
  @moduledoc """
  Read-only ERC-20 balance reader for the redesigned wallet card.

  The Agent Control redesign's wallet status section displays a user's USDC
  balance on Base Sepolia. Until this module landed, the balance was
  hardcoded `nil` (rendering "— USDC") because neither
  `Bank.AdapterClient` nor the TS chain_adapter exposes a balance
  endpoint. This module fills that gap with a direct JSON-RPC
  `eth_call` against the configured Base Sepolia RPC, mirroring the
  pattern already established by `Bank.Chains.KernelVerifier`:

    * `Req.post` driver with a fixed timeout
    * `:rpc_fn` test injection
    * Sealed failure-reason allowlist (no upstream strings ever
      escape)
    * No transactions, no signing, no Oban work

  ## Configuration

      config :bank, Bank.Chains.BalanceReader,
        rpc_url: System.get_env("BASE_SEPOLIA_RPC_URL")

  When `:rpc_url` is absent, `get_erc20_balance/3` returns
  `{:error, :rpc_not_configured}` — fail closed. Callers (e.g.
  `BankWeb.AgentLive`) treat this as "render `nil`/`"— USDC"`" so
  the UI degrades gracefully instead of misleading the user.

  ## Token + chain support

  MVP only Base Sepolia + USDC. Both are pinned at compile time:

    * USDC Base Sepolia: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`
    * USDC has 6 decimals everywhere it ships.

  Adding more tokens / chains is a follow-up — extend
  `@token_address/2` with the new contract, document its decimals,
  add a chain → RPC config knob.

  ## Failure-reason allowlist

    * `:rpc_not_configured` — `:rpc_url` is unset.
    * `:chain_unsupported` — `chain` is not `"base-sepolia"`.
    * `:token_unsupported` — `token` is not `:usdc`.
    * `:account_address_invalid` — input is not `0x` + 40-hex.
    * `:transport_error` — RPC unreachable / 4xx / 5xx.
    * `:rpc_error` — RPC returned a JSON-RPC `error` envelope.
    * `:invalid_response` — RPC returned 2xx with malformed body.
    * `:unknown` — exit / unhandled exception in the driver.

  Free-form upstream strings, raw URLs, exception messages, and any
  Authorization headers are NEVER returned.
  """

  require Logger

  @rpc_timeout_ms 3_000

  # ERC-20 `balanceOf(address)` selector. Computed off-chain as
  # keccak256("balanceOf(address)")[0..3] = 0x70a08231. Hard-coded so
  # the reader doesn't need a keccak helper at boot time.
  @balance_of_selector "0x70a08231"

  # USDC contracts (6 decimals on every chain it ships).
  @usdc_base_sepolia "0x036cbd53842c5426634e7929541ec2318f3dcf7e"
  @usdc_decimals 6

  @type chain :: String.t()
  @type token :: :usdc
  @type account :: String.t()
  @type opts :: [rpc_fn: (String.t(), map() -> {:ok, term()} | {:error, atom()})]

  @type failure ::
          :rpc_not_configured
          | :chain_unsupported
          | :token_unsupported
          | :account_address_invalid
          | :transport_error
          | :rpc_error
          | :invalid_response
          | :unknown

  @doc """
  Read the ERC-20 balance for `account` on `chain` (`"base-sepolia"`
  for MVP) for `token` (`:usdc` for MVP).

  Returns `{:ok, %Decimal{}}` with a human-scale value (already
  divided by the token's decimal precision), or `{:error, atom}`
  from the fixed allowlist above.

  Optional `opts`:

    * `:rpc_fn` — 2-arity `(rpc_url, jsonrpc_payload) ->
      {:ok, term()} | {:error, atom()}`. Defaults to a `Req.post`-
      based driver. Tests stub the chain entirely.
  """
  @spec get_erc20_balance(chain(), account(), token(), opts()) ::
          {:ok, Decimal.t()} | {:error, failure()}
  def get_erc20_balance(chain, account, token, opts \\ []) do
    with :ok <- check_chain(chain),
         {:ok, account_normalised} <- check_account(account),
         {:ok, token_address, decimals} <- token_meta(token),
         {:ok, rpc_url} <- fetch_rpc_url(),
         rpc_fn = Keyword.get(opts, :rpc_fn, configured_rpc_fn()),
         {:ok, hex} <- read_balance(rpc_fn, rpc_url, token_address, account_normalised),
         {:ok, raw} <- decode_uint256(hex) do
      {:ok, scale_decimal(raw, decimals)}
    end
  end

  # --- input validation ---------------------------------------------------

  defp check_chain("base-sepolia"), do: :ok
  defp check_chain(_), do: {:error, :chain_unsupported}

  defp check_account(account) when is_binary(account) do
    if account =~ ~r/^0x[0-9a-fA-F]{40}$/,
      do: {:ok, String.downcase(account)},
      else: {:error, :account_address_invalid}
  end

  defp check_account(_), do: {:error, :account_address_invalid}

  defp token_meta(:usdc), do: {:ok, @usdc_base_sepolia, @usdc_decimals}
  defp token_meta(_), do: {:error, :token_unsupported}

  defp fetch_rpc_url do
    case Application.get_env(:bank, __MODULE__, []) |> Keyword.get(:rpc_url) do
      url when is_binary(url) and byte_size(url) > 0 -> {:ok, url}
      _ -> {:error, :rpc_not_configured}
    end
  end

  defp configured_rpc_fn do
    case Application.get_env(:bank, __MODULE__, []) |> Keyword.get(:rpc_fn) do
      fun when is_function(fun, 2) -> fun
      _ -> &default_rpc/2
    end
  end

  # --- chain read ---------------------------------------------------------

  defp read_balance(rpc_fn, url, token_address, account) do
    "0x" <> account_hex = account
    padded = String.pad_leading(account_hex, 64, "0")
    data = @balance_of_selector <> padded

    payload =
      jsonrpc("eth_call", [
        %{"to" => token_address, "data" => data},
        "latest"
      ])

    case rpc_fn.(url, payload) do
      {:ok, hex} when is_binary(hex) -> {:ok, hex}
      {:ok, _} -> {:error, :invalid_response}
      {:error, reason} -> {:error, normalize_rpc_error(reason)}
    end
  end

  defp decode_uint256("0x"), do: {:ok, 0}

  defp decode_uint256("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {value, ""} when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_response}
    end
  end

  defp decode_uint256(_), do: {:error, :invalid_response}

  defp scale_decimal(raw, decimals) when is_integer(raw) do
    raw
    |> Decimal.new()
    |> Decimal.div(Decimal.new(Integer.pow(10, decimals)))
    |> Decimal.round(decimals, :half_even)
  end

  # --- RPC driver ---------------------------------------------------------

  defp jsonrpc(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }
  end

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

      {:ok, %Req.Response{status: status}} when status >= 400 ->
        {:error, :transport_error}

      {:ok, %Req.Response{}} ->
        {:error, :invalid_response}

      {:error, %{__struct__: Req.TransportError}} ->
        {:error, :transport_error}

      {:error, _} ->
        {:error, :transport_error}
    end
  rescue
    _ -> {:error, :unknown}
  catch
    :exit, _ -> {:error, :unknown}
  end

  defp normalize_rpc_error(reason)
       when reason in [:transport_error, :rpc_error, :invalid_response, :unknown],
       do: reason

  defp normalize_rpc_error(_), do: :unknown
end
