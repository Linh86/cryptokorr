defmodule Bank.Smoke.WalletDelegationSmokeTest do
  @moduledoc """
  Local mocked smoke for the MVP browser wallet → scoped session
  permission install → revoke → blocked-intent loop (#172).

  Mirrors the operator walkthrough in `docs/wallet-quickstart.md`
  step-for-step. Runs entirely in-process: no chain RPC, no adapter
  network IO, no broadcast. The test is the canonical fast feedback
  loop after any change to `Bank.WalletBindings`,
  `Bank.SessionPermissions`, or `Bank.Delegations.apply_callback/1`.

  Each describe block names a numbered step from the quickstart so a
  reviewer reading the test sees the same sequence they would see
  on the page.
  """

  use Bank.DataCase, async: false

  alias Bank.Accounts
  alias Bank.Audit
  alias Bank.Delegations
  alias Bank.Delegations.Delegation
  alias Bank.SessionPermissions
  alias Bank.SessionPermissions.Scope
  alias Bank.WalletBindings
  alias Bank.WalletBindings.Signature
  alias Bank.Workspaces

  # secp256k1 generator point — convenient deterministic test EOA.
  @privkey <<1::256>>

  # Pre-canned permission artifact set the adapter would echo back on
  # a successful grant. Mirrors the shape pinned by
  # `Bank.DelegationsTest`.
  @permission_id <<0xA1, 0xB2, 0xC3, 0xD4>>
  @validation_id <<0x02>> <> @permission_id <> :binary.copy(<<0x00>>, 16)
  @blob_b64 "eyJzZXJpYWxpemVkUGVybWlzc2lvbkFjY291bnQiOiJ0ZXN0In0="
  @session_signer "0x" <> String.duplicate("11", 20)

  setup do
    Bank.Security.PauseState.reset()

    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "smoke-wallet-#{suffix}",
        email: "smoke-wallet-#{suffix}@example.com",
        name: "Smoke Wallet User"
      })

    {:ok, workspace} =
      Workspaces.create_workspace(%{
        slug: "smoke-wallet-ws-#{suffix}",
        name: "Smoke wallet ws #{suffix}",
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

    %{user: user, workspace: workspace, address: address}
  end

  describe "MVP wallet smoke — install → active → revoke → blocked" do
    test "walks the full happy path with no chain calls", ctx do
      %{user: user, workspace: workspace, address: address} = ctx

      # 1. Connect: hook detects window.ethereum, reads chain id 84532,
      #    pushes wallet_connect:connected to the LiveView. (Outside
      #    the smoke surface — see ControlLiveTest for the JS round-
      #    trip.)

      # 2. Bind: Phoenix issues an EIP-191 challenge, the browser
      #    signs it via personal_sign, and Phoenix recovers the EOA.
      {:ok, challenge} =
        WalletBindings.issue_challenge(workspace.id, user.id, %{
          address: address,
          chain_id: Scope.chain_id()
        })

      assert challenge.workspace_id == workspace.id
      assert challenge.user_id == user.id
      assert challenge.address == String.downcase(address)
      assert challenge.chain_id == 84_532
      assert challenge.verified_at == nil

      signature = sign_personal(challenge.challenge_message, @privkey)
      {:ok, binding} = WalletBindings.verify_and_bind(challenge.id, signature)
      assert %DateTime{} = binding.verified_at
      assert WalletBindings.get_active_binding(workspace.id).id == binding.id

      # 3. Install request: SessionPermissions gates on the verified
      #    binding, audits, and dispatches through the existing
      #    GrantDelegation worker. No row exists yet — the adapter
      #    creates it via the callback.
      assert {:ok, smart_account_id} =
               SessionPermissions.request_install(workspace.id, binding)

      assert smart_account_id == "sa_wb_" <> binding.id
      assert is_nil(Delegations.get(smart_account_id))

      assert audit_event_for(binding.id, "session_permission.install_requested")
      assert audit_event_for_subject(smart_account_id, "delegation.connect_requested")

      # 4. Adapter granted callback: simulate the cryptographic
      #    install completing on chain. Phoenix promotes the row to
      #    :active and stores the permission artifacts.
      delegation_id_hex =
        "0x" <> Base.encode16(@permission_id, case: :lower)

      {:ok, granted} =
        Delegations.apply_callback(%{
          "smart_account_id" => smart_account_id,
          "delegation_id" => delegation_id_hex,
          "state" => "granted",
          "reason" => "wallet_connect_install",
          "permission" => %{
            "blob" => @blob_b64,
            "permission_id" => delegation_id_hex,
            "validation_id" => "0x" <> Base.encode16(@validation_id, case: :lower),
            "kernel_version" => "0.3.1",
            "package_version" => "5.6.3",
            "session_signer_address" => @session_signer,
            "installed_at_block" => 42_424_242,
            "install_tx_hash" => "0xdeadbeef"
          }
        })

      assert granted.state == :active
      assert granted.smart_account_id == smart_account_id
      assert Delegation.cryptographically_revocable?(granted)
      assert Delegations.executable?(smart_account_id)

      # 5. Auto-execute: an intent dispatched against an executable
      #    delegation can proceed. We do not run the full execution
      #    pipeline here — the executable? predicate is the boundary
      #    the runtime gate consults.
      assert Delegations.executable?(smart_account_id) == true

      # 6. Revoke: operator clicks Revoke. Phoenix records the
      #    requested transition; the actual on-chain revoke fires
      #    through the adapter, which we simulate via the revoking
      #    callback.
      {:ok, requested} = Delegations.record_revoke_requested(smart_account_id)
      assert requested.state == :revoking
      refute Delegations.executable?(smart_account_id)

      # 7. Adapter revoked callback: cryptographic uninstall confirmed.
      {:ok, revoked} =
        Delegations.apply_callback(%{
          "smart_account_id" => smart_account_id,
          "delegation_id" => delegation_id_hex,
          "state" => "revoked",
          "reason" => "operator_requested",
          "tx_refs" => %{"tx_hash" => "0xfeedface"}
        })

      assert revoked.state == :revoked
      refute Delegations.executable?(smart_account_id)

      # 8. Intent submitted post-revoke is blocked at the executable
      #    gate. Same boundary the runtime decision pipeline uses.
      refute Delegations.executable?(smart_account_id)
    end

    test "grant_failed callback emits an audit event and creates no row", ctx do
      %{user: user, workspace: workspace, address: address} = ctx

      {:ok, challenge} =
        WalletBindings.issue_challenge(workspace.id, user.id, %{
          address: address,
          chain_id: Scope.chain_id()
        })

      signature = sign_personal(challenge.challenge_message, @privkey)
      {:ok, binding} = WalletBindings.verify_and_bind(challenge.id, signature)

      {:ok, smart_account_id} =
        SessionPermissions.request_install(workspace.id, binding)

      assert {:error, :grant_failed} =
               Delegations.apply_callback(%{
                 "smart_account_id" => smart_account_id,
                 "delegation_id" => "del_smoke_failed",
                 "state" => "grant_failed",
                 "reason" => "permission_install_failed"
               })

      assert is_nil(Delegations.get(smart_account_id))
      refute Delegations.executable?(smart_account_id)

      event = audit_event_for_subject(smart_account_id, "delegation.grant_failed")
      assert event
      assert event.after_ref["reason"] == "permission_install_failed"
    end
  end

  # --- helpers ----------------------------------------------------------

  defp sign_personal(message, privkey) do
    digest = Signature.eip191_hash(message)
    {:ok, {r, s, v}} = ExSecp256k1.sign(digest, privkey)
    "0x" <> Base.encode16(r <> s <> <<v + 27>>, case: :lower)
  end

  defp audit_event_for(correlation_id, event_type) do
    %{events: events} =
      Audit.list_events(%{correlation_id: correlation_id}, limit: 20)

    Enum.find(events, &(&1.event_type == event_type))
  end

  defp audit_event_for_subject(subject_id, event_type) do
    %{events: events} = Audit.list_events(%{subject_id: subject_id}, limit: 20)
    Enum.find(events, &(&1.event_type == event_type))
  end
end
