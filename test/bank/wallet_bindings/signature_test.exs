defmodule Bank.WalletBindings.SignatureTest do
  @moduledoc """
  Unit tests for EIP-191 personal-message signature verification.

  Builds known-good signatures with `ExSecp256k1.sign/2` and the
  EIP-191 prefix, then asserts that `Signature.verify_eip191/3` matches
  the address derived from the same private key. Tampered inputs must
  surface as structured `{:error, atom}` returns.
  """

  use ExUnit.Case, async: true

  alias Bank.WalletBindings.Signature

  # secp256k1 generator point — convenient deterministic test key.
  @privkey <<1::256>>
  # second deterministic test key (different address)
  @other_privkey <<2::256>>

  setup_all do
    {:ok, pubkey} = ExSecp256k1.create_public_key(@privkey)
    {:ok, address} = Signature.address_from_pubkey(pubkey)

    {:ok, other_pubkey} = ExSecp256k1.create_public_key(@other_privkey)
    {:ok, other_address} = Signature.address_from_pubkey(other_pubkey)

    %{
      pubkey: pubkey,
      address: address,
      other_pubkey: other_pubkey,
      other_address: other_address
    }
  end

  describe "address_from_pubkey/1" do
    test "derives a lowercase 0x-prefixed 42-char address", %{address: address} do
      assert "0x" <> hex = address
      assert byte_size(hex) == 40
      assert String.match?(hex, ~r/^[0-9a-f]{40}$/)
    end

    test "rejects compressed or malformed pubkeys" do
      assert {:error, :invalid_pubkey} = Signature.address_from_pubkey(<<0x02, 0::256>>)
      assert {:error, :invalid_pubkey} = Signature.address_from_pubkey(<<>>)
    end
  end

  describe "verify_eip191/3 — happy paths" do
    test "accepts a signature with v=27 (legacy)", %{address: address} do
      message = "hello binding"
      signature = sign_personal(message, @privkey, :legacy)
      assert :ok = Signature.verify_eip191(message, signature, address)
    end

    test "accepts a signature with v=0 (modern)", %{address: address} do
      message = "hello binding"
      signature = sign_personal(message, @privkey, :modern)
      assert :ok = Signature.verify_eip191(message, signature, address)
    end

    test "is case-insensitive on the expected address", %{address: address} do
      message = "Hello-Mixed-Case"
      signature = sign_personal(message, @privkey, :legacy)
      checksummed = "0x" <> String.upcase(String.trim_leading(address, "0x"))
      assert :ok = Signature.verify_eip191(message, signature, checksummed)
    end

    test "matches the EIP-191 prefix exactly" do
      # Sanity check: the digest helper composes "\x19Ethereum Signed
      # Message:\n<len><msg>" before keccak256. Tampering with the
      # prefix must change the digest.
      msg = "abc"
      assert Signature.eip191_hash(msg) != ExKeccak.hash_256(msg)

      assert Signature.eip191_hash(msg) ==
               ExKeccak.hash_256("\x19Ethereum Signed Message:\n3abc")
    end
  end

  describe "verify_eip191/3 — sad paths" do
    test "rejects a signature for a different address", %{
      address: address,
      other_address: other
    } do
      assert address != other
      message = "binding payload"
      signature = sign_personal(message, @other_privkey, :legacy)
      assert {:error, :address_mismatch} = Signature.verify_eip191(message, signature, address)
    end

    test "rejects a signature over a different message", %{address: address} do
      signature = sign_personal("message A", @privkey, :legacy)

      assert {:error, :address_mismatch} =
               Signature.verify_eip191("message B", signature, address)
    end

    test "rejects a malformed signature (wrong length)", %{address: address} do
      assert {:error, :malformed_signature} =
               Signature.verify_eip191("msg", "0x" <> String.duplicate("aa", 32), address)
    end

    test "rejects a malformed signature (missing 0x and odd-length)", %{address: address} do
      assert {:error, :malformed_signature} =
               Signature.verify_eip191("msg", "abc", address)
    end

    test "rejects a malformed signature (non-hex characters)", %{address: address} do
      bogus = "0x" <> String.duplicate("zz", 65)
      assert {:error, :malformed_signature} = Signature.verify_eip191("msg", bogus, address)
    end

    test "rejects an invalid recovery id (v not in 0/1/27/28)", %{address: address} do
      message = "hi"
      signature = sign_personal(message, @privkey, :legacy)
      <<rs::binary-size(64), _v::8>> = decode_signature(signature)
      tampered = "0x" <> Base.encode16(rs <> <<99>>, case: :lower)

      assert {:error, :invalid_recovery_id} =
               Signature.verify_eip191(message, tampered, address)
    end

    test "rejects an invalid expected_address shape", %{address: _} do
      message = "hi"
      signature = sign_personal(message, @privkey, :legacy)

      assert {:error, :invalid_address} =
               Signature.verify_eip191(message, signature, "not-an-address")

      assert {:error, :invalid_address} = Signature.verify_eip191(message, signature, "0xZZZZ")
    end
  end

  # --- helpers -----------------------------------------------------------

  # Build an EIP-191 personal_sign signature in either legacy (v=27/28)
  # or modern (v=0/1) form. Returns 0x-prefixed hex.
  defp sign_personal(message, privkey, mode) do
    digest = Signature.eip191_hash(message)
    {:ok, {r, s, v}} = ExSecp256k1.sign(digest, privkey)

    final_v =
      case mode do
        :modern -> v
        :legacy -> v + 27
      end

    "0x" <> Base.encode16(r <> s <> <<final_v>>, case: :lower)
  end

  defp decode_signature("0x" <> hex) do
    {:ok, bytes} = Base.decode16(hex, case: :mixed)
    bytes
  end
end
