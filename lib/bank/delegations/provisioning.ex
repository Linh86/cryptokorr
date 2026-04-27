defmodule Bank.Delegations.Provisioning do
  @moduledoc """
  No-secret operator preflight for the eventual ZeroDev kernel
  permissions integration.

  An earlier version of this module validated a "Permission Validator
  address" env var and a deployment-receipt shape that was specific
  to a wrong model — see `docs/zerodev-permissions-integration.md`.
  ZeroDev's `@zerodev/permissions@5.6.3` does not have a single
  Permission Validator contract; permissions compose from CREATE2
  signer + policy modules and a 4-byte `permissionId`.

  What this module still does:

    * Validate the *secret-bearing* env vars an operator needs for
      any kind of Kernel v3 provisioning (operator EOA private key,
      delegation signer public key, RPC + bundler URLs, optional
      Kernel factory address, optional smart account address).
    * Redact private-key-shaped values when echoing env to the
      operator console.

  What this module no longer does:

    * Validate the `PERMISSION_VALIDATOR_ADDRESS` env — it has been
      removed because ZeroDev does not produce a single value to put
      there.
    * Validate `permission_validator_address` /
      `validator_bytecode_keccak256` fields in a deployment receipt
      — the verification script that produced them was wrong-model.
      `validate_receipt/1` now returns a deferred-blocker error
      pointing at the integration doc until the corrected receipt
      shape is decided.
    * Pretend a `:kernel_provisioning_ready` runtime mode exists
      based on env presence. The runtime is sentinel-era until the
      ZeroDev SDK integration ships; preflight reports
      `:awaiting_zerodev_integration` instead.
  """

  @allowed_chain_ids [84532, 8453]
  @default_chain_id 84532

  @base_required_env ~w(
    OPERATOR_PRIVATE_KEY
    DELEGATION_SIGNER_PUBKEY
    BASE_RPC_URL
    BUNDLER_RPC_URL
    KERNEL_FACTORY_ADDRESS
  )

  @smart_account_env "SMART_ACCOUNT_ADDRESS"

  @type phase :: :deploy | :install | :verify | :runtime
  @type severity :: :missing | :placeholder | :invalid

  @type problem :: %{
          key: String.t(),
          severity: severity(),
          detail: String.t()
        }

  @type preflight :: %{
          phase: phase(),
          status: :ready | :blocked,
          chain_id: pos_integer(),
          mode: :sentinel_era | :awaiting_zerodev_integration,
          required_env: [String.t()],
          problems: [problem()],
          redacted_env: map()
        }

  @doc "Environment variables required for each provisioning phase."
  @spec required_env(phase()) :: [String.t()]
  def required_env(:deploy), do: @base_required_env
  def required_env(:install), do: @base_required_env ++ [@smart_account_env]
  def required_env(:verify), do: @base_required_env ++ [@smart_account_env]
  def required_env(:runtime), do: ~w(SMART_ACCOUNT_ADDRESS)

  @doc """
  Validate environment shape for a provisioning phase.

  Accepts an explicit env map so tests and operators can run this
  without reading process-global state. `System.get_env/0` can be
  passed by CLI wrappers.
  """
  @spec preflight(map(), phase()) :: preflight()
  def preflight(env, phase \\ :deploy) when is_map(env) do
    phase = normalise_phase!(phase)
    chain_id = chain_id(env)

    required = required_env(phase)

    problems =
      required
      |> Enum.flat_map(&validate_env_value(&1, Map.get(env, &1)))
      |> Kernel.++(validate_chain_id(chain_id))

    %{
      phase: phase,
      status: if(problems == [], do: :ready, else: :blocked),
      chain_id: chain_id,
      mode: mode(),
      required_env: required,
      problems: problems,
      redacted_env: redact_env(env, required ++ ["BASE_CHAIN_ID"])
    }
  end

  @doc """
  Build the operator command plan for a phase.

  Returns `{:error, preflight}` when required inputs are missing or
  malformed. The returned plan includes command strings only; secret
  values stay out of the output.
  """
  @spec plan(map(), phase()) :: {:ok, map()} | {:error, preflight()}
  def plan(env, phase \\ :deploy) when is_map(env) do
    checked = preflight(env, phase)

    if checked.status == :ready do
      {:ok,
       %{
         phase: checked.phase,
         chain_id: checked.chain_id,
         mode: checked.mode,
         commands: commands_for(checked.phase),
         redacted_env: checked.redacted_env,
         next_issue:
           "ZeroDev SDK integration is pending — see docs/zerodev-permissions-integration.md before running phase commands."
       }}
    else
      {:error, checked}
    end
  end

  @doc """
  Validate a deployment-journal receipt (deferred).

  The earlier shape of this validator (`permission_validator_address`,
  `validator_bytecode_keccak256`, `permission_id?`) was tied to the
  wrong-model assumption that ZeroDev produces a single deployable
  validator with a single ABI fragment. The corrected ZeroDev model
  has neither — `toPermissionValidator()` returns
  `address: zeroAddress` and revoke is a kernel-account
  `uninstallValidation` call. Until the corrected receipt shape is
  decided alongside the ZeroDev SDK integration, this function
  refuses to validate. Operators are pointed at the tracking doc.
  """
  @spec validate_receipt(map()) :: {:error, [problem()]}
  def validate_receipt(receipt) when is_map(receipt) do
    {:error,
     [
       problem(
         "receipt",
         :invalid,
         "deployment-receipt validator was wrong-model and has been deferred; " <>
           "see docs/zerodev-permissions-integration.md for the corrected ZeroDev model"
       )
     ]}
  end

  @doc """
  File-shape gate around `validate_receipt/1`.

  Surfaces the same deferred-blocker error after the file has been
  read and parsed. The file IO and JSON-decode error paths still
  fire in case an operator points the task at a missing or
  malformed file.
  """
  @spec validate_receipt_file(Path.t()) ::
          {:error, [problem()]}
          | {:error, {:read_failed, File.posix()}}
          | {:error, {:decode_failed, Jason.DecodeError.t()}}
  def validate_receipt_file(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded) do
      validate_receipt(decoded)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:read_failed, reason}}

      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:decode_failed, reason}}

      false ->
        {:error, [problem("receipt", :invalid, "must be a JSON object")]}
    end
  end

  # --- env validation ----------------------------------------------------

  defp normalise_phase!(phase) when phase in [:deploy, :install, :verify, :runtime], do: phase

  defp normalise_phase!(phase) when is_binary(phase) do
    case phase do
      "deploy" -> :deploy
      "install" -> :install
      "verify" -> :verify
      "runtime" -> :runtime
      _ -> raise ArgumentError, "unknown provisioning phase: #{inspect(phase)}"
    end
  end

  defp validate_env_value(key, nil), do: [problem(key, :missing, "is required")]
  defp validate_env_value(key, ""), do: [problem(key, :missing, "is required")]

  defp validate_env_value(key, value) when is_binary(value) do
    cond do
      placeholder?(value) ->
        [problem(key, :placeholder, "still contains a placeholder value")]

      key in ~w(OPERATOR_PRIVATE_KEY) and not hex?(value, 32) ->
        [problem(key, :invalid, "must be a 32-byte 0x-prefixed hex private key")]

      key in ~w(DELEGATION_SIGNER_PUBKEY KERNEL_FACTORY_ADDRESS SMART_ACCOUNT_ADDRESS) and
          not address?(value) ->
        [problem(key, :invalid, "must be a 20-byte 0x-prefixed EVM address")]

      key in ~w(BASE_RPC_URL BUNDLER_RPC_URL) and not url?(value) ->
        [problem(key, :invalid, "must be an http(s) URL")]

      true ->
        []
    end
  end

  defp validate_env_value(key, _value), do: [problem(key, :invalid, "must be a string")]

  defp validate_chain_id(chain_id) when chain_id in @allowed_chain_ids, do: []

  defp validate_chain_id(chain_id) do
    [
      problem(
        "BASE_CHAIN_ID",
        :invalid,
        "must be 84532 (Sepolia) or 8453 (mainnet), got #{chain_id}"
      )
    ]
  end

  defp chain_id(env) do
    case Map.get(env, "BASE_CHAIN_ID") || Map.get(env, "CHAIN_ID") do
      nil -> @default_chain_id
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
    end
  rescue
    _ -> -1
  end

  # The runtime is sentinel-era today and will stay that way until the
  # ZeroDev SDK integration in `docs/zerodev-permissions-integration.md`
  # ships. There is no longer an env-derived "ready" state.
  defp mode, do: :awaiting_zerodev_integration

  defp redact_env(env, keys) do
    keys
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(env, key) do
        nil -> acc
        value -> Map.put(acc, key, redact_value(key, value))
      end
    end)
  end

  defp redact_value(key, value) when key in ~w(OPERATOR_PRIVATE_KEY DELEGATION_SIGNER_KEY) do
    redact_secret(value)
  end

  defp redact_value(_key, value), do: value

  defp redact_secret(value) when is_binary(value) and byte_size(value) > 12 do
    String.slice(value, 0, 6) <> "..." <> String.slice(value, -4, 4)
  end

  defp redact_secret(_), do: "<redacted>"

  # --- shape helpers -----------------------------------------------------

  @placeholder_pattern ~r/_placeholder|placeholder_|_dev_placeholder|^0x_/

  defp placeholder?(value), do: Regex.match?(@placeholder_pattern, value)

  defp hex?(value, byte_len) when is_binary(value) and is_integer(byte_len) do
    expected = 2 + byte_len * 2

    case value do
      "0x" <> rest ->
        String.length(value) == expected and Regex.match?(~r/^[0-9a-f]+$/, rest)

      _ ->
        false
    end
  end

  defp hex?(_, _), do: false

  defp address?(value), do: hex?(value, 20)

  defp url?(value) when is_binary(value) do
    Regex.match?(~r"^https?://[^\s]+$", value)
  end

  defp url?(_), do: false

  defp commands_for(:deploy), do: ["npx tsx provision-kernel.ts"]
  defp commands_for(:install), do: ["INSTALL_VALIDATOR=true npx tsx provision-kernel.ts"]
  defp commands_for(:verify), do: ["npx tsx verify-installed-validator.ts"]

  defp commands_for(:runtime),
    do: ["check-env.sh"]

  defp problem(key, severity, detail) do
    %{key: key, severity: severity, detail: detail}
  end
end
