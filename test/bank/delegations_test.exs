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

    test "revoke on unknown smart account returns :not_found" do
      assert {:error, :not_found} = Delegations.record_revoke_requested("sa_missing")
      assert {:error, :not_found} = Delegations.record_revoked("sa_missing")
    end

    test "revoke on already-revoked delegation returns :not_found" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoked("sa_1")

      # get/1 returns nil for terminal states, so this is :not_found
      assert {:error, :not_found} = Delegations.record_revoke_requested("sa_1")
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
end
