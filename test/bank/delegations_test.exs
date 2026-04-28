defmodule Bank.DelegationsTest do
  use Bank.DataCase, async: true

  alias Bank.Delegations

  describe "grant/3" do
    test "creates an active delegation" do
      assert {:ok, record} =
               Delegations.grant("sa_1", "del_1", %{
                 scope: %{"asset" => "USDC"}
               })

      assert record.state == :active
      assert record.smart_account_id == "sa_1"
      assert record.delegation_id == "del_1"
      assert record.scope == %{"asset" => "USDC"}
      assert %DateTime{} = record.granted_at
    end

    test "rejects when a non-terminal delegation already exists" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")

      assert {:error, :already_exists} = Delegations.grant("sa_1", "del_2")
    end

    test "allows re-grant after prior delegation is revoked" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_1")
      {:ok, _} = Delegations.record_revoked("sa_1")

      assert {:ok, re} = Delegations.grant("sa_1", "del_2")
      assert re.state == :active
      assert re.delegation_id == "del_2"
    end

    test "allows re-grant after prior delegation is expired" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_expired("sa_1")

      assert {:ok, re} = Delegations.grant("sa_1", "del_2")
      assert re.state == :active
    end
  end

  describe "get/1" do
    test "returns the non-terminal delegation" do
      {:ok, original} = Delegations.grant("sa_1", "del_1")

      result = Delegations.get("sa_1")
      assert result.id == original.id
      assert result.state == :active
    end

    test "returns nil after delegation is revoked" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_1")
      {:ok, _} = Delegations.record_revoked("sa_1")

      assert is_nil(Delegations.get("sa_1"))
    end

    test "returns nil for unknown smart account" do
      assert is_nil(Delegations.get("sa_ghost"))
    end
  end

  describe "get_by_id/1" do
    test "returns delegation by primary key" do
      {:ok, original} = Delegations.grant("sa_1", "del_1")

      assert {:ok, found} = Delegations.get_by_id(original.id)
      assert found.id == original.id
    end

    test "returns :not_found for unknown id" do
      assert {:error, :not_found} = Delegations.get_by_id(Ecto.UUID.generate())
    end
  end

  describe "revoke flow" do
    test "revoke_requested → revoked" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")

      assert {:ok, %{state: :revoking, revoke_requested_at: %DateTime{}}} =
               Delegations.record_revoke_requested("sa_1", %{last_reason: "operator_requested"})

      assert {:ok, %{state: :revoked, revoked_at: %DateTime{}}} =
               Delegations.record_revoked("sa_1")
    end

    test "duplicate revoke_requested callback is idempotent while already revoking" do
      {:ok, _} = Delegations.grant("sa_idempotent_revoke", "del_1")

      assert {:ok, %{state: :revoking} = first} =
               Delegations.record_revoke_requested("sa_idempotent_revoke", %{
                 last_reason: "operator_requested"
               })

      assert {:ok, %{state: :revoking} = second} =
               Delegations.record_revoke_requested("sa_idempotent_revoke", %{
                 last_reason: "adapter_ack"
               })

      assert second.id == first.id
      assert second.last_reason == "operator_requested"
    end

    test "record_revoked refuses to bypass :revoking (no fast-fail path)" do
      # Confirmed revoke means the chain said the revoke succeeded, so
      # :revoking must always be the prior state. Any failure of the
      # attempt itself routes through record_revoke_failed.
      {:ok, _} = Delegations.grant("sa_fast", "del_fast")

      assert {:error, :invalid_transition} = Delegations.record_revoked("sa_fast")
    end

    test "revoke on unknown smart account returns :not_found" do
      assert {:error, :not_found} = Delegations.record_revoke_requested("sa_missing")
      assert {:error, :not_found} = Delegations.record_revoked("sa_missing")
      assert {:error, :not_found} = Delegations.record_revoke_failed("sa_missing")
    end

    test "revoke on already-revoked delegation returns :not_found" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_1")
      {:ok, _} = Delegations.record_revoked("sa_1")

      # get/1 returns nil for terminal states, so this is :not_found
      assert {:error, :not_found} = Delegations.record_revoke_requested("sa_1")
    end
  end

  describe "revoke_failed flow (issue #31)" do
    test "revoking → revoke_failed records reason and tx hash" do
      {:ok, _} = Delegations.grant("sa_fail", "del_fail")
      {:ok, _} = Delegations.record_revoke_requested("sa_fail")

      tx_hash = "0x" <> String.duplicate("ab", 32)

      assert {:ok, delegation} =
               Delegations.record_revoke_failed("sa_fail", %{
                 last_reason: "sentinel_reverted",
                 last_tx_hash: tx_hash
               })

      assert delegation.state == :revoke_failed
      assert delegation.last_reason == "sentinel_reverted"
      assert delegation.last_tx_hash == tx_hash
    end

    test "revoke_failed from anything other than :revoking is :invalid_transition" do
      {:ok, _} = Delegations.grant("sa_ny", "del_ny")
      assert {:error, :invalid_transition} = Delegations.record_revoke_failed("sa_ny")
    end

    test "operator retry: revoke_failed → revoking → revoked" do
      {:ok, _} = Delegations.grant("sa_retry", "del_retry")
      {:ok, _} = Delegations.record_revoke_requested("sa_retry")
      {:ok, _} = Delegations.record_revoke_failed("sa_retry", %{last_reason: "send_failed: rpc"})

      # Operator retries via record_revoke_requested
      assert {:ok, %{state: :revoking}} =
               Delegations.record_revoke_requested("sa_retry", %{last_reason: "operator_retry"})

      # Subsequent success lands in :revoked
      assert {:ok, %{state: :revoked}} = Delegations.record_revoked("sa_retry")
    end

    test "revoke_failed is non-executable and non-terminal" do
      {:ok, _} = Delegations.grant("sa_exec", "del_exec")
      {:ok, _} = Delegations.record_revoke_requested("sa_exec")
      {:ok, _} = Delegations.record_revoke_failed("sa_exec")

      # Fail-closed: not executable.
      refute Delegations.executable?("sa_exec")

      # Non-terminal: still visible to get/1 and blocks re-grant.
      assert %{state: :revoke_failed} = Delegations.get("sa_exec")
      assert {:error, :already_exists} = Delegations.grant("sa_exec", "del_new")
    end
  end

  describe "expiry" do
    test "record_expired marks active delegation as :expired" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      assert {:ok, %{state: :expired}} = Delegations.record_expired("sa_1")
    end

    test "record_expired on revoking returns :invalid_transition" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_1")

      assert {:error, :invalid_transition} = Delegations.record_expired("sa_1")
    end

    test "record_expired on missing returns :not_found" do
      assert {:error, :not_found} = Delegations.record_expired("sa_missing")
    end
  end

  describe "executable?/2" do
    test "true only for active + non-expired" do
      now = ~U[2026-04-15 12:00:00Z]

      {:ok, _} = Delegations.grant("sa_never_expires", "del_1")
      assert Delegations.executable?("sa_never_expires", now)

      {:ok, _} =
        Delegations.grant("sa_future", "del_2", %{
          expires_at: ~U[2026-04-16 12:00:00Z]
        })

      assert Delegations.executable?("sa_future", now)

      {:ok, _} =
        Delegations.grant("sa_past", "del_3", %{
          expires_at: ~U[2026-04-15 11:00:00Z]
        })

      refute Delegations.executable?("sa_past", now)
    end

    test "false for revoking, revoked, expired, and missing" do
      {:ok, _} = Delegations.grant("sa_r1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_r1")
      refute Delegations.executable?("sa_r1")

      {:ok, _} = Delegations.grant("sa_r2", "del_2")
      {:ok, _} = Delegations.record_revoke_requested("sa_r2")
      {:ok, _} = Delegations.record_revoked("sa_r2")
      refute Delegations.executable?("sa_r2")

      {:ok, _} = Delegations.grant("sa_e1", "del_3")
      {:ok, _} = Delegations.record_expired("sa_e1")
      refute Delegations.executable?("sa_e1")

      refute Delegations.executable?("sa_ghost")
    end
  end

  describe "apply_callback/1" do
    test "granted callback creates delegation when none exists" do
      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "granted",
                 "reason" => "initial_grant",
                 "scope" => %{"asset" => "USDC"}
               })

      assert delegation.state == :active
      assert delegation.smart_account_id == "sa_1"
    end

    test "granted callback on existing active is idempotent" do
      {:ok, existing} = Delegations.grant("sa_1", "del_1")

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "granted",
                 "reason" => "re_confirm"
               })

      assert delegation.id == existing.id
    end

    test "revoking callback transitions active to revoking" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "revoking",
                 "reason" => "operator_requested"
               })

      assert delegation.state == :revoking
    end

    test "revoked callback transitions revoking to revoked" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_1")

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "revoked",
                 "reason" => "confirmed_on_chain",
                 "tx_refs" => [%{"hash" => "0xabc123"}]
               })

      assert delegation.state == :revoked
      assert delegation.last_tx_hash == "0xabc123"
    end

    test "expired callback transitions active to expired" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "expired",
                 "reason" => "window_closed"
               })

      assert delegation.state == :expired
    end

    test "unknown state returns error" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")

      assert {:error, :unknown_state} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "bogus",
                 "reason" => "test"
               })
    end

    test "grant_failed callback does not create an active delegation" do
      assert {:error, :grant_failed} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_failed_grant",
                 "delegation_id" => "grant_failed_1",
                 "state" => "grant_failed",
                 "reason" => "operator_key_missing"
               })

      refute Delegations.executable?("sa_failed_grant")
      assert is_nil(Delegations.get("sa_failed_grant"))
    end

    test "granted callback with a known grant-failure reason is rejected defensively" do
      assert {:error, :grant_failed} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_old_failure_shape",
                 "delegation_id" => "grant_failed_legacy",
                 "state" => "granted",
                 "reason" => "operator_key_missing"
               })

      refute Delegations.executable?("sa_old_failure_shape")
      assert is_nil(Delegations.get("sa_old_failure_shape"))
    end

    test "invalid callback shape returns error" do
      assert {:error, :invalid_callback} = Delegations.apply_callback(%{"bad" => "shape"})
    end
  end

  describe "revoke callback tx_ref propagation (issue #31)" do
    test "revoked callback with full tx_refs records the on-chain hash and reason" do
      {:ok, _} = Delegations.grant("sa_ref", "del_ref")
      {:ok, _} = Delegations.record_revoke_requested("sa_ref")

      tx_hash = "0x" <> String.duplicate("ef", 32)

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_ref",
                 "delegation_id" => "del_ref",
                 "state" => "revoked",
                 "reason" => "operator_requested",
                 "tx_refs" => [
                   %{
                     "chain" => "base",
                     "hash" => tx_hash,
                     "block_number" => 12_345_678,
                     "status" => "success"
                   }
                 ]
               })

      assert delegation.state == :revoked
      assert delegation.last_tx_hash == tx_hash
      assert delegation.last_reason == "operator_requested"
      assert %DateTime{} = delegation.revoked_at
    end

    test "revoke_failed callback from :revoking records the failure and stays fail-closed" do
      # When the adapter's revoke attempt fails on-chain (send rejected,
      # confirmation timeout, sentinel reverted) it emits
      # state=revoke_failed — NOT revoked. Phoenix records the failure
      # on the existing :revoking row so the operator can retry.
      {:ok, _} = Delegations.grant("sa_fail_cb", "del_x")
      {:ok, _} = Delegations.record_revoke_requested("sa_fail_cb")

      tx_hash = "0x" <> String.duplicate("cd", 32)

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_fail_cb",
                 "delegation_id" => "del_x",
                 "state" => "revoke_failed",
                 "reason" => "send_failed: insufficient funds",
                 "tx_refs" => [%{"chain" => "base", "hash" => tx_hash, "status" => "unknown"}]
               })

      assert delegation.state == :revoke_failed
      assert delegation.last_reason == "send_failed: insufficient funds"
      assert delegation.last_tx_hash == tx_hash
      refute Delegations.executable?("sa_fail_cb")
    end

    test "revoked callback from :active is refused (:invalid_transition)" do
      # Success must always follow :revoking. A direct :active → :revoked
      # would mean the adapter somehow confirmed a revoke it never
      # acknowledged starting — that's a contract violation, not a
      # recoverable state.
      {:ok, _} = Delegations.grant("sa_direct", "del_x")

      assert {:error, :invalid_transition} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_direct",
                 "delegation_id" => "del_x",
                 "state" => "revoked",
                 "reason" => "operator_requested"
               })
    end

    test "a duplicate revoked callback is a benign :invalid_transition" do
      {:ok, _} = Delegations.grant("sa_dup", "del_dup")
      {:ok, _} = Delegations.record_revoke_requested("sa_dup")

      payload = %{
        "smart_account_id" => "sa_dup",
        "delegation_id" => "del_dup",
        "state" => "revoked",
        "reason" => "operator_requested"
      }

      assert {:ok, d} = Delegations.apply_callback(payload)
      assert d.state == :revoked

      # The second callback finds no non-terminal row and reports
      # :not_found rather than double-recording. The controller treats
      # this as accepted_with_warning.
      assert {:error, :not_found} = Delegations.apply_callback(payload)
    end
  end

  describe "ERC-4337 v0.7 AA-shaped callbacks (issue #32)" do
    # The adapter's AA path emits `tx_refs` carrying both `userop_hash`
    # (EntryPoint identity) and `hash` (chain-level tx hash) on
    # confirmed receipts, plus `bundler` + hex `nonce`. Phoenix only
    # keeps one identifier on the delegation row; the invariant is
    # "prefer `hash` when present, fall back to `userop_hash`". That
    # keeps pre-inclusion states (broadcast, confirmation_failed)
    # navigable in the control tower instead of showing a blank anchor.
    test "revoked callback with AA tx_refs records the on-chain hash (prefers hash over userop_hash)" do
      {:ok, _} = Delegations.grant("sa_aa_ok", "del_aa")
      {:ok, _} = Delegations.record_revoke_requested("sa_aa_ok")

      userop_hash = "0x" <> String.duplicate("aa", 32)
      tx_hash = "0x" <> String.duplicate("bb", 32)

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_aa_ok",
                 "delegation_id" => "del_aa",
                 "state" => "revoked",
                 "reason" => "operator_requested",
                 "tx_refs" => [
                   %{
                     "chain" => "base",
                     "userop_hash" => userop_hash,
                     "hash" => tx_hash,
                     "nonce" => "0x7",
                     "bundler" => "base-v07-bundler",
                     "block_number" => 42_000,
                     "status" => "success"
                   }
                 ]
               })

      assert delegation.state == :revoked
      assert delegation.last_tx_hash == tx_hash
    end

    test "revoke_failed with confirmation_failed (userop_hash only) records the user-op hash" do
      # `confirmation_failed` fires when the bundler accepted the
      # user-op but `waitForUserOperationReceipt` timed out — we have
      # a user-op hash to look up later but no on-chain tx hash yet.
      # Without the fallback, last_tx_hash would be nil and the
      # operator would have no anchor to resume the investigation.
      {:ok, _} = Delegations.grant("sa_aa_pend", "del_aa_pend")
      {:ok, _} = Delegations.record_revoke_requested("sa_aa_pend")

      userop_hash = "0x" <> String.duplicate("cc", 32)

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_aa_pend",
                 "delegation_id" => "del_aa_pend",
                 "state" => "revoke_failed",
                 "reason" => "confirmation_failed: timeout",
                 "tx_refs" => [
                   %{
                     "chain" => "base",
                     "userop_hash" => userop_hash,
                     "nonce" => "0x7",
                     "bundler" => "base-v07-bundler",
                     "status" => "unknown"
                   }
                 ]
               })

      assert delegation.state == :revoke_failed
      assert delegation.last_tx_hash == userop_hash
      refute Delegations.executable?("sa_aa_pend")
    end
  end

  describe "permission artifacts (issue #58)" do
    # ZeroDev permissionId is bytes4; validationId is bytes21
    # (`0x02 ‖ rightPad(permissionId, 20)`). The fixtures below match
    # the on-chain shape exactly so the changeset's byte-size
    # validation has something concrete to check.
    @perm_id <<0xA1, 0xB2, 0xC3, 0xD4>>
    @validation_id <<0x02>> <> @perm_id <> :binary.copy(<<0x00>>, 16)
    @blob_b64 "eyJzZXJpYWxpemVkUGVybWlzc2lvbkFjY291bnQiOiJ0ZXN0In0="
    # 20-byte session-signer EOA hex (0x + 40 hex chars).
    @session_signer "0x" <> String.duplicate("11", 20)

    test "grant accepts permission artifact attrs and persists them verbatim" do
      assert {:ok, d} =
               Delegations.grant("sa_crypto", "0xa1b2c3d4", %{
                 permission_blob: @blob_b64,
                 permission_id: @perm_id,
                 validation_id: @validation_id,
                 kernel_version: "0.3.1",
                 permission_package_version: "5.6.3",
                 installed_at_block: 12_345_678,
                 install_tx_hash: "0xdeadbeef",
                 session_signer_address: @session_signer
               })

      assert d.permission_blob == @blob_b64
      assert d.permission_id == @perm_id
      assert d.validation_id == @validation_id
      assert d.kernel_version == "0.3.1"
      assert d.permission_package_version == "5.6.3"
      assert d.installed_at_block == 12_345_678
      assert d.install_tx_hash == "0xdeadbeef"
      assert d.session_signer_address == @session_signer
    end

    test "grant rejects a permission_id that is not exactly 4 bytes" do
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Delegations.grant("sa_bad_pid", "0xa1b2c3", %{
                 permission_id: <<0xA1, 0xB2, 0xC3>>,
                 validation_id: @validation_id
               })

      assert {:permission_id, {"must be exactly 4 bytes", _}} =
               List.keyfind(errors, :permission_id, 0)
    end

    test "grant rejects a validation_id that is not exactly 21 bytes" do
      # The kernel's `uninstallValidation` takes a `bytes21` argument.
      # A row carrying a 20-byte or 22-byte value would build malformed
      # calldata, so we refuse at the changeset boundary.
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Delegations.grant("sa_bad_vid", "0xa1b2c3d4", %{
                 permission_id: @perm_id,
                 validation_id: :binary.copy(<<0x00>>, 22)
               })

      assert {:validation_id, {"must be exactly 21 bytes", _}} =
               List.keyfind(errors, :validation_id, 0)
    end

    test "cryptographically_revocable?/1 returns true when the complete wire-shape is present" do
      {:ok, d} =
        Delegations.grant("sa_yes", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer
        })

      assert Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when session_signer_address is missing" do
      # Subagent D's security review forces a keyless blob, which
      # means the session-signer EOA must travel separately. Without
      # it the adapter cannot rebuild the stub ModularSigner at
      # revoke-time, so the row is NOT cryptographically revocable.
      {:ok, d} =
        Delegations.grant("sa_partial_signer", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3"
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false on legacy sentinel rows" do
      {:ok, d} = Delegations.grant("sa_legacy", "del_legacy")
      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when blob is missing" do
      {:ok, d} =
        Delegations.grant("sa_partial_blob", "0xa1b2c3d4", %{
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3"
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when permission_id is missing" do
      {:ok, d} =
        Delegations.grant("sa_partial_pid", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3"
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when package version is missing" do
      {:ok, d} =
        Delegations.grant("sa_partial_pkg", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1"
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when validation_id is missing" do
      # The adapter feeds `validation_id` directly to
      # `Kernel.uninstallValidation(...)` as `vId`. Without it the
      # cryptographic revoke cannot run, so the predicate must
      # refuse and let the worker fall back to sentinel.
      {:ok, d} =
        Delegations.grant("sa_partial_vid", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when kernel_version is missing" do
      # The adapter pins kernel_version to deserialize the blob
      # against the right kernel implementation; missing it
      # invalidates the row.
      {:ok, d} =
        Delegations.grant("sa_partial_kv", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when permission_id is the wrong byte size" do
      # `Delegations.grant/3` would refuse to insert a 3-byte
      # permission_id at the changeset boundary. The predicate
      # itself is a defense-in-depth pattern match — hand-construct
      # a struct that bypasses the changeset to confirm the
      # predicate ALSO refuses, so any future schema relaxation
      # cannot silently produce a malformed dispatch block.
      d = %Bank.Delegations.Delegation{
        smart_account_id: "sa_bad_pid_size",
        delegation_id: "0xa1b2c3",
        chain: "base",
        state: :active,
        permission_blob: @blob_b64,
        permission_id: <<0xA1, 0xB2, 0xC3>>,
        validation_id: @validation_id,
        kernel_version: "0.3.1",
        permission_package_version: "5.6.3",
        session_signer_address: @session_signer
      }

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when validation_id is the wrong byte size" do
      # Same defense-in-depth posture: bypass the changeset's
      # byte-size guard to confirm the predicate is independently
      # safe. Kernel.uninstallValidation takes bytes21; a 22-byte
      # value would build malformed calldata.
      d = %Bank.Delegations.Delegation{
        smart_account_id: "sa_bad_vid_size",
        delegation_id: "0xa1b2c3d4",
        chain: "base",
        state: :active,
        permission_blob: @blob_b64,
        permission_id: @perm_id,
        validation_id: :binary.copy(<<0x00>>, 22),
        kernel_version: "0.3.1",
        permission_package_version: "5.6.3",
        session_signer_address: @session_signer
      }

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when session_signer_address is the wrong length" do
      # The wire requires `0x` + 40 hex chars (= 42 bytes UTF-8 in
      # the column). 41 or 43 bytes would fail the adapter's Zod
      # regex anyway, but the predicate refuses up-front so the
      # worker never selects the crypto path with bad input.
      {:ok, d} =
        Delegations.grant("sa_short_signer", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: "0x" <> String.duplicate("11", 19)
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "permission_dispatch_block/1 returns nil when the predicate returns false" do
      # Integration test for the predicate ↔ wire encoder contract:
      # any row that fails `cryptographically_revocable?/1` MUST
      # NOT produce a dispatch block, otherwise the adapter would
      # receive a malformed `permission` payload (Zod would
      # reject, but Phoenix should fail locally first with a
      # deterministic absent-block).
      {:ok, partial} =
        Delegations.grant("sa_partial_disp", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3"
          # session_signer_address intentionally omitted
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(partial)
      assert is_nil(Delegations.permission_dispatch_block(partial))
    end

    test "permission_dispatch_block/1 emits hex-encoded ids, the blob, and the session signer address" do
      {:ok, d} =
        Delegations.grant("sa_disp", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer
        })

      block = Delegations.permission_dispatch_block(d)

      assert block.blob == @blob_b64
      assert block.permission_id == "0xa1b2c3d4"
      # 0x02 ++ permissionId ++ 16 zero bytes → 21 bytes / 42 hex chars.
      assert block.validation_id ==
               "0x02a1b2c3d400000000000000000000000000000000"

      assert block.kernel_version == "0.3.1"
      assert block.package_version == "5.6.3"
      assert block.session_signer_address == @session_signer
    end

    test "permission_dispatch_block/1 returns nil for legacy rows" do
      {:ok, d} = Delegations.grant("sa_legacy_disp", "del_legacy")
      assert is_nil(Delegations.permission_dispatch_block(d))
    end

    test "apply_callback granted with full permission block stores all artifacts decoded from hex" do
      assert {:ok, d} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_cb",
                 "delegation_id" => "0xa1b2c3d4",
                 "state" => "granted",
                 "reason" => "wallet_connect",
                 "permission" => %{
                   "blob" => @blob_b64,
                   "permission_id" => "0xa1b2c3d4",
                   "validation_id" => "0x02a1b2c3d400000000000000000000000000000000",
                   "kernel_version" => "0.3.1",
                   "package_version" => "5.6.3",
                   "session_signer_address" => @session_signer,
                   "installed_at_block" => 12_345_678,
                   "install_tx_hash" => "0xdeadbeef"
                 }
               })

      assert d.state == :active
      assert d.permission_blob == @blob_b64
      assert d.permission_id == @perm_id
      assert d.validation_id == @validation_id
      assert d.kernel_version == "0.3.1"
      assert d.permission_package_version == "5.6.3"
      assert d.session_signer_address == @session_signer
      assert d.installed_at_block == 12_345_678
      assert d.install_tx_hash == "0xdeadbeef"
      assert Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "apply_callback granted without session_signer_address produces a non-revocable row" do
      # Backwards-compat: an adapter that has not been upgraded to
      # emit `session_signer_address` still creates a Phoenix row,
      # but the row is NOT cryptographically revocable. The worker's
      # branch in `permission_dispatch_block/1` keeps such a row on
      # the sentinel revoke path until a future grant repopulates
      # the field.
      assert {:ok, d} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_partial_cb",
                 "delegation_id" => "0xa1b2c3d4",
                 "state" => "granted",
                 "reason" => "wallet_connect",
                 "permission" => %{
                   "blob" => @blob_b64,
                   "permission_id" => "0xa1b2c3d4",
                   "validation_id" => "0x02a1b2c3d400000000000000000000000000000000",
                   "kernel_version" => "0.3.1",
                   "package_version" => "5.6.3"
                 }
               })

      assert d.state == :active
      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
      assert is_nil(d.session_signer_address)
    end

    test "apply_callback granted without permission block keeps row legacy-shaped" do
      # Backward compat: pre-#58 callback fixtures (and the smoke task
      # in v0.1) still send no `permission` key. The row stays on the
      # sentinel revoke path until a future `granted` callback
      # populates the artifacts.
      assert {:ok, d} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_cb_legacy",
                 "delegation_id" => "del_legacy",
                 "state" => "granted",
                 "reason" => "smoke"
               })

      assert d.state == :active
      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end
  end
end
