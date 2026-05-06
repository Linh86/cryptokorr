defmodule Bank.WalletBindings.Signature do
  @moduledoc """
  EIP-191 personal-message signature verification.

  The browser wallet signs a server-issued challenge with
  `personal_sign`. The wallet hashes
  `\"\\x19Ethereum Signed Message:\\n\" <> byte_size(message) <> message`
  with Keccak-256 and signs the resulting digest with secp256k1.
  This module reverses that:

  1. Hash the message with the EIP-191 prefix.
  2. Recover the secp256k1 public key from the signature.
  3. Derive the Ethereum address from the public key
     (`last 20 bytes of keccak256(pubkey_xy)`).
  4. Compare to the expected address (lowercase, length-checked).

  No private keys, raw signatures, or recovered public keys are
  logged. Only structured failure reasons surface to callers.
  """

  @typedoc "0x-prefixed 42-char hex address, lowercase."
  @type address :: String.t()

  @doc """
  Verify that `signature` is a valid EIP-191 personal-message signature
  over `message` produced by the private key behind `expected_address`.

  Returns `:ok` on match. Returns `{:error, reason}` for every other
  outcome — `reason` is one of:

    * `:malformed_signature` — wrong length, missing `0x`, non-hex
    * `:invalid_recovery_id` — `v` byte is not 27/28 or 0/1
    * `:invalid_signature`   — recovery failed inside the NIF
    * `:address_mismatch`    — signature is valid but for a different EOA
    * `:invalid_address`     — `expected_address` is not a 0x-prefixed 42-char hex string
  """
  @spec verify_eip191(String.t(), String.t(), address()) ::
          :ok | {:error, atom()}
  def verify_eip191(message, signature, expected_address)
      when is_binary(message) and is_binary(signature) and is_binary(expected_address) do
    with {:ok, expected} <- normalize_address(expected_address),
         {:ok, sig_bytes} <- decode_signature(signature),
         {:ok, {r, s, recovery_id}} <- split_signature(sig_bytes),
         hash <- eip191_hash(message),
         {:ok, recovered_address} <- recover_address(hash, r, s, recovery_id) do
      if recovered_address == expected do
        :ok
      else
        {:error, :address_mismatch}
      end
    end
  end

  @doc """
  Compute the EIP-191 personal-message digest for `message`.

  Exposed so tests can build expected hashes without re-implementing
  the prefix.
  """
  @spec eip191_hash(String.t()) :: binary()
  def eip191_hash(message) when is_binary(message) do
    prefix = "\x19Ethereum Signed Message:\n#{byte_size(message)}"
    ExKeccak.hash_256(prefix <> message)
  end

  @doc """
  Derive the lowercase 0x-prefixed Ethereum address for an
  uncompressed secp256k1 public key (65 bytes starting with 0x04).
  """
  @spec address_from_pubkey(binary()) :: {:ok, address()} | {:error, :invalid_pubkey}
  def address_from_pubkey(<<0x04, xy::binary-size(64)>>) do
    digest = ExKeccak.hash_256(xy)
    <<_::binary-size(12), tail::binary-size(20)>> = digest
    {:ok, "0x" <> Base.encode16(tail, case: :lower)}
  end

  def address_from_pubkey(_), do: {:error, :invalid_pubkey}

  # --- internals ----------------------------------------------------------

  defp normalize_address("0x" <> hex) when byte_size(hex) == 40 do
    if String.match?(hex, ~r/^[0-9a-fA-F]{40}$/) do
      {:ok, "0x" <> String.downcase(hex)}
    else
      {:error, :invalid_address}
    end
  end

  defp normalize_address(_), do: {:error, :invalid_address}

  defp decode_signature("0x" <> hex), do: decode_signature_hex(hex)
  defp decode_signature(hex) when is_binary(hex), do: decode_signature_hex(hex)

  defp decode_signature_hex(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::binary-size(65)>> = bytes} -> {:ok, bytes}
      {:ok, _} -> {:error, :malformed_signature}
      :error -> {:error, :malformed_signature}
    end
  end

  defp split_signature(<<r::binary-size(32), s::binary-size(32), v::8>>) do
    case v do
      27 -> {:ok, {r, s, 0}}
      28 -> {:ok, {r, s, 1}}
      0 -> {:ok, {r, s, 0}}
      1 -> {:ok, {r, s, 1}}
      _ -> {:error, :invalid_recovery_id}
    end
  end

  defp recover_address(hash, r, s, recovery_id) do
    case ExSecp256k1.recover(hash, r, s, recovery_id) do
      {:ok, pubkey} -> address_from_pubkey(pubkey)
      {:error, _} -> {:error, :invalid_signature}
    end
  end
end
