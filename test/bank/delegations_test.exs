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
end
