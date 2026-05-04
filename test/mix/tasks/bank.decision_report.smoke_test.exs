defmodule Mix.Tasks.Bank.DecisionReport.SmokeTest do
  use Bank.DataCase, async: false

  import ExUnit.CaptureIO

  alias Bank.Demo

  @runbook_path Path.expand("../../../docs/runbooks/decision-reports.md", __DIR__)

  describe "mix bank.decision_report.smoke" do
    test "passes against the seeded sandbox dataset for all six outcome examples" do
      :ok = Demo.seed()

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.DecisionReport.Smoke.run([])
        end)

      # All six required outcome examples surface as PASS lines on a
      # green run. The labels mirror #252's scope.
      for label <- ~w(auto_exec approval_required held blocked executed failed) do
        assert output =~ "PASS #{label}",
               "missing PASS line for #{label}: #{inspect(output)}"
      end

      assert output =~ "6 / 6 PASS"
      refute output =~ "FAIL"
    end

    test "with --seed runs Bank.Demo.seed/0 first and prints the seed-message" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.DecisionReport.Smoke.run(["--seed"])
        end)

      assert Bank.Workspaces.get_workspace_by_slug("sandbox-demo") != nil
      assert output =~ "seeding sandbox dataset (--seed)"
      assert output =~ "6 / 6 PASS"
    end

    test "with --quiet suppresses PASS lines but still prints the summary" do
      :ok = Demo.seed()

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.DecisionReport.Smoke.run(["--quiet"])
        end)

      refute output =~ "PASS auto_exec"
      refute output =~ "PASS executed"
      assert output =~ "6 / 6 PASS"
    end

    test "fails loudly when a required seeded fixture is missing (no fake-pass on regression)" do
      :ok = Demo.seed()

      # Simulate a regression where the `treasury-reverted` (failed)
      # scenario is removed from the seed. The smoke MUST surface
      # this as a FAIL — silent green is the anti-acceptance for
      # #252's "smoke covers all six outcomes" scope.
      #
      # We rename the idempotency_key rather than delete the row,
      # because the row has FK-referencing children (simulation,
      # decision, plan, audit) that would block a raw DELETE. The
      # smoke looks up by `(workspace_id, idempotency_key)`, so
      # rewriting the key is sufficient to make the example
      # invisible to the lookup.
      Bank.Repo.update_all(
        from(i in Bank.Intents.AgentIntent,
          where: i.idempotency_key == ^"sandbox-treasury-reverted"
        ),
        set: [idempotency_key: "sandbox-treasury-reverted-RENAMED"]
      )

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/bank\.decision_report\.smoke FAILED/, fn ->
            Mix.Tasks.Bank.DecisionReport.Smoke.run([])
          end
        end)

      assert output =~ "FAIL failed"
      assert output =~ "sandbox-treasury-reverted"
      refute output =~ "6 / 6 PASS"
    end

    # #252 acceptance bullet: the smoke must produce at least one
    # generated report from demo data. The most direct proof is to
    # capture the stdout of a green run and assert that the
    # generated artifact filenames appear in it (one per example).
    test "generates a Markdown report artifact for every example (filename appears in output)" do
      :ok = Demo.seed()

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.DecisionReport.Smoke.run([])
        end)

      # Each PASS line is shaped:
      #   PASS <label> <handle> → decision-report-<intent_short>-<hash_short>.md
      # We assert at least six unique filenames appear.
      filenames =
        Regex.scan(~r/(decision-report-[0-9a-f-]+-[0-9a-f]+\.md)/, output)
        |> Enum.map(fn [_, fname] -> fname end)
        |> Enum.uniq()

      assert length(filenames) >= 6,
             "expected ≥ 6 distinct decision-report-*.md filenames in smoke output, got: #{inspect(filenames)}"
    end

    # #252 secret-hygiene acceptance — the smoke output and (by
    # implication, since the smoke would have refused to PASS
    # otherwise) the rendered report bodies must not carry any
    # of the credential shapes the issue body lists. We
    # double-check the stdout output here so a future regression
    # that prints a leaked field into the PASS line is caught.
    test "smoke output contains no secret-shaped markers" do
      :ok = Demo.seed()

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.DecisionReport.Smoke.run([])
        end)

      refute output =~ ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
             "smoke output contains a PEM private-key block"

      refute output =~ ~r/\b(sk_live|pk_live|sk_test)_[A-Za-z0-9_-]+/,
             "smoke output contains a Stripe-style live/test secret token"

      refute output =~ ~r/\bauthorization\s*:\s*"?bearer\s+[A-Za-z0-9._-]+/i,
             "smoke output contains a literal Authorization: Bearer header"

      refute output =~ ~r{https?://[^/\s"`]+:[^@/\s"`]+@[A-Za-z0-9.-]+},
             "smoke output contains a tokenized https://user:pass@host URL"
    end

    # #252 chain-safety acceptance — the smoke must not call
    # `Bank.AdapterClient` (no chain HTTP). Mirrors the equivalent
    # guard in `Mix.Tasks.Bank.Sandbox.SmokeTest`.
    test "does not call Bank.AdapterClient (no chain HTTP)" do
      :ok = Demo.seed()

      parent = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        send(parent, :adapter_was_called)
        Req.Test.json(conn, %{status: "ok"})
      end)

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.DecisionReport.Smoke.run([])
        end)

      assert output =~ "6 / 6 PASS"
      refute output =~ "FAIL"
      refute_receive :adapter_was_called, 50
    end

    # #252 acceptance bullet: a fresh reviewer can generate a report
    # locally. The shape predicates encode the required mapping
    # from outcome label to seed scenario; this test cross-checks
    # the runtime predicates against the seeded data so a future
    # seed change that breaks the mapping fails this test, not
    # silently reduces coverage.
    test "shape predicates are wired correctly to the seeded scenarios" do
      :ok = Demo.seed()

      pairs = [
        {&Mix.Tasks.Bank.DecisionReport.Smoke.matches_auto_exec?/1,
         "sandbox-decided-pending-exec"},
        {&Mix.Tasks.Bank.DecisionReport.Smoke.matches_approval_required?/1,
         "sandbox-partner-x-pending-approval"},
        {&Mix.Tasks.Bank.DecisionReport.Smoke.matches_held?/1, "sandbox-treasury-held"},
        {&Mix.Tasks.Bank.DecisionReport.Smoke.matches_blocked?/1, "sandbox-unknown-blocked"},
        {&Mix.Tasks.Bank.DecisionReport.Smoke.matches_executed?/1, "sandbox-payroll-confirmed"},
        {&Mix.Tasks.Bank.DecisionReport.Smoke.matches_failed?/1, "sandbox-treasury-reverted"}
      ]

      ws_id = Demo.demo_workspace_id()
      assert is_binary(ws_id)

      for {predicate, idempotency_key} <- pairs do
        intent =
          Bank.Repo.one(
            from(i in Bank.Intents.AgentIntent,
              where: i.workspace_id == ^ws_id and i.idempotency_key == ^idempotency_key,
              limit: 1
            )
          )

        assert intent != nil,
               "seeded intent #{inspect(idempotency_key)} not found — seed regression?"

        {:ok, bundle} = Bank.Audit.replay(intent.id)
        report = Bank.Decisions.Report.from_bundle(bundle)

        assert predicate.(report),
               "predicate did not match seeded #{idempotency_key} report shape: #{inspect(report.decision_envelope)} / #{inspect(report.execution_plan)}"
      end
    end
  end

  describe "docs/runbooks/decision-reports.md" do
    test "exists at the expected path" do
      assert File.exists?(@runbook_path),
             "decision-reports runbook missing at #{@runbook_path}"
    end

    test "carries the not-legal-attestation caveat" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/not\s+a\s+legal\s+attestation/i,
             "runbook missing the 'not a legal attestation' caveat"

      assert contents =~ ~r/not\s+a\s+compliance\s+certification/i,
             "runbook missing the 'not a compliance certification' caveat"

      assert contents =~ ~r/evidence-based runtime report/i,
             "runbook missing the 'evidence-based runtime report' framing"
    end

    test "documents how to generate a report locally" do
      contents = File.read!(@runbook_path)

      assert contents =~ "mix bank.demo.seed",
             "runbook missing the seed instruction"

      assert contents =~ "mix bank.decision_report.smoke",
             "runbook missing the smoke command"

      assert contents =~ "/audit/replay/:intent_id/report",
             "runbook missing the browser-session route"

      assert contents =~ "/v1/intents/:id/report",
             "runbook missing the API route"
    end

    test "names every #252 example outcome at least once" do
      contents = File.read!(@runbook_path)

      for example <- ~w(auto_exec approval_required held blocked executed failed) do
        assert contents =~ example,
               "runbook does not name the #{example} example"
      end
    end

    test "explicitly states the no-secrets / no-broadcast posture" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/no.{0,5}broadcast/i,
             "runbook missing the 'no broadcast' posture"

      assert contents =~ ~r/no.{0,5}secret/i,
             "runbook missing the 'no secrets' posture"
    end
  end
end
