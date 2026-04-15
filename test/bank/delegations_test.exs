defmodule Bank.DelegationsTest do
  use ExUnit.Case, async: false

  alias Bank.Delegations

  setup do
    Delegations.reset()
    :ok
  end

  describe "grant/2" do
    test "registers an active delegation" do
      assert {:ok, record} =
               Delegations.grant("sa_1",
                 counterparty_id: "cp_1",
                 scope: %{"asset" => "USDC"}
               )

      assert record.state == :active
      assert record.counterparty_id == "cp_1"
      assert record.scope == %{"asset" => "USDC"}
      assert %DateTime{} = record.granted_at
    end

    test "replaces an existing delegation (re-grant after revoke)" do
      {:ok, _} = Delegations.grant("sa_1", counterparty_id: "cp_1")
      {:ok, _} = Delegations.record_revoked("sa_1")
      assert %{state: :revoked} = Delegations.get("sa_1")

      {:ok, re} = Delegations.grant("sa_1", counterparty_id: "cp_1")
      assert re.state == :active
      assert is_nil(re.revoked_at)
    end
  end

  describe "revoke flow" do
    test "revoke_requested → revoked" do
      {:ok, _} = Delegations.grant("sa_1")

      assert {:ok, %{state: :revoking, revoke_requested_at: %DateTime{}}} =
               Delegations.record_revoke_requested("sa_1", reason: :operator_requested)

      assert {:ok, %{state: :revoked, revoked_at: %DateTime{}}} =
               Delegations.record_revoked("sa_1")
    end

    test "revoke on unknown smart account returns :not_found" do
      assert {:error, :not_found} = Delegations.record_revoke_requested("sa_missing")
      assert {:error, :not_found} = Delegations.record_revoked("sa_missing")
    end
  end

  describe "expiry" do
    test "record_expired marks delegation :expired" do
      {:ok, _} = Delegations.grant("sa_1")
      assert {:ok, %{state: :expired}} = Delegations.record_expired("sa_1")
    end
  end

  describe "executable?/2" do
    test "true only for active + non-expired" do
      now = ~U[2026-04-15 12:00:00Z]

      {:ok, _} = Delegations.grant("sa_never_expires", granted_at: now)
      assert Delegations.executable?("sa_never_expires", now)

      {:ok, _} =
        Delegations.grant("sa_future", granted_at: now, expires_at: ~U[2026-04-16 12:00:00Z])

      assert Delegations.executable?("sa_future", now)

      {:ok, _} =
        Delegations.grant("sa_past", granted_at: now, expires_at: ~U[2026-04-15 11:00:00Z])

      refute Delegations.executable?("sa_past", now)
    end

    test "false for revoking, revoked, expired, and missing" do
      {:ok, _} = Delegations.grant("sa_r1")
      {:ok, _} = Delegations.record_revoke_requested("sa_r1")
      refute Delegations.executable?("sa_r1")

      {:ok, _} = Delegations.grant("sa_r2")
      {:ok, _} = Delegations.record_revoked("sa_r2")
      refute Delegations.executable?("sa_r2")

      {:ok, _} = Delegations.grant("sa_e1")
      {:ok, _} = Delegations.record_expired("sa_e1")
      refute Delegations.executable?("sa_e1")

      refute Delegations.executable?("sa_ghost")
    end
  end
end
