defmodule Bank.Smoke.WalletQuickstartDocTest do
  @moduledoc """
  Drift guard for `docs/wallet-quickstart.md` (#172).

  Pins the docs against the MVP contract: every section the issue
  acceptance calls out is present, and none of the banned claims
  (mainnet, paymaster promise, multi-account, arbitrary contract,
  unlimited token, Morpho withdraw / borrow / leverage, browser
  private-key paste) leak in.

  Pairs with the local mocked smoke in
  `Bank.Smoke.WalletDelegationSmokeTest`.
  """

  use ExUnit.Case, async: true

  @doc_path Path.expand("../../../docs/wallet-quickstart.md", __DIR__)

  setup_all do
    {:ok, body: File.read!(@doc_path)}
  end

  test "exists at the expected path" do
    assert File.exists?(@doc_path), "wallet quickstart missing at #{@doc_path}"
  end

  describe "structure" do
    test "names every required section", %{body: body} do
      for section <- [
            "## Scope",
            "## Before you start",
            "## Walkthrough",
            "## Permission scope",
            "## Troubleshooting",
            "## Security guarantees",
            "## Local mocked smoke",
            "## Live Base Sepolia smoke",
            "## CLI / headless setup is a dev fallback only"
          ] do
        assert body =~ section, "wallet quickstart missing section #{section}"
      end
    end

    test "walks Connect → Bind → Install → Run → Revoke", %{body: body} do
      for step <- [
            "Open the connection page",
            "Connect",
            "Sign the binding challenge",
            "Review the permission scope",
            "Install",
            "Run an intent",
            "Revoke"
          ] do
        assert body =~ step, "walkthrough missing step: #{step}"
      end
    end
  end

  describe "MVP scoping" do
    test "names Base Sepolia (84532) as the only chain", %{body: body} do
      assert body =~ "Base Sepolia"
      assert body =~ "84532"
    end

    test "calls out Base mainnet as post-MVP wrong-chain", %{body: body} do
      assert body =~ "Base mainnet (8453)"
      assert body =~ "post-MVP"

      assert body =~ ~r/(mainnet|8453).+post-MVP/s,
             "doc must explicitly defer Base mainnet (8453) as post-MVP"
    end

    test "names every troubleshooting failure mode the issue calls out", %{body: body} do
      for clue <- [
            "wrong chain",
            "wallet extension installed",
            "rejected the binding signature",
            "Adapter / bundler failure",
            "permission_install_failed",
            "Revoke attempt fails",
            "Delegation is revoked or expired"
          ] do
        assert body =~ clue, "troubleshooting matrix missing: #{clue}"
      end
    end
  end

  describe "permission scope plain language" do
    test "lists all three allowed actions", %{body: body} do
      assert body =~ "usdc_transfer"
      assert body =~ "zero_x_swap"
      assert body =~ "morpho_4626_deposit"
      assert body =~ "Transfer USDC"
      assert body =~ "0x"
      assert body =~ "Morpho"
    end

    test "lists all five denied actions", %{body: body} do
      assert body =~ "withdraw_redeem"
      assert body =~ "arbitrary_calldata"
      assert body =~ "unlimited_approvals"
      assert body =~ "borrow_leverage"
      assert body =~ ~r/^\| `mainnet`/m
    end
  end

  describe "security guarantees" do
    test "promises no private-key paste", %{body: body} do
      assert body =~ ~r/no private-?key paste/i
      assert body =~ ~r/never\s+(asks|receives|stores)/i
    end

    test "names personal_sign as the only browser signing primitive", %{body: body} do
      assert body =~ "personal_sign"

      assert body =~ ~r/eth_signTransaction/,
             "doc must explicitly call out the forbidden signing methods"

      assert body =~ ~r/eth_signTypedData/,
             "doc must explicitly call out the forbidden signing methods"
    end
  end

  describe "banned claims" do
    test "does not promise paymaster / sponsored gas", %{body: body} do
      # The doc may *deny* paymaster — we want to forbid promising it.
      refute body =~ ~r/paymaster (covers|sponsors|funds) gas/i
      refute body =~ ~r/sponsored gas (is|will be) (provided|available)/i
    end

    test "does not promise multi-account / multi-tenant", %{body: body} do
      refute body =~ "multi-account selector"
      refute body =~ "multi-tenant"
      refute body =~ "switch workspace"
      refute body =~ ~r/multi-account support/i
    end

    test "does not promise arbitrary contract calls", %{body: body} do
      refute body =~ ~r/agent can call any contract/i
      refute body =~ ~r/arbitrary contract calls? (are|is) (allowed|supported)/i
    end

    test "does not promise unlimited token spend", %{body: body} do
      refute body =~ ~r/unlimited token (spend|approval) (is|will be) (granted|allowed)/i
    end

    test "does not promise Morpho withdraw / borrow / leverage", %{body: body} do
      refute body =~ ~r/Morpho withdraw (is|will be) (allowed|supported|granted)/i
      refute body =~ ~r/agent can withdraw from Morpho/i
      refute body =~ ~r/borrow (is|will be) (allowed|supported)/i
    end

    test "does not instruct the user to paste a private key into the browser or Phoenix",
         %{body: body} do
      # The doc legitimately uses "pasting a private key into the
      # browser or Phoenix" as something we never do — that's a
      # denial, not an instruction. The forbidden patterns are
      # imperatives ("Paste …") or capability claims ("you can
      # paste …"), not denials.
      refute body =~ ~r/^(?:Step \d+\.\s+)?Paste (your |the )?private key/im
      refute body =~ ~r/you can paste (your |the )?private key/i
      refute body =~ ~r/copy your private key/i
    end
  end

  describe "cross-links" do
    test "links to wallet-connect.md, mvp-smoke-runbook.md, operator-secrets-checklist.md", %{
      body: body
    } do
      assert body =~ "wallet-connect.md"
      assert body =~ "mvp-smoke-runbook.md"
      assert body =~ "operator-secrets-checklist.md"
    end

    test "names Bank.WalletBindings, Bank.SessionPermissions, Bank.Delegations", %{body: body} do
      assert body =~ "Bank.WalletBindings"
      assert body =~ "Bank.SessionPermissions"
      assert body =~ "Bank.Delegations"
    end
  end
end
