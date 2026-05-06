defmodule Docs.Runbooks.BrowserSignedInstallTest do
  @moduledoc """
  Docs-pin describe block for `docs/runbooks/browser-signed-install.md`
  (#476) and the no-stale-claim invariant on the surrounding docs.

  The browser-signed install path is the load-bearing
  non-custodial guarantee for v0.1. A docs drift that re-asserts
  "the install UserOp is signed server-side by
  `OPERATOR_PRIVATE_KEY`" on the **normal** install path would
  silently revert the launch claim. This test makes that drift
  impossible to merge.

  Mirrors `Docs.Runbooks.MultiAccountTest`.
  """

  use ExUnit.Case, async: true

  @docs_root Path.expand("../../../docs", __DIR__)
  @runbook Path.join(@docs_root, "runbooks/browser-signed-install.md")

  describe "docs/runbooks/browser-signed-install.md (#476)" do
    setup do
      assert File.exists?(@runbook),
             "browser-signed install runbook missing at #{@runbook}"

      {:ok, contents: File.read!(@runbook)}
    end

    test "is Sepolia-only and never claims mainnet support", %{contents: contents} do
      assert contents =~ "Base Sepolia", "runbook must call out Base Sepolia"
      assert contents =~ "84532", "runbook must name Sepolia chain id"

      refute contents =~ ~r/(?<![\w-])mainnet support(?![\w-])/i,
             "runbook must not claim mainnet support"

      refute contents =~ ~r/chain[_ ]?id[:= ]+8453(?![\d])/i,
             "runbook must not advertise the Base mainnet chain id (8453)"
    end

    test "states no operator/server key signs the normal install", %{
      contents: contents
    } do
      assert contents =~ ~r/no\s+server\s*\/?\s*operator\s+key/i or
               contents =~ ~r/no\s+(server|operator)\s+key\s+(signs|participates)/i,
             "runbook must explicitly state no server/operator key signs the install"

      assert contents =~ "ZeroDev SDK",
             "runbook must name the ZeroDev SDK as the browser-side signer"

      assert contents =~ "wallet signs",
             "runbook must say the wallet signs"

      refute contents =~
               ~r/install\s+UserOp(?:eration)?\s+is\s+signed\s+server[- ]side/i,
             "runbook must not describe the normal install as server-signed"
    end

    test "documents visible-fail check for wrong-chain", %{contents: contents} do
      assert contents =~ ~r/wrong[- ]chain/i,
             "runbook must document the wrong-chain failure"

      assert contents =~ "wallet-status-wrong-chain",
             "runbook must point at the LiveView's wrong-chain DOM id"

      assert contents =~ "Switch to Base Sepolia",
             "runbook must specify the wrong-chain operator copy"
    end

    test "documents visible-fail check for user rejection", %{contents: contents} do
      assert contents =~ ~r/user[_ ]rejected/i,
             "runbook must document the user_rejected failure category"

      assert contents =~ "delegation.install_failed",
             "runbook must reference the install_failed audit event"

      assert contents =~ "Wallet rejected",
             "runbook must specify the user-rejection operator copy"
    end

    test "documents visible-fail check for missing on-chain verification", %{
      contents: contents
    } do
      assert contents =~ "VerifyInstallOnchain",
             "runbook must reference the on-chain verifier worker"

      assert contents =~ "onchain_verification_unreachable",
             "runbook must document the verifier-unreachable reason"

      assert contents =~ "MUST NOT flip",
             "runbook must explicitly forbid the :active transition without the verifier"
    end

    test "documents visible-fail check for malicious browser", %{contents: contents} do
      assert contents =~ "onchain_state_mismatch",
             "runbook must document the on-chain state-mismatch reason"

      assert contents =~ ~r/malicious browser/i,
             "runbook must call out the malicious-browser scenario"
    end

    test "names every audit event in the install lifecycle", %{contents: contents} do
      for event <- [
            "delegation.connect_requested",
            "delegation.identity_bound",
            "delegation.install_envelope_issued",
            "delegation.install_signed_by_user",
            "delegation.install_broadcast",
            "delegation.install_confirmed_onchain"
          ] do
        assert contents =~ event,
               "runbook missing audit event #{event}"
      end
    end

    test "lists every failure category from the BrowserInstall allowlist", %{
      contents: contents
    } do
      for category <-
            Bank.SessionPermissions.BrowserInstall.failure_categories()
            |> Enum.map(&Atom.to_string/1) do
        assert contents =~ category,
               "runbook missing failure category #{category}"
      end
    end

    test "names the canonical /v1 endpoints the browser hits", %{contents: contents} do
      assert contents =~ "install_envelope",
             "runbook must mention the install_envelope endpoint"

      assert contents =~ "install_attestation",
             "runbook must mention the install_attestation endpoint"

      assert contents =~ "install_status",
             "runbook must mention the install_status endpoint"
    end

    test "includes recovery guidance section", %{contents: contents} do
      assert contents =~ ~r/^##\s+Recovery guidance/m,
             "runbook must include a 'Recovery guidance' H2 section"
    end
  end

  describe "no-stale-claim invariant on browser-install docs (#476)" do
    @stale_claim_files [
      {"docs/wallet-quickstart.md", &__MODULE__.read_wallet_quickstart/0},
      {"docs/mvp-readiness.md", &__MODULE__.read_mvp_readiness/0},
      {"docs/wallet-connect.md", &__MODULE__.read_wallet_connect/0}
    ]

    test "no doc claims the normal install UserOp is signed server-side" do
      for {label, reader} <- @stale_claim_files do
        contents = reader.()

        refute contents =~
                 ~r/install\s+UserOp(?:eration)?\s+is\s+(?:still\s+)?signed\s+server[- ]side/i,
               """
               Stale claim re-introduced in #{label}: the doc once again describes the
               normal install UserOperation as server-signed. The browser-signed install
               (epic #471) makes this false. If you are documenting the legacy fallback,
               qualify it with "legacy" / "operator-signed delegations" / a clear
               distinction from the default browser-signed path.
               """

        refute contents =~
                 ~r/the\s+(?:adapter|server)\s+signs\s+the\s+install\s+UserOp/i,
               "Stale claim re-introduced in #{label}: the doc says the adapter/server signs the install UserOp."
      end
    end

    test "wallet-quickstart points at the new browser-install runbook" do
      contents = read_wallet_quickstart()

      assert contents =~ "runbooks/browser-signed-install.md",
             "wallet-quickstart must link to the new reviewer-grade smoke runbook"
    end

    test "mvp-readiness names the browser-signed install path as the default" do
      contents = read_mvp_readiness()

      assert contents =~ "Browser-signed install",
             "mvp-readiness must name the browser-signed install"

      assert contents =~ "VerifyInstallOnchain",
             "mvp-readiness must reference the on-chain verifier worker"

      assert contents =~ "delegation.install_confirmed_onchain",
             "mvp-readiness must reference the install_confirmed_onchain audit event"
    end
  end

  # File reader helpers (closures-as-args don't compose well with @attrs).

  @doc false
  def read_wallet_quickstart do
    File.read!(Path.expand("../../../docs/wallet-quickstart.md", __DIR__))
  end

  @doc false
  def read_mvp_readiness do
    File.read!(Path.expand("../../../docs/mvp-readiness.md", __DIR__))
  end

  @doc false
  def read_wallet_connect do
    File.read!(Path.expand("../../../docs/wallet-connect.md", __DIR__))
  end
end
