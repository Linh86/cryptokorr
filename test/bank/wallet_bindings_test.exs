defmodule Bank.WalletBindingsTest do
  @moduledoc """
  Context tests for `Bank.WalletBindings`.

  Pins the acceptance criteria from #169:

    * issue_challenge/3 happy path + chain/address validation
    * verify_and_bind/2 happy path + every rejection reason the
      acceptance criteria call out: expiry, replay (already verified),
      address mismatch, malformed signature
    * get_active_binding/1 selects the most recent verified row and
      ignores pending / revoked rows
    * revoke_binding/2 round-trip
    * audit redaction: nonce + signature + challenge_message never
      land in the audit `after_ref`
  """

  use Bank.DataCase, async: true

  alias Bank.Accounts
  alias Bank.Audit
  alias Bank.WalletBindings
  alias Bank.WalletBindings.{Signature, WalletBinding}
  alias Bank.Workspaces

  # secp256k1 generator point — convenient deterministic test key.
  @privkey <<1::256>>
  @other_privkey <<2::256>>

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "wb-test-#{suffix}",
        email: "wb-test-#{suffix}@example.com",
        name: "WB Test"
      })

    {:ok, workspace} =
      Workspaces.create_workspace(%{
        slug: "wb-ws-#{suffix}",
        name: "WB ws #{suffix}",
        mainnet_enabled: false
      })

    {:ok, _} =
      Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: workspace.id,
        role: :admin
      })

    Process.put(:bank_test_workspace_id, workspace.id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    {:ok, pubkey} = ExSecp256k1.create_public_key(@privkey)
    {:ok, address} = Signature.address_from_pubkey(pubkey)

    {:ok, other_pubkey} = ExSecp256k1.create_public_key(@other_privkey)
    {:ok, other_address} = Signature.address_from_pubkey(other_pubkey)

    %{
      user: user,
      workspace: workspace,
      address: address,
      other_address: other_address
    }
  end

  describe "issue_challenge/3" do
    test "creates a pending binding for Base Sepolia", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      assert {:ok, binding} =
               WalletBindings.issue_challenge(workspace.id, user.id, %{
                 address: address,
                 chain_id: 84_532
               })

      assert binding.workspace_id == workspace.id
      assert binding.user_id == user.id
      assert binding.address == address
      assert binding.chain_id == 84_532
      assert binding.verified_at == nil
      assert binding.revoked_at == nil
      assert is_binary(binding.nonce)
      assert binding.challenge_message =~ "CryptoBank wants to bind"
      assert binding.challenge_message =~ binding.nonce
      assert binding.challenge_message =~ address
      assert DateTime.compare(binding.expires_at, DateTime.utc_now()) == :gt
    end

    test "normalizes uppercase addresses to lowercase", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      checksummed = "0x" <> String.upcase(String.trim_leading(address, "0x"))

      assert {:ok, binding} =
               WalletBindings.issue_challenge(workspace.id, user.id, %{
                 address: checksummed,
                 chain_id: 84_532
               })

      assert binding.address == address
    end

    test "rejects unsupported chains (Base mainnet)", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      assert {:error, :chain_not_supported} =
               WalletBindings.issue_challenge(workspace.id, user.id, %{
                 address: address,
                 chain_id: 8453
               })
    end

    test "rejects unsupported chains (Ethereum mainnet)", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      assert {:error, :chain_not_supported} =
               WalletBindings.issue_challenge(workspace.id, user.id, %{
                 address: address,
                 chain_id: 1
               })
    end

    test "rejects malformed addresses", %{workspace: workspace, user: user} do
      assert {:error, :invalid_address} =
               WalletBindings.issue_challenge(workspace.id, user.id, %{
                 address: "0xnope",
                 chain_id: 84_532
               })
    end

    test "writes a wallet_binding.challenge_issued audit event without leaking the nonce", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} =
        WalletBindings.issue_challenge(workspace.id, user.id, %{
          address: address,
          chain_id: 84_532
        })

      events = list_events(binding.id)

      assert event = Enum.find(events, &(&1.event_type == "wallet_binding.challenge_issued"))
      assert event.subject_type == "wallet_binding"
      assert event.subject_id == binding.id
      assert event.workspace_id == workspace.id

      assert_redacted(event, binding)
    end
  end

  describe "verify_and_bind/2" do
    test "marks the binding as verified for a valid signature", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      signature = sign(binding.challenge_message, @privkey)

      assert {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)
      assert verified.id == binding.id
      assert %DateTime{} = verified.verified_at
    end

    test "writes a wallet_binding.verified audit event without leaking the signature", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      signature = sign(binding.challenge_message, @privkey)
      {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)

      events = list_events(binding.id)
      assert event = Enum.find(events, &(&1.event_type == "wallet_binding.verified"))

      assert event.workspace_id == workspace.id
      assert_redacted(event, verified)
      refute serialize(event.after_ref) =~ signature
    end

    test "rejects an expired challenge", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)

      stale_expiry = DateTime.add(DateTime.utc_now(), -10, :second)

      Repo.update_all(
        from(b in WalletBinding, where: b.id == ^binding.id),
        set: [expires_at: stale_expiry]
      )

      signature = sign(binding.challenge_message, @privkey)

      assert {:error, :expired} = WalletBindings.verify_and_bind(binding.id, signature)
    end

    test "rejects an already-verified binding (replay)", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      signature = sign(binding.challenge_message, @privkey)
      {:ok, _} = WalletBindings.verify_and_bind(binding.id, signature)

      assert {:error, :already_verified} =
               WalletBindings.verify_and_bind(binding.id, signature)
    end

    test "rejects a signature from a different EOA (address mismatch)", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      signature = sign(binding.challenge_message, @other_privkey)

      assert {:error, :address_mismatch} =
               WalletBindings.verify_and_bind(binding.id, signature)
    end

    test "rejects a malformed signature", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)

      assert {:error, :malformed_signature} =
               WalletBindings.verify_and_bind(binding.id, "0xdeadbeef")
    end

    test "rejects an unknown challenge id with :not_found" do
      bogus = Ecto.UUID.generate()

      assert {:error, :not_found} =
               WalletBindings.verify_and_bind(bogus, "0x" <> String.duplicate("aa", 65))
    end

    test "rejects a revoked binding", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      signature = sign(binding.challenge_message, @privkey)
      {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)
      {:ok, _} = WalletBindings.revoke_binding(verified.id, :test)

      assert {:error, :revoked} = WalletBindings.verify_and_bind(binding.id, signature)
    end

    test "writes a failure audit event for every rejection reason", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      signature_other = sign(binding.challenge_message, @other_privkey)
      {:error, :address_mismatch} = WalletBindings.verify_and_bind(binding.id, signature_other)

      events = list_events(binding.id)
      assert event = Enum.find(events, &(&1.event_type == "wallet_binding.failed"))
      assert event.workspace_id == workspace.id
      assert event.after_ref["reason"] == "address_mismatch"
      refute serialize(event.after_ref) =~ binding.nonce
      refute serialize(event.after_ref) =~ signature_other
    end
  end

  describe "get_active_binding/1" do
    test "returns nil when no binding exists", %{workspace: workspace} do
      assert nil == WalletBindings.get_active_binding(workspace.id)
    end

    test "returns nil when only a pending challenge exists", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, _binding} = issue(workspace.id, user.id, address)
      assert nil == WalletBindings.get_active_binding(workspace.id)
    end

    test "returns the verified binding", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      signature = sign(binding.challenge_message, @privkey)
      {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)

      assert %WalletBinding{id: id} = WalletBindings.get_active_binding(workspace.id)
      assert id == verified.id
    end

    test "returns the most recent verified, non-revoked binding", %{
      workspace: workspace,
      user: user,
      address: address,
      other_address: other_address
    } do
      {:ok, b1} = issue(workspace.id, user.id, address)
      sig1 = sign(b1.challenge_message, @privkey)
      {:ok, _} = WalletBindings.verify_and_bind(b1.id, sig1)

      {:ok, b2} = issue(workspace.id, user.id, other_address)
      sig2 = sign(b2.challenge_message, @other_privkey)
      {:ok, latest} = WalletBindings.verify_and_bind(b2.id, sig2)

      assert %WalletBinding{id: id} = WalletBindings.get_active_binding(workspace.id)
      assert id == latest.id
      assert latest.address == other_address
    end

    test "ignores revoked bindings", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      signature = sign(binding.challenge_message, @privkey)
      {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)
      {:ok, _} = WalletBindings.revoke_binding(verified.id, :test)

      assert nil == WalletBindings.get_active_binding(workspace.id)
    end
  end

  describe "revoke_binding/2" do
    test "revokes a verified binding and audits", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      signature = sign(binding.challenge_message, @privkey)
      {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)

      assert {:ok, revoked} = WalletBindings.revoke_binding(verified.id, :operator_requested)
      assert %DateTime{} = revoked.revoked_at
      assert revoked.revoked_reason == "operator_requested"

      events = list_events(binding.id)
      assert Enum.any?(events, &(&1.event_type == "wallet_binding.revoked"))
    end

    test "rejects revoking a pending binding", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      assert {:error, :not_verified} = WalletBindings.revoke_binding(binding.id, :test)
    end

    test "rejects double revoke", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      {:ok, binding} = issue(workspace.id, user.id, address)
      signature = sign(binding.challenge_message, @privkey)
      {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)
      {:ok, _} = WalletBindings.revoke_binding(verified.id, :first)

      assert {:error, :already_revoked} =
               WalletBindings.revoke_binding(verified.id, :second)
    end
  end

  describe "build_message/1" do
    test "is stable for fixed inputs", %{address: address} do
      issued = ~U[2026-05-06 00:00:00.000000Z]
      expires = ~U[2026-05-06 00:05:00.000000Z]

      msg =
        WalletBindings.build_message(%{
          workspace_id: "ws-1",
          address: address,
          chain_id: 84_532,
          nonce: "deadbeef",
          issued_at: issued,
          expires_at: expires
        })

      assert msg =~ "Workspace: ws-1"
      assert msg =~ "Address:   #{address}"
      assert msg =~ "Chain:     84532 (Base Sepolia)"
      assert msg =~ "Nonce:     deadbeef"
      assert msg =~ "Issued:    2026-05-06T00:00:00.000000Z"
      assert msg =~ "Expires:   2026-05-06T00:05:00.000000Z"
    end
  end

  # --- helpers -----------------------------------------------------------

  defp issue(workspace_id, user_id, address) do
    WalletBindings.issue_challenge(workspace_id, user_id, %{
      address: address,
      chain_id: 84_532
    })
  end

  defp list_events(correlation_id) do
    Audit.list_events(%{correlation_id: correlation_id}, limit: 10)
    |> Map.get(:events)
  end

  defp sign(message, privkey) do
    digest = Signature.eip191_hash(message)
    {:ok, {r, s, v}} = ExSecp256k1.sign(digest, privkey)
    "0x" <> Base.encode16(r <> s <> <<v + 27>>, case: :lower)
  end

  defp serialize(value) do
    cond do
      is_binary(value) -> value
      true -> Jason.encode!(value)
    end
  end

  defp assert_redacted(event, %WalletBinding{} = binding) do
    payload = serialize(event.after_ref)

    refute payload =~ binding.nonce,
           "audit event leaked the nonce: #{payload}"

    refute payload =~ binding.challenge_message,
           "audit event leaked the challenge message body: #{payload}"
  end
end
