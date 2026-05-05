defmodule Bank.DefiVenues.Morpho.OnChainFacts do
  @moduledoc """
  Read-only on-chain ERC-4626 vault fact reader (#200).

  Issues `eth_call`s against a hard-allowlisted set of ERC-4626
  read methods and returns the decoded results as
  `Bank.DefiVenues.Morpho.OnChainVaultFacts`. The Morpho GraphQL
  API (#198) is fine for analytics; decisions that gate
  execution MUST re-verify against the chain.

  ## Hard-allowlisted method set

  Phase 1 only the following read methods are exposed:

    * `asset()` → `address` (selector `0x38d52e0f`)
    * `totalAssets()` → `uint256` (selector `0x01e1d114`)
    * `maxDeposit(address)` → `uint256` (selector `0x402d267d`)
    * `maxWithdraw(address)` → `uint256` (selector `0xce96cb77`)
    * `previewRedeem(uint256)` → `uint256` (selector `0x4cdad506`)

  No other method can be reached through this module. Arbitrary
  vault calldata is explicitly out of scope (see #200 non-goals).

  ## Read-only contract

  This module **never**:

    * dispatches a chain transaction,
    * signs a payload,
    * mutates DB rows,
    * calls `Bank.AdapterClient`,
    * enqueues an Oban job,
    * reads `.env` directly (configuration goes through
      `Application.get_env(:bank, __MODULE__, [])`).

  ## Configuration

      config :bank, Bank.DefiVenues.Morpho.OnChainFacts,
        base_url_by_chain: %{
          84532 => "https://sepolia.base.org"
        },
        req_options: []

  When no `base_url_by_chain` entry exists for a `chain_id` the
  module returns `{:error, :rpc_not_configured}` immediately
  without touching the network — the production-safe default
  for environments that haven't wired up an RPC source.

  ## Phase 1 chain allowlist

  Only `chain_id` values in `Bank.DefiVenues.Morpho.OnChainFacts.supported_chains/0`
  are accepted. Any other `chain_id` returns
  `{:error, :unsupported_chain}` before any HTTP / RPC call —
  this is the "chain id mismatch fails closed" acceptance bullet.

  ## Asset mismatch

  Pass `:expected_asset` (the off-chain GraphQL deposit asset
  address) and the reader will compare `asset()` against it
  case-insensitively. A mismatch returns
  `{:error, :asset_mismatch}` — the "API deposit asset mismatch
  with on-chain `asset()` fails closed" acceptance bullet.

  ## Test injection

  Tests pass `:rpc_fn` (1-arity function on `%{method, params}`)
  and never touch the network. The default `rpc_fn` reads the
  `Application.get_env` config above and routes via Req against
  the configured base_url.

  ## Secret hygiene

  The default rpc_fn never logs the configured `base_url` (which
  can carry tokenized RPC userinfo / query strings), the request
  payload, the raw Req error struct, or `Authorization` headers.
  Sanitised log lines collapse the underlying transport reason
  to a fixed enum.
  """

  require Logger

  alias Bank.DefiVenues.Morpho.OnChainVaultFacts

  # ERC-4626 function selectors. These are the well-known first
  # 4 bytes of `keccak256("<signature>")` — they're the public
  # ERC-4626 standard contract surface and verified against the
  # OpenZeppelin reference implementation.
  @asset_selector "0x38d52e0f"
  @total_assets_selector "0x01e1d114"
  @max_deposit_selector "0x402d267d"
  @max_withdraw_selector "0xce96cb77"
  @preview_redeem_selector "0x4cdad506"

  # Hard-allowlist. Anything outside this set cannot be called
  # through this module — see the moduledoc on the `non-goals`
  # bullet ("arbitrary vault calldata").
  @allowed_selectors [
    @asset_selector,
    @total_assets_selector,
    @max_deposit_selector,
    @max_withdraw_selector,
    @preview_redeem_selector
  ]

  # Phase 1 supported chains. Keys are EVM chain ids; values are
  # the human label used by the rest of the runtime
  # (`base-sepolia`, etc.). A future iteration adds mainnet here
  # once #166 permits.
  @supported_chains %{
    84_532 => "base-sepolia"
  }

  @typedoc "RPC source result (mirrors `Bank.Activity.ChainSync.RpcSource`)."
  @type rpc_result :: {:ok, String.t()} | {:error, String.t()}

  @typedoc "Read result."
  @type read_result ::
          {:ok, OnChainVaultFacts.t()}
          | {:error,
             :invalid_args
             | :unsupported_chain
             | :asset_mismatch
             | :invalid_response
             | :rpc_unavailable
             | :rpc_error_4xx
             | :rpc_error_5xx
             | :timeout
             | :rpc_not_configured}

  @doc """
  Read on-chain ERC-4626 vault facts for `(chain_id,
  vault_address)`.

  ## Args

    * `chain_id` — integer EVM chain id. Must be in
      `supported_chains/0` or the call returns
      `{:error, :unsupported_chain}`.
    * `vault_address` — 0x-prefixed 20-byte hex string. Lowercased
      server-side.
    * `opts`:
      * `:account` — optional 0x-prefixed 20-byte hex address.
        When provided, `maxDeposit(account)` and
        `maxWithdraw(account)` are read; otherwise both are
        skipped and surface as `nil` on the result.
      * `:expected_asset` — optional 0x-prefixed 20-byte hex
        address. When provided, `asset()` is compared
        case-insensitively against it; a mismatch returns
        `{:error, :asset_mismatch}`.
      * `:preview_shares` — optional non-negative integer. When
        provided, `previewRedeem(shares)` is read; otherwise
        skipped.
      * `:rpc_fn` — test injection (see moduledoc).
      * `:fetched_at` — clock override for deterministic tests.

  ## Returns

  `{:ok, %OnChainVaultFacts{}}` on success or one of the
  documented error tuples otherwise.
  """
  @spec read_facts(integer() | nil, String.t() | nil, keyword()) :: read_result()
  def read_facts(chain_id, vault_address, opts \\ [])

  def read_facts(chain_id, _vault_address, _opts) when not is_integer(chain_id),
    do: {:error, :invalid_args}

  def read_facts(_chain_id, vault_address, _opts)
      when not is_binary(vault_address) or vault_address == "",
      do: {:error, :invalid_args}

  def read_facts(chain_id, vault_address, opts) do
    cond do
      not Map.has_key?(@supported_chains, chain_id) ->
        {:error, :unsupported_chain}

      not valid_address?(vault_address) ->
        {:error, :invalid_args}

      true ->
        do_read(chain_id, String.downcase(vault_address), opts)
    end
  end

  @doc "Phase 1 chain allowlist. Stable for callers / tests."
  @spec supported_chains() :: %{integer() => String.t()}
  def supported_chains, do: @supported_chains

  @doc "Hard-allowlisted ERC-4626 selectors. Stable for callers / tests."
  @spec allowed_selectors() :: [String.t()]
  def allowed_selectors, do: @allowed_selectors

  # --- internals ----------------------------------------------------

  defp do_read(chain_id, vault_address, opts) do
    rpc_fn =
      Keyword.get_lazy(opts, :rpc_fn, fn -> default_rpc_fn(chain_id) end)

    fetched_at = Keyword.get(opts, :fetched_at, DateTime.utc_now())
    account = sanitize_account(Keyword.get(opts, :account))
    expected_asset = sanitize_account(Keyword.get(opts, :expected_asset))
    preview_shares = sanitize_shares(Keyword.get(opts, :preview_shares))

    with {:ok, asset} <- read_asset(rpc_fn, vault_address),
         :ok <- check_expected_asset(asset, expected_asset),
         {:ok, total_assets} <- read_total_assets(rpc_fn, vault_address),
         {:ok, max_deposit, dep_warnings} <-
           maybe_read_max_deposit(rpc_fn, vault_address, account),
         {:ok, max_withdraw, wd_warnings} <-
           maybe_read_max_withdraw(rpc_fn, vault_address, account),
         {:ok, preview_redeem, pr_warnings} <-
           maybe_read_preview_redeem(rpc_fn, vault_address, preview_shares) do
      {:ok,
       %OnChainVaultFacts{
         chain_id: chain_id,
         vault_address: vault_address,
         account: account,
         asset: asset,
         total_assets: total_assets,
         max_deposit: max_deposit,
         max_withdraw: max_withdraw,
         preview_redeem: preview_redeem,
         fetched_at: fetched_at,
         source_warnings: dep_warnings ++ wd_warnings ++ pr_warnings
       }}
    end
  end

  # --- per-method readers ------------------------------------------

  defp read_asset(rpc_fn, vault_address) do
    case eth_call(rpc_fn, vault_address, @asset_selector) do
      {:ok, hex} ->
        case decode_address(hex) do
          nil -> {:error, :invalid_response}
          addr -> {:ok, addr}
        end

      {:error, _} = err ->
        err
    end
  end

  defp read_total_assets(rpc_fn, vault_address) do
    case eth_call(rpc_fn, vault_address, @total_assets_selector) do
      {:ok, hex} ->
        case decode_uint256(hex) do
          nil -> {:error, :invalid_response}
          v -> {:ok, v}
        end

      {:error, _} = err ->
        err
    end
  end

  defp maybe_read_max_deposit(_rpc_fn, _vault_address, nil),
    do: {:ok, nil, [{:missing_field, :max_deposit}]}

  defp maybe_read_max_deposit(rpc_fn, vault_address, account) do
    data = @max_deposit_selector <> encode_address_arg(account)
    handle_optional_uint(eth_call(rpc_fn, vault_address, data), :max_deposit)
  end

  defp maybe_read_max_withdraw(_rpc_fn, _vault_address, nil),
    do: {:ok, nil, [{:missing_field, :max_withdraw}]}

  defp maybe_read_max_withdraw(rpc_fn, vault_address, account) do
    data = @max_withdraw_selector <> encode_address_arg(account)
    handle_optional_uint(eth_call(rpc_fn, vault_address, data), :max_withdraw)
  end

  defp maybe_read_preview_redeem(_rpc_fn, _vault_address, nil),
    do: {:ok, nil, [{:missing_field, :preview_redeem}]}

  defp maybe_read_preview_redeem(rpc_fn, vault_address, shares) do
    data = @preview_redeem_selector <> encode_uint256_arg(shares)
    handle_optional_uint(eth_call(rpc_fn, vault_address, data), :preview_redeem)
  end

  # `maxDeposit` / `maxWithdraw` can revert in some vault states
  # (paused, account-blocked). A revert surfaces from the RPC as
  # an error that we down-convert to a `:account_unavailable`
  # source warning rather than failing the whole read. The two
  # required reads (asset, totalAssets) still hard-fail on RPC
  # error.
  defp handle_optional_uint({:ok, hex}, _label) do
    case decode_uint256(hex) do
      nil -> {:ok, nil, []}
      v -> {:ok, v, []}
    end
  end

  defp handle_optional_uint({:error, reason}, label) do
    {:ok, nil, [{:account_unavailable, label_for(label, reason)}]}
  end

  defp label_for(_label, reason) when reason in [:rpc_error_4xx, :invalid_response],
    do: :reverted

  defp label_for(_label, reason), do: reason

  # --- eth_call wrapper --------------------------------------------

  # Goes through `rpc_fn` with the canonical `eth_call` shape.
  # The default rpc_fn (see `default_rpc_fn/1`) routes via Req
  # against the configured base_url.
  defp eth_call(rpc_fn, to, data) do
    request = %{
      method: "eth_call",
      params: [
        %{"to" => to, "data" => data},
        "latest"
      ]
    }

    case rpc_fn.(request) do
      {:ok, hex} when is_binary(hex) ->
        {:ok, hex}

      {:ok, _other} ->
        {:error, :invalid_response}

      {:error, "rpc_not_configured"} ->
        {:error, :rpc_not_configured}

      {:error, "rpc_unavailable"} ->
        {:error, :rpc_unavailable}

      {:error, "rpc_error_4xx"} ->
        {:error, :rpc_error_4xx}

      {:error, "rpc_error_5xx"} ->
        {:error, :rpc_error_5xx}

      {:error, "timeout"} ->
        {:error, :timeout}

      {:error, "invalid_response"} ->
        {:error, :invalid_response}

      {:error, label} when is_binary(label) ->
        # Anything outside the allowlist collapses to a generic
        # rpc_unavailable so a future RPC source returning a
        # surprising label cannot leak into our enum.
        {:error, :rpc_unavailable}

      _ ->
        {:error, :rpc_unavailable}
    end
  end

  defp check_expected_asset(_asset, nil), do: :ok

  defp check_expected_asset(asset, expected) when is_binary(asset) and is_binary(expected) do
    if String.downcase(asset) == String.downcase(expected),
      do: :ok,
      else: {:error, :asset_mismatch}
  end

  defp check_expected_asset(_, _), do: {:error, :asset_mismatch}

  # --- ABI helpers --------------------------------------------------

  defp encode_address_arg("0x" <> hex) when byte_size(hex) == 40 do
    "000000000000000000000000" <> String.downcase(hex)
  end

  defp encode_uint256_arg(int) when is_integer(int) and int >= 0 do
    int
    |> Integer.to_string(16)
    |> String.pad_leading(64, "0")
    |> String.downcase()
  end

  defp decode_address("0x" <> hex) when byte_size(hex) == 64 do
    addr_hex = String.slice(hex, 24, 40)
    "0x" <> String.downcase(addr_hex)
  end

  defp decode_address(_), do: nil

  defp decode_uint256("0x" <> hex) when is_binary(hex) and byte_size(hex) > 0 do
    case Integer.parse(hex, 16) do
      {n, ""} when n >= 0 -> Integer.to_string(n)
      _ -> nil
    end
  end

  defp decode_uint256(_), do: nil

  defp valid_address?("0x" <> hex),
    do: byte_size(hex) == 40 and Regex.match?(~r/\A[0-9a-fA-F]+\z/, hex)

  defp valid_address?(_), do: false

  defp sanitize_account(nil), do: nil

  defp sanitize_account(addr) when is_binary(addr) do
    if valid_address?(addr), do: String.downcase(addr), else: nil
  end

  defp sanitize_account(_), do: nil

  defp sanitize_shares(nil), do: nil

  defp sanitize_shares(int) when is_integer(int) and int >= 0, do: int

  defp sanitize_shares(_), do: nil

  # --- default RPC source ------------------------------------------

  defp default_rpc_fn(chain_id) do
    fn request ->
      config = Application.get_env(:bank, __MODULE__, [])
      base_url_by_chain = Keyword.get(config, :base_url_by_chain, %{})
      base_url = Map.get(base_url_by_chain, chain_id)

      if is_nil(base_url) or base_url == "" do
        {:error, "rpc_not_configured"}
      else
        do_default_call(base_url, request, Keyword.get(config, :req_options, []))
      end
    end
  end

  @default_timeout_ms 5_000

  defp do_default_call(base_url, request, extra) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => request.method,
      "params" => request.params
    }

    req_opts =
      [
        base_url: base_url,
        url: "/",
        method: :post,
        headers: [{"content-type", "application/json"}],
        json: body,
        receive_timeout: @default_timeout_ms,
        retry: false
      ]
      |> Keyword.merge(extra)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: %{"result" => result}}}
      when status in 200..299 ->
        {:ok, result}

      {:ok, %Req.Response{status: status, body: %{"error" => _}}}
      when status in 200..299 ->
        Logger.warning(
          "Bank.DefiVenues.Morpho.OnChainFacts: RPC returned application error " <>
            "(method=#{request.method})"
        )

        {:error, "invalid_response"}

      {:ok, %Req.Response{status: status}} when status in 400..499 ->
        Logger.warning(
          "Bank.DefiVenues.Morpho.OnChainFacts: RPC #{status} (method=#{request.method})"
        )

        {:error, "rpc_error_4xx"}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning(
          "Bank.DefiVenues.Morpho.OnChainFacts: RPC #{status} (method=#{request.method})"
        )

        {:error, "rpc_error_5xx"}

      {:error, reason} ->
        Logger.warning(
          "Bank.DefiVenues.Morpho.OnChainFacts: RPC unavailable " <>
            "(category=#{reason_category(reason)} method=#{request.method})"
        )

        case reason do
          %Req.TransportError{reason: :timeout} -> {:error, "timeout"}
          :timeout -> {:error, "timeout"}
          _ -> {:error, "rpc_unavailable"}
        end
    end
  end

  defp reason_category(%Req.TransportError{reason: :timeout}), do: :timeout
  defp reason_category(%Req.TransportError{reason: :econnrefused}), do: :econnrefused
  defp reason_category(%Req.TransportError{reason: :nxdomain}), do: :nxdomain
  defp reason_category(%Req.TransportError{}), do: :transport_error
  defp reason_category(:timeout), do: :timeout
  defp reason_category(:econnrefused), do: :econnrefused
  defp reason_category(:nxdomain), do: :nxdomain
  defp reason_category(_), do: :transport_error
end
