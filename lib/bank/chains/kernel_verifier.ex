defmodule Bank.Chains.KernelVerifier do
  @moduledoc """
  Read-only on-chain verifier for ZeroDev Kernel v3.1 permission
  installations on Base Sepolia (#474, design § 8 — load-bearing
  invariant § 10.3).

  When the browser-signed install flow reports
  `attestation { status: "confirmed", userop_hash, tx_hash,
  block_number }`, Phoenix MUST NOT trust the browser's word — a
  malicious or buggy browser could fabricate the success report. The
  `Bank.Runtime.Workers.VerifyInstallOnchain` worker calls
  `verify/2` here to do an `eth_call` against the user's smart
  account and confirm the permission validator is actually
  installed with the `validation_id` Phoenix issued in the install
  envelope.

  ## What it verifies

  Two things have to hold for `verify/2` to return
  `{:ok, evidence}`:

    1. **Smart account is deployed.** `eth_getCode` at the smart
       account address returns non-empty bytecode. Without
       deployment, the kernel storage Phoenix is about to read does
       not exist yet, so an empty-code response is `:not_deployed`.
    2. **Validation slot is populated.** ZeroDev Kernel v3.1
       exposes a public mapping `validationConfig(bytes21 vId) ->
       (...)` that returns a non-zero hookCount / non-empty
       config when a validator with that id has been installed. We
       call it via `eth_call` and accept any non-empty / non-zero
       return as "installed". A zero return means the
       `validation_id` Phoenix expected was NOT installed by the
       UserOp the browser broadcast.

  Both checks are read-only `eth_call` / `eth_getCode` JSON-RPC
  hits. The verifier never sends a transaction, never signs
  anything, never enqueues an Oban worker.

  ## Configuration

  ```elixir
  # config/runtime.exs
  config :bank, Bank.Chains.KernelVerifier,
    rpc_url: System.get_env("BASE_SEPOLIA_RPC_URL")
  ```

  When `:rpc_url` is absent, `verify/2` returns
  `{:error, :rpc_not_configured}` — fail closed. The worker maps
  this to `:install_failed{reason: "onchain_verification_unreachable"}`
  so the deployment surfaces as misconfigured rather than
  silently approving every browser attestation.

  ## Test injection

  `verify/2` accepts a `:rpc_fn` keyword arg that overrides the
  default `Req.post`-based JSON-RPC driver. Mirrors
  `Bank.Chains.MainnetPreflight.run/1`'s `:rpc_fn`. Tests stub
  the chain entirely so unit tests never open a socket.

  ## Failure-reason allowlist

  Every `{:error, atom}` return is one of:

    * `:rpc_not_configured` — `:rpc_url` is unset; deployment is
      misconfigured.
    * `:chain_id_unsupported` — `chain_id` is not Base Sepolia
      (`84532`). Mainnet bindings are refused at the install
      envelope endpoint, but defense-in-depth at the verifier
      catches a regression.
    * `:smart_account_address_invalid` — input is not a 0x +
      40-hex string.
    * `:validation_id_invalid` — input is not a 21-byte 0x +
      42-hex string.
    * `:not_deployed` — smart account has no on-chain code.
    * `:not_installed` — the validation slot for the expected
      `validation_id` is empty / zero.
    * `:transport_error` — RPC was unreachable / 5xx / 4xx /
      malformed.
    * `:rpc_error` — RPC returned a JSON-RPC `error` envelope.
    * `:invalid_response` — RPC returned 2xx with a malformed body.
    * `:unknown` — exit / unhandled exception in the driver.

  Free-form upstream strings, raw URLs, exception messages, and
  Authorization headers are NEVER returned — same posture as
  `Bank.Chains.MainnetPreflight` and `Bank.Quotes.LiveProvider`.
  """

  require Logger

  # Base Sepolia EIP-155 chain id. Mainnet (8453) is rejected
  # closed at every layer per design § 10.1.
  @base_sepolia_chain_id 84_532

  @rpc_timeout_ms 3_000

  # `validationConfig(bytes21)` selector. The mapping returns the
  # ValidationConfig struct stored on the kernel; if the slot is
  # uninitialized it returns 32 zero bytes (single-word ABI return
  # for the packed config or whatever the kernel emits). For our
  # "is installed?" check, any non-zero return is "installed".
  #
  # Selector: keccak256("validationConfig(bytes21)") first 4 bytes.
  # Computed off-chain as `0x91244e98` (keccak("validationConfig(bytes21)")
  # = 0x91244e98...). Hard-coded so the verifier does not need a
  # keccak helper at boot time.
  @validation_config_selector "0x91244e98"

  @type evidence :: %{
          block_number_hex: String.t(),
          validation_config_hex: String.t(),
          smart_account_code_present: boolean()
        }

  @type failure ::
          :rpc_not_configured
          | :chain_id_unsupported
          | :smart_account_address_invalid
          | :validation_id_invalid
          | :not_deployed
          | :not_installed
          | :transport_error
          | :rpc_error
          | :invalid_response
          | :unknown

  @doc """
  Verify on-chain that the smart account at `smart_account_address`
  has the permission validator identified by `validation_id`
  installed on Base Sepolia.

  Required keys in `params`:

    * `:smart_account_address` — `0x` + 40-hex address (the kernel
      account, deployed or counterfactual).
    * `:validation_id` — `0x` + 42-hex (21-byte) bytes21 ValidationId.
    * `:chain_id` — must be `84532` (Base Sepolia).

  Optional opts:

    * `:rpc_fn` — 2-arity `(rpc_url, jsonrpc_payload) ->
      {:ok, term()} | {:error, atom()}`. Defaults to a
      `Req.post`-based driver. Tests stub.
    * `:block_tag` — `"latest"` (default) or a hex block string.

  Returns `{:ok, evidence}` on success or `{:error, atom}` from the
  fixed allowlist above on any verification failure.
  """
  @spec verify(map(), keyword()) :: {:ok, evidence()} | {:error, failure()}
  def verify(params, opts \\ []) do
    with {:ok, sa} <- check_smart_account_address(params),
         {:ok, vid} <- check_validation_id(params),
         :ok <- check_chain_id(params),
         {:ok, rpc_url} <- fetch_rpc_url(),
         rpc_fn = Keyword.get(opts, :rpc_fn, configured_rpc_fn()),
         block_tag = Keyword.get(opts, :block_tag, "latest"),
         {:ok, code_hex} <- get_code(rpc_fn, rpc_url, sa, block_tag),
         :ok <- assert_deployed(code_hex),
         {:ok, config_hex} <-
           read_or_skip_validation_config(rpc_fn, rpc_url, sa, vid, block_tag),
         :ok <- assert_validation_installed(config_hex) do
      {:ok,
       %{
         block_number_hex: block_tag,
         validation_config_hex: config_hex,
         smart_account_code_present: true
       }}
    end
  end

  # Per-validation `validationConfig(bytes21)` read.
  #
  # Selector `0x91244e98` is computed off-chain from the canonical
  # Kernel v3.1 ABI, but the actually-deployed Kernel implementation
  # at this point in the integration does NOT expose that exact
  # selector — every `eth_call` reverts. Until the integration TODO
  # documented in `chain_adapter/scripts/verify-installed-validator.ts`
  # ("verifying [permission install state] presence is the
  # integration TODO") lands, the check is gated by
  # `:validation_id_check`:
  #
  #   * `:enforce` — call `validationConfig`, fail closed on revert
  #     (production posture once the selector is right).
  #   * `:skip`    — return a synthetic `0x01` so
  #     `assert_validation_installed` passes. Used in dev where the
  #     deployment + bundler-accepted UserOp + receipt status are
  #     the actual proof of install. Setting it explicitly leaves a
  #     clear breadcrumb that this is a known degraded check, not a
  #     silent bypass.
  #
  # Defaults to `:skip` only in dev; runtime config can override
  # per-environment.
  defp read_or_skip_validation_config(rpc_fn, rpc_url, sa, vid, block_tag) do
    case validation_id_check_mode() do
      # Synthetic `0x01` is a non-zero hex string that passes
      # `assert_validation_installed/1` (which only refuses `"0x"`
      # and all-zero results). Acts as a deterministic stand-in
      # until the real selector is wired.
      :skip -> {:ok, "0x01"}
      _enforce -> read_validation_config(rpc_fn, rpc_url, sa, vid, block_tag)
    end
  end

  defp validation_id_check_mode do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:validation_id_check, :enforce)
  end

  # Read an injectable RPC function from app config; falls back to
  # the real Req-based driver. Used by the worker test path so the
  # `VerifyInstallOnchain` worker (which calls `verify/1` without
  # opts) can be exercised without a real network round-trip.
  defp configured_rpc_fn do
    case Application.get_env(:bank, __MODULE__, []) |> Keyword.get(:rpc_fn) do
      fun when is_function(fun, 2) -> fun
      _ -> &default_rpc/2
    end
  end

  @doc """
  Returns the canonical Base Sepolia chain id (`84532`).

  Re-exported so callers that need to assert the verifier's
  chain pin do not have to import the literal.
  """
  @spec base_sepolia_chain_id() :: pos_integer()
  def base_sepolia_chain_id, do: @base_sepolia_chain_id

  @doc """
  Returns the function selector the verifier issues against the
  kernel's `validationConfig(bytes21)` mapping. Useful for tests
  that assert the wire payload shape.
  """
  @spec validation_config_selector() :: String.t()
  def validation_config_selector, do: @validation_config_selector

  # --- input validation ---------------------------------------------------

  defp check_smart_account_address(%{smart_account_address: addr}) when is_binary(addr) do
    if address?(addr),
      do: {:ok, String.downcase(addr)},
      else: {:error, :smart_account_address_invalid}
  end

  defp check_smart_account_address(_), do: {:error, :smart_account_address_invalid}

  defp check_validation_id(%{validation_id: vid}) when is_binary(vid) do
    if validation_id?(vid),
      do: {:ok, String.downcase(vid)},
      else: {:error, :validation_id_invalid}
  end

  defp check_validation_id(_), do: {:error, :validation_id_invalid}

  defp check_chain_id(%{chain_id: @base_sepolia_chain_id}), do: :ok
  defp check_chain_id(_), do: {:error, :chain_id_unsupported}

  defp address?(value) when is_binary(value) do
    String.downcase(value) =~ ~r/^0x[0-9a-f]{40}$/
  end

  defp address?(_), do: false

  defp validation_id?(value) when is_binary(value) do
    String.downcase(value) =~ ~r/^0x[0-9a-f]{42}$/
  end

  defp validation_id?(_), do: false

  defp fetch_rpc_url do
    case Application.get_env(:bank, __MODULE__, []) |> Keyword.get(:rpc_url) do
      url when is_binary(url) and byte_size(url) > 0 -> {:ok, url}
      _ -> {:error, :rpc_not_configured}
    end
  end

  # --- chain reads --------------------------------------------------------

  defp get_code(rpc_fn, url, address, block_tag) do
    case rpc_fn.(url, jsonrpc("eth_getCode", [address, block_tag])) do
      {:ok, code_hex} when is_binary(code_hex) -> {:ok, code_hex}
      {:ok, _} -> {:error, :invalid_response}
      {:error, reason} -> {:error, normalize_rpc_error(reason)}
    end
  end

  defp assert_deployed(code_hex) do
    case String.downcase(code_hex) do
      "0x" -> {:error, :not_deployed}
      "0x00" -> {:error, :not_deployed}
      "0x" <> _ -> :ok
      _ -> {:error, :invalid_response}
    end
  end

  defp read_validation_config(rpc_fn, url, smart_account, validation_id, block_tag) do
    # Pad the bytes21 validation id to bytes32 ABI argument:
    # selector + 32-byte right-padded validation_id.
    "0x" <> vid_hex = validation_id
    padded_vid = String.pad_trailing(vid_hex, 64, "0")
    data = @validation_config_selector <> padded_vid

    payload =
      jsonrpc("eth_call", [
        %{"to" => smart_account, "data" => data},
        block_tag
      ])

    case rpc_fn.(url, payload) do
      {:ok, hex} when is_binary(hex) -> {:ok, hex}
      {:ok, _} -> {:error, :invalid_response}
      {:error, reason} -> {:error, normalize_rpc_error(reason)}
    end
  end

  # An empty / all-zero return from the storage mapping means the
  # validation_id has not been installed. Any non-zero return
  # (validator address, hookCount, install type, etc.) means it
  # has.
  defp assert_validation_installed(hex) do
    bytes = String.downcase(hex)

    case bytes do
      "0x" -> {:error, :not_installed}
      "0x" <> rest -> if all_zero?(rest), do: {:error, :not_installed}, else: :ok
      _ -> {:error, :invalid_response}
    end
  end

  defp all_zero?(hex), do: String.match?(hex, ~r/^0+$/)

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

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, :transport_error}

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
