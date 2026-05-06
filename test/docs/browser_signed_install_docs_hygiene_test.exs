defmodule Docs.BrowserSignedInstallDocsHygieneTest do
  @moduledoc """
  Regression guard for issue #476.

  Pins the browser-signed install smoke runbook + the user-facing
  docs hygiene the epic #471 closeout requires:

    * The smoke runbook exists at the documented path and is
      reviewer-ready (named sections present).
    * No user-facing doc claims the install UserOp is signed
      server-side by `OPERATOR_PRIVATE_KEY`. The legacy mention is
      preserved only on the deeper architecture context that
      explains *why* `OPERATOR_PRIVATE_KEY` exists for legacy
      cryptographic revoke (`docs/security.md`,
      `docs/zerodev-permissions-integration.md`).
    * No doc enables Base mainnet (`chain_id = 8453`) for the
      browser-signed install path. Mainnet readiness runbooks
      (`docs/runbooks/base-mainnet-*`) are intentionally outside
      this guard — they're future planning, not user-facing
      install instructions.
    * The smoke runbook itself does not introduce mainnet language.

  This test does NOT enforce code-level invariants — those live
  on the controller / context / worker test suites. It enforces
  doc claims that operators and reviewers read first.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @runbook Path.join(@repo_root, "docs/runbooks/browser-signed-install-smoke.md")
  @wallet_quickstart Path.join(@repo_root, "docs/wallet-quickstart.md")
  @mvp_readiness Path.join(@repo_root, "docs/mvp-readiness.md")
  @readme Path.join(@repo_root, "README.md")
  @wallet_connect Path.join(@repo_root, "docs/wallet-connect.md")

  describe "smoke runbook (#476)" do
    test "exists at docs/runbooks/browser-signed-install-smoke.md" do
      assert File.exists?(@runbook),
             "browser-signed install smoke runbook missing at #{@runbook}"
    end

    test "has the reviewer-ready section headings" do
      source = File.read!(@runbook)

      for heading <- [
            "# Browser-signed install smoke — Base Sepolia",
            "## Prereqs",
            "## Path A — Phoenix-side state machine smoke",
            "## Path B — Real on-chain end-to-end",
            "## Failure modes the smoke MUST surface",
            "## Audit / replay evidence checklist",
            "## Out of scope"
          ] do
        assert String.contains?(source, heading),
               "smoke runbook missing required heading: #{inspect(heading)}"
      end
    end

    test "names every install endpoint a reviewer must hit" do
      source = File.read!(@runbook)

      for endpoint <- [
            "GET /v1/wallet_bindings/:id/install_envelope",
            "POST /v1/wallet_bindings/:id/install_attestation",
            "GET /v1/wallet_bindings/:id/install_status"
          ] do
        # The runbook may render some occurrences inside curl
        # blocks; just check the literal endpoint string appears
        # at least once.
        assert source =~ endpoint or
                 source =~ String.replace(endpoint, ":id", "<binding_id>"),
               "smoke runbook missing endpoint reference: #{endpoint}"
      end
    end

    test "names every install lifecycle audit event" do
      source = File.read!(@runbook)

      for event <- [
            "delegation.install_envelope_issued",
            "delegation.install_signed_by_user",
            "delegation.install_broadcast",
            "delegation.install_confirmed_onchain",
            "delegation.install_failed"
          ] do
        assert String.contains?(source, event),
               "smoke runbook missing audit event reference: #{event}"
      end
    end

    test "is Base Sepolia only — no Base mainnet (8453) enablement" do
      source = File.read!(@runbook)

      refute source =~ ~r/chain_?id\s*[=:]\s*8453\b/,
             "smoke runbook accidentally enables Base mainnet (chain_id 8453)"

      # The runbook references mainnet only to refuse it as a
      # wrong-chain failure mode. Pin Base Sepolia is the live target.
      assert source =~ "84532",
             "smoke runbook does not name Base Sepolia (84532) as the target chain"
    end

    test "documents the pinned failure-category allowlist" do
      source = File.read!(@runbook)

      for category <- [
            "user_rejected",
            "bundler_rejected",
            "bundler_unavailable",
            "chain_id_mismatch",
            "insufficient_funds",
            "userop_reverted",
            "attestation_timeout",
            "unknown"
          ] do
        assert String.contains?(source, category),
               "smoke runbook missing failure category: #{category}"
      end
    end

    test "names the on-chain verifier worker + the active-state invariant" do
      source = File.read!(@runbook)

      assert source =~ "Bank.Runtime.Workers.VerifyInstallOnchain",
             "smoke runbook does not name the on-chain verifier worker"

      assert source =~ ~r/(NOT|never).*\bmark.*:active\b/i or
               source =~ ~r/Phoenix.*only.*marks.*\bactive\b.*after/i,
             "smoke runbook does not pin that Phoenix marks :active only after on-chain verification"
    end
  end

  describe "user-facing docs no longer claim server-signed normal install" do
    test "wallet-quickstart.md does not say install UserOp is server-signed" do
      source = File.read!(@wallet_quickstart)

      refute source =~ ~r/install\s+UserOp[^\n]{0,80}signed\s+server-side/i,
             "wallet-quickstart.md still claims the install UserOp is signed server-side"

      refute source =~ ~r/install[^\n]{0,80}signed.*OPERATOR_PRIVATE_KEY/i,
             "wallet-quickstart.md still attributes install signing to OPERATOR_PRIVATE_KEY"
    end

    test "README.md does not say install UserOp is server-signed" do
      source = File.read!(@readme)

      refute source =~ ~r/install\s+UserOp[^\n]{0,80}signed\s+server-side/i,
             "README.md still claims the install UserOp is signed server-side"
    end

    test "wallet-connect.md does not say install UserOp is server-signed" do
      source = File.read!(@wallet_connect)

      refute source =~ ~r/install\s+UserOp[^\n]{0,80}signed\s+server-side/i,
             "wallet-connect.md still claims the install UserOp is signed server-side"
    end
  end

  describe "mvp-readiness.md reflects browser-signed install (#471)" do
    test "names the epic #471 + the on-chain verifier worker" do
      source = File.read!(@mvp_readiness)

      assert source =~ "epic #471" or source =~ "#471",
             "mvp-readiness.md does not reference epic #471"

      assert source =~ "VerifyInstallOnchain",
             "mvp-readiness.md does not reference the on-chain verifier worker"
    end

    test "documents the v0.1 sentinel revoke posture for user-rooted rows (#475)" do
      source = File.read!(@mvp_readiness)

      assert source =~ "sentinel" and source =~ "#475",
             "mvp-readiness.md does not document the #475 sentinel revoke posture for browser-signed delegations"
    end
  end
end
