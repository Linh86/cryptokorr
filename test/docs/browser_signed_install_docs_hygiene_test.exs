defmodule Docs.BrowserSignedInstallDocsHygieneTest do
  @moduledoc """
  Regression guard for the browser-signed install smoke runbook +
  surrounding user-facing docs.

  Originally landed under #476; extended under #502 with explicit
  anti-stale-language assertions so the launch-track wire-up
  (#500 backend session-auth + receipt poller, #501 frontend
  ZeroDev SDK + bundler) cannot leave behind stale "synthetic
  setTimeout" / "v0.2 follow-up" / "fake bundler confirmation" /
  server-signed-normal-install language in the runbook or in the
  docs operators read first.

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
            "## Path A — Real automated browser install",
            "## Path B — Manual on-chain end-to-end (escape hatch)",
            "## Failure modes the smoke MUST surface",
            "## Recovery guidance",
            "## Audit / replay evidence checklist",
            "## Preflight task",
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
               source =~ ~r/Phoenix.*only.*marks.*\bactive\b.*after/i or
               source =~ ~r/sole writer of the .:active. transition/i,
             "smoke runbook does not pin that Phoenix marks :active only after on-chain verification"
    end

    test "Path B remains documented as the manual reviewer escape hatch" do
      source = File.read!(@runbook)

      assert source =~ ~r/Path B.*Manual on-chain end-to-end/i,
             "smoke runbook lost the Path B manual reviewer escape hatch heading"

      assert source =~ "cast send" or source =~ "dev tools console",
             "Path B no longer documents either the cast or the dev-console reviewer route"
    end

    test "names the preflight Mix task" do
      source = File.read!(@runbook)

      assert source =~ "mix bank.browser_install.smoke",
             "smoke runbook does not name the mix bank.browser_install.smoke preflight task"

      assert source =~ ~r/preflight[- ]only|does not sign|does not broadcast|never.*broadcast/i,
             "smoke runbook does not state the preflight task is preflight-only / non-signing"
    end

    test "describes a real automated browser install on the Path A success path (#502)" do
      source = File.read!(@runbook)

      # Path A's success path must describe the real automated
      # flow, not the deliberate-failure walk-through that #476
      # shipped while the JS hook was still synthetic. The
      # presence of any of these phrases anywhere in the runbook
      # would be a regression to the pre-#502 state.
      stale_phrases = [
        "synthetic confirmation",
        "synthesises the bundler",
        "synthesises the .submitted",
        "stand-in for the bundler",
        ~r/window\.setTimeout.*synthet/i,
        ~r/Real ZeroDev SDK.*v0\.2 follow-up/i,
        ~r/v0\.2 follow-up.*ZeroDev SDK/i,
        ~r/SDK.*deferred/i
      ]

      for phrase <- stale_phrases do
        case phrase do
          %Regex{} = re ->
            refute Regex.match?(re, source),
                   "runbook still carries stale Path A synthetic-confirmation language matching #{inspect(re)}"

          str when is_binary(str) ->
            refute String.contains?(source, str),
                   "runbook still carries stale Path A synthetic-confirmation phrase: #{inspect(str)}"
        end
      end

      # Pin the new Path A wording explicitly.
      assert source =~ ~r/^## Path A — Real automated browser install/m,
             "Path A heading does not describe the real automated browser install"

      assert source =~ "ZeroDev SDK",
             "Path A no longer references the ZeroDev SDK as the browser-side signer"

      assert source =~ "wallet popup" or source =~ "wallet pop-up",
             "Path A no longer describes the wallet pop-up moment"
    end

    test "anti-stale-claim assertions for the install path (#502)" do
      source = File.read!(@runbook)

      # No production claim that setTimeout drives the install
      # confirmation. Hard refuse — even the legacy mention must
      # be reframed as historical / non-launch.
      refute source =~ ~r/window\.setTimeout.*confirm/i,
             "runbook claims `window.setTimeout` is the install-confirmation path; that contradicts the launch posture"

      # No claim that any server / operator key signs the normal
      # install. Mentions of OPERATOR_PRIVATE_KEY must be scoped
      # to legacy-revoke / Path B `cast` callouts.
      refute source =~
               ~r/OPERATOR_PRIVATE_KEY[^\n]{0,80}(install|sign[^\n]{0,40}install)/i,
             "runbook attributes install signing to OPERATOR_PRIVATE_KEY"

      # No claim that the install confirmation is fake / mocked /
      # simulated as the launch path.
      refute source =~ ~r/(fake|mock|simulated)\s+(bundler|confirmation|userop|receipt)/i,
             "runbook claims the launch path uses a fake/mock/simulated bundler confirmation"

      # Defense-in-depth: refuse the literal v0.2 phrasing about
      # the install-signing path. Other v0.2 callouts (cryptographic
      # revoke, per-policy encoding) live in 'Out of scope'.
      refute source =~ ~r/install[^\n]{0,80}v0\.2 follow-up/i,
             "runbook describes the install signing path as a v0.2 follow-up"
    end

    test "names the launch-track issues #500, #501, #502" do
      source = File.read!(@runbook)

      for issue <- ["#500", "#501", "#502"] do
        assert source =~ issue,
               "runbook does not reference launch-track issue #{issue}"
      end
    end

    test "no longer carries the conditional 'if either is still open' launch-lane language (#506)" do
      # #500 and #501 closed before #506; the runbook MUST NOT
      # carry conditional language that frames Path A as
      # contingent on those issues. Path A is the shipped path on
      # `main`; Path B is the fallback / debug / escape hatch.
      source = File.read!(@runbook)

      stale_phrases = [
        "if either is still open",
        "#500/#501 are still open",
        "#500 / #501 are still open",
        "three open issues finalise",
        "only path to a real `:active` row is Path B",
        "only path to a real :active row is Path B",
        "JS hook ships the #473 scaffold",
        "(backend launch lane)",
        "(frontend launch lane)"
      ]

      for phrase <- stale_phrases do
        refute String.contains?(source, phrase),
               "runbook still carries stale conditional launch-lane phrase: #{inspect(phrase)}"
      end
    end

    test "frames Path B as fallback / debug / escape hatch, not the only real path (#506)" do
      source = File.read!(@runbook)

      # Pin that Path B is described as the fallback / debug
      # route. A future regression that re-promotes Path B to
      # "only real path" must fail this test.
      refute source =~ ~r/Path B[^\n]{0,40}only[^\n]{0,40}real/i,
             "runbook re-promotes Path B as the 'only real' path"

      assert source =~ ~r/Path B[^\n]{0,80}(escape[- ]hatch|fallback|debug|manual)/i,
             "runbook does not describe Path B as fallback / debug / manual / escape hatch"
    end

    test "Path A is described as shipped on `main`, not as a future / pending merge (#506)" do
      source = File.read!(@runbook)

      # Look for explicit "shipped on `main`" or equivalent
      # current-state language near the Path A heading.
      assert source =~ ~r/Path A[^\n]{0,400}shipped|shipped[^\n]{0,400}Path A/i or
               source =~ ~r/launch path[^\n]{0,200}shipped on `main`/i,
             "runbook does not describe Path A as shipped on `main`"

      # Defense-in-depth: refuse "Requires the merged PRs for"
      # which previously framed Path A as conditional on open
      # dependencies.
      refute source =~ ~r/Requires the merged PRs for #500 and #501/,
             "runbook still frames Path A as 'requires the merged PRs for #500 and #501'"
    end

    test "has a Recovery guidance section operators can act on" do
      source = File.read!(@runbook)

      for cue <- [
            "Recovery guidance",
            ":install_failed",
            ":pending"
          ] do
        assert String.contains?(source, cue),
               "runbook recovery section missing cue: #{inspect(cue)}"
      end
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

    test "wallet-quickstart.md no longer carries the v0.2 setTimeout 'Honest gap' callout (#502)" do
      source = File.read!(@wallet_quickstart)

      refute source =~ ~r/Honest gap.*v0\.2 follow-up/i,
             "wallet-quickstart.md still carries the pre-#502 'Honest gap (v0.2 follow-up)' callout"

      refute source =~ ~r/setTimeout[^\n]{0,80}stand[- ]in/i,
             "wallet-quickstart.md still describes the install confirmation as a setTimeout stand-in"
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

    test "no longer carries the pre-#502 setTimeout 'Honest gap inside #471' bullet" do
      source = File.read!(@mvp_readiness)

      refute source =~ ~r/Honest gap inside #471/,
             "mvp-readiness.md still carries the pre-#502 'Honest gap inside #471' bullet"

      refute source =~ ~r/setTimeout[^\n]{0,200}v0\.2 follow-up/i,
             "mvp-readiness.md still describes the install confirmation as a v0.2 setTimeout follow-up"
    end

    test "names the launch-track issues #500, #501, #502 (#502)" do
      source = File.read!(@mvp_readiness)

      for issue <- ["#500", "#501", "#502"] do
        assert source =~ issue,
               "mvp-readiness.md does not reference launch-track issue #{issue}"
      end
    end

    test "no longer carries the 'three open issues finalise' conditional language (#506)" do
      # By #506 close, all three (#500/#501/#502) are merged on
      # `main`. The MVP readiness doc must reflect shipped state,
      # not pending-launch language.
      source = File.read!(@mvp_readiness)

      stale_phrases = [
        "Three\n  open issues finalise",
        "Three open issues finalise",
        "three open issues finalise",
        "When all three merge on `main`",
        "Until then, the reviewer escape hatch is Path B"
      ]

      for phrase <- stale_phrases do
        refute String.contains?(source, phrase),
               "mvp-readiness.md still carries stale launch-lane phrase: #{inspect(phrase)}"
      end
    end

    test "frames the browser-signed install as shipped on `main` (#506)" do
      source = File.read!(@mvp_readiness)

      assert source =~ ~r/(shipped|launched)[^\n]{0,80}on `main`/i or
               source =~ ~r/launch[^\n]{0,80}shipped on `main`/i,
             "mvp-readiness.md does not state the browser-signed install is shipped on `main`"
    end

    test "preserves post-MVP hardening caveats (#506)" do
      # Post-MVP follow-ups must remain visible so the readiness
      # doc stays honest.
      source = File.read!(@mvp_readiness)

      for cue <- [
            "browser-signed cryptographic revoke",
            "per-policy on-chain",
            "wallet-provider"
          ] do
        assert String.contains?(source, cue),
               "mvp-readiness.md missing post-MVP caveat cue: #{inspect(cue)}"
      end
    end
  end
end
