defmodule Bank.Delegations.Provisioning do
  @moduledoc """
  No-secret planning and validation helpers for Kernel v3 provisioning.

  This module deliberately does **not** call RPC endpoints, sign
  UserOperations, or claim that a smart account has been deployed. It
  gives operators and CI a safe preflight surface for GitHub #84:

    * validate that required environment variables are present and
      shaped correctly before running adapter-side provisioning scripts;
    * build a redacted command plan that can be pasted into an operator
      workspace without printing private keys;
    * validate the deployment-journal receipt that unblocks #83's ABI
      pin.

  Anything that would touch Base Sepolia or Base mainnet remains
  operator-side work in `chain_adapter/scripts/`.
  """

  @allowed_chain_ids [84532, 8453]
  @default_chain_id 84532

  @base_required_env ~w(
    OPERATOR_PRIVATE_KEY
    DELEGATION_SIGNER_PUBKEY
    BASE_RPC_URL
    BUNDLER_RPC_URL
    KERNEL_FACTORY_ADDRESS
    PERMISSION_VALIDATOR_ADDRESS
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
          mode: :sentinel_era | :kernel_provisioning_ready,
          required_env: [String.t()],
          problems: [problem()],
          redacted_env: map()
        }

  @doc "Environment variables required for each provisioning phase."
  @spec required_env(phase()) :: [String.t()]
  def required_env(:deploy), do: @base_required_env
  def required_env(:install), do: @base_required_env ++ [@smart_account_env]
  def required_env(:verify), do: @base_required_env ++ [@smart_account_env]
  def required_env(:runtime), do: ~w(SMART_ACCOUNT_ADDRESS PERMISSION_VALIDATOR_ADDRESS)

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
      mode: mode(env),
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
         next_issue: "After verify succeeds, hand the receipt to #83 for ABI/selector pinning."
       }}
    else
      {:error, checked}
    end
  end

  @doc """
  Validate the deployment-journal receipt emitted after #84 verification.

  This is the handoff contract from #84 to #83. It proves only that the
  receipt is complete and well-formed; it does not verify bytecode
  against the chain.
  """
  @spec validate_receipt(map()) :: {:ok, map()} | {:error, [problem()]}
  def validate_receipt(receipt) when is_map(receipt) do
    normalised = atomise_known_receipt_keys(receipt)

    problems =
      []
      |> validate_receipt_chain(normalised)
      |> validate_receipt_address(normalised, :smart_account_address)
      |> validate_receipt_address(normalised, :permission_validator_address)
      |> validate_receipt_address(normalised, :kernel_factory_address)
      |> validate_receipt_hash(normalised, :validator_bytecode_keccak256)
      |> validate_receipt_required_string(normalised, :vendor_source)
      |> validate_receipt_required_string(normalised, :basescan_validator_url)

    case problems do
      [] -> {:ok, build_handoff(normalised)}
      _ -> {:error, Enum.reverse(problems)}
    end
  end

  @doc """
  Read and validate a JSON receipt file from the adapter verification script.

  This is still a no-secret, no-RPC check. It exists so operators can
  validate the `verify-installed-validator.ts` output before handing it
  to #83 for ABI/artifact pinning.
  """
  @spec validate_receipt_file(Path.t()) ::
          {:ok, map()}
          | {:error, [problem()]}
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

  @doc "Return true for lowercase `0x` + 32-byte permission ids."
  @spec permission_id?(term()) :: boolean()
  def permission_id?(value), do: hex?(value, 32)

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

      key in ~w(DELEGATION_SIGNER_PUBKEY KERNEL_FACTORY_ADDRESS PERMISSION_VALIDATOR_ADDRESS SMART_ACCOUNT_ADDRESS) and
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

  defp mode(env) do
    case Map.get(env, "PERMISSION_VALIDATOR_ADDRESS") do
      value when is_binary(value) and value != "" -> :kernel_provisioning_ready
      _ -> :sentinel_era
    end
  end

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

  # --- receipt validation ------------------------------------------------

  defp atomise_known_receipt_keys(receipt) do
    known = %{
      "chain_id" => :chain_id,
      "smart_account_address" => :smart_account_address,
      "permission_validator_address" => :permission_validator_address,
      "validator_bytecode_keccak256" => :validator_bytecode_keccak256,
      "permission_validator_bytecode_keccak256" => :validator_bytecode_keccak256,
      "kernel_factory_address" => :kernel_factory_address,
      "vendor_source" => :vendor_source,
      "basescan_validator_url" => :basescan_validator_url,
      "chain_explorer_url" => :basescan_validator_url
    }

    Enum.reduce(receipt, %{}, fn {key, value}, acc ->
      Map.put(acc, Map.get(known, key, key), value)
    end)
  end

  defp validate_receipt_chain(problems, %{chain_id: chain_id})
       when chain_id in @allowed_chain_ids,
       do: problems

  defp validate_receipt_chain(problems, %{chain_id: chain_id}) when is_binary(chain_id) do
    case Integer.parse(chain_id) do
      {parsed, ""} -> validate_receipt_chain(problems, %{chain_id: parsed})
      _ -> [problem("chain_id", :invalid, "must be 84532 or 8453") | problems]
    end
  end

  defp validate_receipt_chain(problems, _receipt) do
    [problem("chain_id", :missing, "is required") | problems]
  end

  defp validate_receipt_address(problems, receipt, key) do
    value = Map.get(receipt, key)

    if address?(value) do
      problems
    else
      [
        problem(Atom.to_string(key), problem_severity(value), "must be a 20-byte EVM address")
        | problems
      ]
    end
  end

  defp validate_receipt_hash(problems, receipt, key) do
    value = Map.get(receipt, key)

    if hex?(value, 32) do
      problems
    else
      [
        problem(
          Atom.to_string(key),
          problem_severity(value),
          "must be a 32-byte 0x-prefixed hash"
        )
        | problems
      ]
    end
  end

  defp validate_receipt_required_string(problems, receipt, key) do
    case Map.get(receipt, key) do
      value when is_binary(value) and value != "" ->
        problems

      value ->
        [problem(Atom.to_string(key), problem_severity(value), "is required") | problems]
    end
  end

  defp build_handoff(receipt) do
    %{
      chain_id: int_chain_id(receipt.chain_id),
      smart_account_address: String.downcase(receipt.smart_account_address),
      permission_validator_address: String.downcase(receipt.permission_validator_address),
      kernel_factory_address: String.downcase(receipt.kernel_factory_address),
      deployed_bytecode_keccak256: String.downcase(receipt.validator_bytecode_keccak256),
      artifact_source_required: true,
      artifact_source_hint: receipt.vendor_source,
      chain_explorer_url: receipt.basescan_validator_url,
      next_issue: "#83"
    }
  end

  defp int_chain_id(value) when is_integer(value), do: value
  defp int_chain_id(value) when is_binary(value), do: String.to_integer(value)

  # --- commands ----------------------------------------------------------

  defp commands_for(:deploy) do
    [
      "npx tsx provision-kernel.ts",
      "record SMART_ACCOUNT_ADDRESS from stdout before continuing"
    ]
  end

  defp commands_for(:install) do
    [
      "export INSTALL_VALIDATOR=true",
      "npx tsx provision-kernel.ts",
      "record the install user-op hash and receipt"
    ]
  end

  defp commands_for(:verify) do
    [
      "unset INSTALL_VALIDATOR",
      "npx tsx verify-installed-validator.ts",
      "record permission_validator_bytecode_keccak256 for #83"
    ]
  end

  defp commands_for(:runtime) do
    [
      "set SMART_ACCOUNT_ADDRESS and PERMISSION_VALIDATOR_ADDRESS in the adapter secret store",
      "restart the adapter",
      "bash scripts/check-env.sh"
    ]
  end

  # --- primitives --------------------------------------------------------

  defp address?(value), do: hex?(value, 20)

  defp hex?(value, bytes) when is_binary(value) do
    Regex.match?(~r/^0x[0-9a-f]{#{bytes * 2}}$/, value)
  end

  defp hex?(_value, _bytes), do: false

  defp url?(value), do: String.starts_with?(value, ["http://", "https://"])

  defp placeholder?(value) do
    value = String.downcase(value)
    String.contains?(value, "placeholder") or String.contains?(value, "...")
  end

  defp problem(key, severity, detail), do: %{key: key, severity: severity, detail: detail}

  defp problem_severity(nil), do: :missing
  defp problem_severity(""), do: :missing

  defp problem_severity(value) when is_binary(value) do
    if placeholder?(value), do: :placeholder, else: :invalid
  end

  defp problem_severity(_), do: :invalid
end
