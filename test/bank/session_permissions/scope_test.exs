defmodule Bank.SessionPermissions.ScopeTest do
  @moduledoc """
  Pins the canonical scope summary that the browser flow consents to
  and that `Bank.SessionPermissions.request_install/2` stamps onto
  the delegation row.

  Future PRs that widen the agent's permission must update this
  test alongside the scope module — the explicit denied list is the
  failsafe for "no withdraw in agent permission".
  """

  use ExUnit.Case, async: true

  alias Bank.SessionPermissions.Scope

  describe "default/0" do
    test "pins MVP version, kernel version, and chain id" do
      scope = Scope.default()
      assert scope["version"] == "1"
      assert scope["kernel_version"] == "v3.1"
      assert scope["chain_id"] == 84_532
    end

    test "lists USDC transfer, 0x swap, and Morpho deposit as allowed" do
      kinds =
        Scope.default()
        |> Map.fetch!("allowed")
        |> Enum.map(& &1["kind"])

      assert "usdc_transfer" in kinds
      assert "zero_x_swap" in kinds
      assert "morpho_4626_deposit" in kinds
    end

    test "every allowed action is policy-gated by Phoenix" do
      Scope.default()
      |> Map.fetch!("allowed")
      |> Enum.each(fn action ->
        assert action["policy_gated"] == true,
               "expected #{action["kind"]} to be policy_gated"
      end)
    end

    test "explicitly denies withdraw, arbitrary calldata, mainnet, leverage" do
      kinds =
        Scope.default()
        |> Map.fetch!("denied")
        |> Enum.map(& &1["kind"])

      assert "withdraw_redeem" in kinds
      assert "arbitrary_calldata" in kinds
      assert "unlimited_approvals" in kinds
      assert "borrow_leverage" in kinds
      assert "mainnet" in kinds
    end
  end

  describe "allowed/0 + denied/0" do
    test "every allowed action has a label and a rationale" do
      Enum.each(Scope.allowed(), fn action ->
        assert is_binary(action["label"]) and action["label"] != ""
        assert is_binary(action["rationale"]) and action["rationale"] != ""
      end)
    end

    test "every denied action has a label" do
      Enum.each(Scope.denied(), fn denied ->
        assert is_binary(denied["label"]) and denied["label"] != ""
      end)
    end
  end

  describe "chain_id/0" do
    test "pins Base Sepolia for the MVP" do
      assert Scope.chain_id() == 84_532
    end
  end

  describe "audit_summary/0" do
    test "exposes only public scope fields (no signer keys, no nonces)" do
      summary = Scope.audit_summary()

      assert Map.has_key?(summary, "version")
      assert Map.has_key?(summary, "kernel_version")
      assert Map.has_key?(summary, "chain_id")
      assert Map.has_key?(summary, "allowed")
      assert Map.has_key?(summary, "denied")

      # No private-key, signature, or nonce shaped keys.
      refute Map.has_key?(summary, "private_key")
      refute Map.has_key?(summary, "signature")
      refute Map.has_key?(summary, "nonce")
      refute Map.has_key?(summary, "session_signer_key")
    end
  end
end
