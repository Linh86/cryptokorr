defmodule Docs.Runbooks.MultiAccountTest do
  @moduledoc """
  Docs-pin describe block for `docs/runbooks/multi-account.md` (#187).

  Mirrors the precedent set by
  `Mix.Tasks.Bank.Chain.Mainnet.PreflightTest`'s
  `describe "docs/runbooks/base-mainnet-rehearsal.md (#180)"`
  block: every load-bearing claim the runbook makes is pinned by
  one assertion in this file so a docs drift cannot silently
  unship the v0.1 multi-account isolation contract.
  """

  use ExUnit.Case, async: true

  @runbook_path Path.expand(
                  "../../../docs/runbooks/multi-account.md",
                  __DIR__
                )

  describe "docs/runbooks/multi-account.md (#187)" do
    test "exists at the expected path" do
      assert File.exists?(@runbook_path),
             "multi-account runbook missing at #{@runbook_path}"
    end

    test "is explicit about the v0.1 single-active-delegation reality" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/single[- ]active[- ]delegation/i,
             "runbook missing the 'single-active-delegation' v0.1 reality statement"

      assert contents =~ ~r/v0\.1/,
             "runbook missing the explicit v0.1 callout"

      assert contents =~ "delegations_smart_account_active_idx",
             "runbook missing the partial unique index that enforces the single-active rule"

      assert contents =~ ~r/at most one non[- ]terminal/i,
             "runbook missing the 'at most one non-terminal row per smart account' invariant"
    end

    test "names every workspace-scoped surface" do
      contents = File.read!(@runbook_path)

      # The five workspace-scoped surfaces. The runbook must name
      # each one explicitly so an operator reading the runbook
      # alone can audit isolation surface-by-surface.
      surfaces = [
        # intents
        ~r/intents?/i,
        # decisions / decision envelopes
        ~r/decision\s+envelopes?/i,
        # execution plans
        ~r/execution\s+plans?/i,
        # delegations
        ~r/delegations?/i,
        # audit events
        ~r/audit\s+events?/i
      ]

      for surface_re <- surfaces do
        assert contents =~ surface_re,
               "runbook missing surface match for #{inspect(surface_re)}"
      end

      # The five context columns themselves — these are the
      # technical anchor points for an auditor.
      assert contents =~ "agent_intents.workspace_id",
             "runbook missing agent_intents.workspace_id"

      assert contents =~ "execution_plans.workspace_id",
             "runbook missing execution_plans.workspace_id"

      assert contents =~ "delegations.workspace_id",
             "runbook missing delegations.workspace_id"

      assert contents =~ "audit_events.workspace_id",
             "runbook missing audit_events.workspace_id"
    end

    test "is honest about the deferred multi-account model (#183-#186)" do
      contents = File.read!(@runbook_path)

      assert contents =~ "#183",
             "runbook missing reference to deferred multi-account issue #183"

      assert contents =~ "#184",
             "runbook missing reference to deferred multi-account issue #184"

      assert contents =~ "#185",
             "runbook missing reference to deferred multi-account issue #185"

      assert contents =~ "#186",
             "runbook missing reference to deferred multi-account issue #186"

      assert contents =~ ~r/deferred/i,
             "runbook missing the 'deferred' callout for the future multi-account model"
    end

    test "documents the cross-workspace dispatch refusal failure mode" do
      contents = File.read!(@runbook_path)

      # A plan in workspace A whose smart_account_id targets a
      # foreign account must never dispatch. The runbook must
      # both name the failure mode and pin the gate that catches
      # it.
      assert contents =~ ~r/Delegations\.executable\?/,
             "runbook missing the executable? gate that catches cross-account dispatch"

      assert contents =~ "delegation_not_active",
             "runbook missing the documented final_reason for the dispatch-side gate"

      assert contents =~ "Bank.AdapterClient",
             "runbook missing the 'no adapter call' guarantee for the dispatch-side gate"
    end

    test "documents the revoke-mid-flight failure mode" do
      contents = File.read!(@runbook_path)

      assert contents =~
               ~r/(revoked between plan creation|revoke[- ]mid[- ]flight|between plan creation and dispatch)/i,
             "runbook missing the revoke-mid-flight failure mode"

      assert contents =~ ~r/RunExecution(\.verify_delegation\/1)?/,
             "runbook missing the worker-side reference for the revoke-mid-flight gate"
    end

    test "cross-links every named sibling runbook + the regression suite" do
      contents = File.read!(@runbook_path)

      assert contents =~ "production-observability.md",
             "runbook missing cross-link to production-observability.md"

      assert contents =~ "base-mainnet-rehearsal.md",
             "runbook missing cross-link to base-mainnet-rehearsal.md"

      assert contents =~ "base-mainnet-canary.md",
             "runbook missing cross-link to base-mainnet-canary.md"

      assert contents =~ "incident-runbook.md",
             "runbook missing cross-link to docs/incident-runbook.md"

      assert contents =~ "test/bank/cross_account_isolation_test.exs",
             "runbook missing cross-link to the cross-account isolation regression suite"

      assert contents =~ "test/bank/workspace_query_scoping_test.exs",
             "runbook missing cross-link to the per-context workspace scoping suite"

      assert contents =~ "test/bank/mainnet_gate_test.exs",
             "runbook missing cross-link to the sibling mainnet gate suite"

      assert contents =~ "bank-v0.1-runtime-flow-and-api.md",
             "runbook missing cross-link to the v0.1 runtime flow + API doc"
    end

    test "names the dependency chain back to the parent epic" do
      contents = File.read!(@runbook_path)

      assert contents =~ "#167", "runbook missing reference to epic #167"

      assert contents =~ "#187",
             "runbook missing reference to itself (#187)"

      assert contents =~ "#158",
             "runbook missing reference to the workspace_id foundation #158"
    end
  end
end
