defmodule Bank.Decisions.ReportTest do
  @moduledoc """
  Tests for the deterministic decision report model (#248).

  Covers:

    * report builds from a `Bank.Audit.replay/1` bundle
    * same source bundle → identical report payload (determinism)
    * missing optional sections are LABELLED, not hidden
    * secret hygiene: no Bearer / Authorization / private key / raw
      audit before_ref/after_ref payloads / signing material in the
      JSON dump
    * report builder is read-only: no rows mutated, no jobs enqueued
    * cross-workspace safety: builder operates on the supplied
      bundle and does not pull sibling rows
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Bank.Fixtures

  alias Bank.Audit
  alias Bank.Audit.AuditEvent

  alias Bank.Decisions.{
    DecisionEnvelope,
    ExecutionPlan,
    Report,
    SimulationReport,
    TrustAssessment
  }

  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  describe "from_bundle/1 — successful flow" do
    setup do
      intent = agent_intent()

      claim =
        trust_assessment(
          intent: intent,
          derived_trust: :trusted,
          current: true,
          confidence: :high
        )

      sim =
        simulation_report(
          intent: intent,
          status: :completed,
          current: true,
          provider: "tenderly",
          provider_trace_ref: "tnd-trace-001",
          estimated_gas: 21_000,
          expected_output: Decimal.new("9.95"),
          slippage_exposure: Decimal.new("0.01")
        )

      decision =
        decision_envelope(
          intent: intent,
          outcome: :auto_exec,
          risk_tier: :low,
          current: true,
          decided_by: :runtime,
          state: :decided,
          reasons: %{"items" => ["policy.amount_limit ok", "trust=trusted"]}
        )

      plan =
        execution_plan(
          decision: decision,
          execution_status: :confirmed,
          final_outcome: :confirmed,
          tx_refs: ["0xabc1234567890def"]
        )

      audit_event(
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :agent
      )

      audit_event(
        event_type: "decision.decided",
        subject_type: "decision_envelope",
        subject_id: decision.id,
        correlation_id: intent.id,
        actor: :runtime
      )

      {:ok, bundle} = Audit.replay(intent.id)

      %{intent: intent, claim: claim, sim: sim, decision: decision, plan: plan, bundle: bundle}
    end

    test "produces a stable Report struct with all sections populated", %{
      intent: intent,
      decision: decision,
      plan: plan,
      bundle: bundle
    } do
      report = Report.from_bundle(bundle)

      assert %Report{} = report
      assert report.version == "1"

      assert report.generated_from == %{
               intent_id: intent.id,
               workspace_id: intent.workspace_id
             }

      # intent section
      assert report.intent.id == intent.id
      assert report.intent.kind == "transfer"
      assert report.intent.asset == intent.asset
      assert report.intent.chain == intent.chain
      # Stored decimals may carry more trailing precision than the
      # fixture's input string; compare numerically.
      assert Decimal.equal?(Decimal.new(report.intent.amount), intent.amount)
      assert report.intent.state == to_string(intent.state)
      assert report.intent.target.kind in ["counterparty", "raw_address", "unspecified"]

      # actor / source / workspace
      assert report.actor_source.agent_id == intent.agent_id
      assert report.actor_source.source == to_string(intent.source)
      assert report.actor_source.workspace_id == intent.workspace_id

      # trust
      assert report.trust_assessment.available == true
      assert report.trust_assessment.derived_trust == "trusted"
      assert report.trust_assessment.confidence == "high"

      # simulation
      assert report.simulation.available == true
      assert report.simulation.provider == "tenderly"
      assert report.simulation.status == "completed"
      assert Decimal.equal?(Decimal.new(report.simulation.expected_output), Decimal.new("9.95"))

      assert Decimal.equal?(
               Decimal.new(report.simulation.slippage_exposure),
               Decimal.new("0.01")
             )

      # decision envelope
      assert report.decision_envelope.available == true
      assert report.decision_envelope.id == decision.id
      assert report.decision_envelope.outcome == "auto_exec"
      assert report.decision_envelope.risk_tier == "low"
      assert "policy.amount_limit ok" in report.decision_envelope.reasons.items

      # approval (auto_exec)
      assert report.approval.available == true
      assert report.approval.kind == "auto_exec"

      # execution plan
      assert report.execution_plan.available == true
      assert report.execution_plan.id == plan.id
      assert report.execution_plan.execution_status == "confirmed"
      assert report.execution_plan.final_outcome == "confirmed"
      assert "0xabc1234567890def" in report.execution_plan.tx_refs

      # flags
      assert report.flags.chain == intent.chain
      # confirmed plan implies live (production-equivalent dispatch)
      assert report.flags.live? == true
      assert report.flags.stub? == false

      # audit trail summarised, no raw payloads
      assert is_list(report.audit_trail)
      assert length(report.audit_trail) >= 2

      # residual limitations: empty for a fully-resolved auto_exec flow
      # (every section was populated).
      refute Enum.any?(
               report.residual_limitations,
               &String.contains?(&1, "no decision envelope recorded")
             )
    end

    test "is byte-for-byte deterministic for the same bundle", %{bundle: bundle} do
      first = Report.from_bundle(bundle)
      second = Report.from_bundle(bundle)

      assert first == second

      first_json = Jason.encode!(first)
      second_json = Jason.encode!(second)

      assert first_json == second_json
    end

    test "from_intent_id/1 wraps from_bundle and matches the same payload", %{
      intent: intent,
      bundle: bundle
    } do
      assert {:ok, report_via_id} = Report.from_intent_id(intent.id)
      assert Report.from_bundle(bundle) == report_via_id
    end

    test "from_intent_id/1 returns :not_found for unknown intent" do
      assert {:error, :not_found} = Report.from_intent_id(Ecto.UUID.generate())
    end
  end

  describe "from_bundle/1 — held / blocked / partial flows" do
    test "no decisions yet → labelled missing sections, not crashes" do
      intent = agent_intent()
      {:ok, bundle} = Audit.replay(intent.id)

      report = Report.from_bundle(bundle)

      # required sections still populated
      assert report.intent.id == intent.id
      assert report.actor_source.agent_id == intent.agent_id
      assert report.flags.chain == intent.chain

      # optional sections labelled, not hidden
      assert %{available: false, reason: "no trust assessment recorded"} = report.trust_assessment
      assert %{available: false, reason: "no simulation recorded"} = report.simulation

      assert %{available: false, reason: "no decision envelope recorded"} =
               report.decision_envelope

      assert %{available: false, reason: "no execution plan recorded"} = report.execution_plan
      assert %{available: false, reason: "no approval/rejection recorded"} = report.approval
      assert %{available: false, reason: "no policy snapshot captured"} = report.policy_snapshot

      # residual limitations enumerate every missing section
      assert "no trust assessment recorded" in report.residual_limitations
      assert "no simulation recorded" in report.residual_limitations
      assert "no decision envelope recorded" in report.residual_limitations
      assert "no execution plan recorded" in report.residual_limitations

      # residual_limitations is sorted (deterministic ordering)
      assert report.residual_limitations == Enum.sort(report.residual_limitations)
    end

    test "approval_required decision → approval section reports pending; residual limitation flags hold" do
      intent = agent_intent()

      decision_envelope(
        intent: intent,
        outcome: :approval_required,
        risk_tier: :elevated,
        current: true,
        approval_expires_at: ~U[2030-01-01 00:00:00Z]
      )

      {:ok, bundle} = Audit.replay(intent.id)
      report = Report.from_bundle(bundle)

      assert report.decision_envelope.available == true
      assert report.decision_envelope.outcome == "approval_required"
      assert report.approval == %{available: true, kind: "approval_required_pending"}

      assert Enum.any?(
               report.residual_limitations,
               &String.starts_with?(&1, "decision is approval_required")
             )
    end

    test "block decision → approval section reports block kind" do
      intent = agent_intent()

      decision_envelope(
        intent: intent,
        outcome: :block,
        risk_tier: :severe,
        current: true,
        decided_by: :runtime,
        state: :resolved
      )

      {:ok, bundle} = Audit.replay(intent.id)
      report = Report.from_bundle(bundle)

      assert report.decision_envelope.outcome == "block"
      assert report.approval.kind == "block"
    end
  end

  describe "secret hygiene" do
    test "report payload does not include raw secrets even when source rows carry secret-like strings" do
      # Plant secret-like strings in places they could plausibly leak
      # from: intent target_raw_address, simulation provider_trace_ref,
      # plan adapter_ref, audit before_ref/after_ref. The Report
      # builder must NOT echo `Bearer`, `sk_`, `pk_`, `BEGIN `,
      # private-key markers, raw Authorization headers, or raw audit
      # payloads.
      bearer_token = "Bearer sk_test_THIS_MUST_NEVER_LEAK_0123456789"
      private_key_marker = "-----BEGIN PRIVATE KEY-----"
      provider_secret = "tenderly-token=secret_TOKEN_DEADBEEF"

      intent =
        agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0xpublicAddressNotASecret"
        )

      simulation_report(
        intent: intent,
        provider: "tenderly",
        # Provider trace refs ARE included in the report (they're a
        # trace identifier, not a secret), so use a non-secret value
        # here. Hide the actual secret-bearing string in a field the
        # report MUST exclude:
        provider_trace_ref: "tnd-trace-public-002",
        # routing_path is a raw payload field the report must NOT
        # serialise verbatim.
        routing_path: %{"raw_provider_payload" => bearer_token},
        # predicted_balance_changes raw items must NOT be serialised.
        predicted_balance_changes: %{"items" => [%{"sk" => "sk_test_HIDDEN_IN_RAW"}]}
      )

      decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      execution_plan(
        decision: decision_envelope(intent: intent, outcome: :auto_exec, current: false),
        intent_id: intent.id,
        # adapter_ref is a public reference (not a secret); include
        # a NON-secret string here. Hide the secret-bearing string in
        # `signing_requirements` which the report MUST exclude.
        adapter_ref: "adapter-ref-public-003",
        signing_requirements: %{"private_key_pem" => private_key_marker}
      )

      # Plant a secret in an audit event payload — report must not
      # echo before_ref/after_ref bodies into its audit_trail summary.
      audit_event(
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :agent,
        before_ref: %{"raw_authorization_header" => bearer_token},
        after_ref: %{"provider_secret" => provider_secret}
      )

      {:ok, bundle} = Audit.replay(intent.id)
      report = Report.from_bundle(bundle)

      # Dump the entire report to a string and assert no secret
      # marker appears anywhere.
      json = Jason.encode!(report)

      refute json =~ "Bearer ", "Bearer header must not appear in report payload"
      refute json =~ "sk_test_", "Stripe-style secret must not appear in report payload"

      refute json =~ "BEGIN PRIVATE KEY",
             "PEM private-key marker must not appear in report payload"

      refute json =~ "secret_TOKEN_DEADBEEF", "provider secret must not appear in report payload"

      refute json =~ "private_key_pem",
             "private_key_pem field key must not appear in report payload"

      refute json =~ "raw_authorization_header", "raw audit before_ref keys must not leak"
      refute json =~ "raw_provider_payload", "raw simulation routing_path keys must not leak"

      # Sanity: the public references SHOULD appear.
      assert json =~ "tnd-trace-public-002"
      assert json =~ "adapter-ref-public-003"
      assert json =~ "0xpublicAddressNotASecret"
    end

    test "policy snapshot exposes only metadata, not raw `params` values" do
      intent = agent_intent()

      rule =
        policy_rule(
          rule_type: :amount_limit,
          priority: 100,
          # `params` may carry provider-specific identifiers in the
          # future; the report should expose KEYS only, not values.
          params: %{
            "max_per_tx" => "100",
            "provider_secret_id" => "sk_HIDDEN_IN_PARAMS"
          }
        )

      decision_envelope(
        intent: intent,
        outcome: :auto_exec,
        current: true,
        policy_snapshot_ref: %{"rule_ids" => [rule.id]}
      )

      {:ok, bundle} = Audit.replay(intent.id)
      report = Report.from_bundle(bundle)

      json = Jason.encode!(report)

      refute json =~ "sk_HIDDEN_IN_PARAMS",
             "policy_rule.params raw values must not appear in report payload"

      # But the keys (param shape) ARE useful for replay readers.
      assert json =~ "max_per_tx"
      assert json =~ "provider_secret_id"
    end

    test "operator-supplied reason text in `decision.reasons.items[].message` is redacted (#248 P2)" do
      # `Bank.Decisions.apply_approval_decision/2` writes the
      # operator's free-text `reason` into a successor decision
      # envelope as `reasons.items[].message`. Pre-fix the Report
      # builder serialised those items verbatim, so an operator who
      # pasted a Bearer token / Authorization header / RPC URL with
      # embedded credentials / PEM marker / 0x-prefixed key handle
      # would leak the secret into any downstream
      # #249/#250/#251 report. Post-fix the message body is
      # dropped; only `code` + `actor_id` survive, plus a
      # `redacted: true` marker so downstream readers can tell
      # "operator wrote a reason but the body was suppressed" apart
      # from "operator wrote no reason at all".
      intent = agent_intent()

      # Plant every shape from the review finding into one
      # operator-style reason so the JSON-string refute covers all
      # markers the issue called for.
      planted_message =
        "Bearer sk_test_LEAKED_PROBE | Authorization: Bearer header | " <>
          "https://secret@example.test | -----BEGIN PRIVATE KEY----- | " <>
          "private_key=hex_blob | sk_live_HIDDEN | 0xdeadbeef"

      operator_actor_id = Ecto.UUID.generate()

      decision_envelope(
        intent: intent,
        outcome: :auto_exec,
        risk_tier: :low,
        decided_by: :user,
        current: true,
        reasons: %{
          "items" => [
            %{
              "code" => "operator_approved",
              "message" => planted_message,
              "actor_id" => operator_actor_id,
              # Some future caller may also use a `details` map for
              # richer context; the redactor must drop that too.
              "details" => %{"raw_authorization" => "Bearer sk_test_LEAKED_PROBE"}
            }
          ]
        }
      )

      {:ok, bundle} = Audit.replay(intent.id)
      report = Report.from_bundle(bundle)

      # The safe summary survives.
      assert report.decision_envelope.reasons.item_count == 1
      [item] = report.decision_envelope.reasons.items

      assert item["code"] == "operator_approved"
      assert item["actor_id"] == operator_actor_id
      assert item["redacted"] == true
      refute Map.has_key?(item, "message")
      refute Map.has_key?(item, "details")

      # And the JSON dump must not contain ANY of the planted
      # markers from the P2 acceptance list.
      json = Jason.encode!(report)

      refute json =~ "Bearer sk_test_LEAKED_PROBE"
      refute json =~ "Authorization: Bearer"
      refute json =~ "https://secret@example.test"
      refute json =~ "BEGIN PRIVATE KEY"
      refute json =~ "private_key"
      refute json =~ "sk_test_"
      refute json =~ "sk_live_HIDDEN"
      refute json =~ "0xdeadbeef"
      refute json =~ "raw_authorization"

      # `sk_` is a partial substring marker — verify nothing of the
      # planted secret-prefix family leaks under any casing.
      refute json =~ ~r/sk_(test|live)_/
    end

    test "runtime-generated reason items (bare strings) still pass through verbatim" do
      # Backstop: the redactor must not break the runtime path.
      # Programmer-written labels like `"policy.amount_limit ok"`
      # are safe by construction (no operator input) and remain
      # useful evidence in the report.
      intent = agent_intent()

      decision_envelope(
        intent: intent,
        outcome: :auto_exec,
        current: true,
        reasons: %{"items" => ["policy.amount_limit ok", "trust=trusted"]}
      )

      {:ok, bundle} = Audit.replay(intent.id)
      report = Report.from_bundle(bundle)

      assert report.decision_envelope.reasons.item_count == 2
      assert "policy.amount_limit ok" in report.decision_envelope.reasons.items
      assert "trust=trusted" in report.decision_envelope.reasons.items
    end
  end

  describe "read-only / no side effects" do
    test "from_bundle/1 does not mutate plans, intents, or enqueue Oban jobs" do
      intent = agent_intent()

      decision = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      plan =
        execution_plan(
          decision: decision,
          execution_status: :prepared,
          active: true
        )

      intent_before = Repo.get!(AgentIntent, intent.id)
      decision_before = Repo.get!(DecisionEnvelope, decision.id)
      plan_before = Repo.get!(ExecutionPlan, plan.id)

      {:ok, bundle} = Audit.replay(intent.id)
      _report = Report.from_bundle(bundle)

      assert Repo.get!(AgentIntent, intent.id) == intent_before
      assert Repo.get!(DecisionEnvelope, decision.id) == decision_before
      assert Repo.get!(ExecutionPlan, plan.id) == plan_before

      # No worker jobs of any kind were enqueued by the report
      # builder.
      assert oban_jobs_in_db() == []
    end
  end

  describe "cross-workspace safety" do
    test "from_bundle/1 reflects only the bundle the caller passed in" do
      # Workspace A holds the intent the caller wants. Workspace B
      # has its own intent + decision; nothing in workspace B should
      # appear in the workspace-A report.
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "report-iso-#{System.unique_integer([:positive])}",
          name: "Report iso B"
        })

      cp_b = counterparty(workspace_id: ws_b.id)

      intent_b = agent_intent(workspace_id: ws_b.id, target_counterparty_id: cp_b.id)
      _decision_b = decision_envelope(intent: intent_b, outcome: :block, current: true)

      intent_a = agent_intent()
      decision_a = decision_envelope(intent: intent_a, outcome: :auto_exec, current: true)

      {:ok, bundle_a} = Audit.replay(intent_a.id)
      report_a = Report.from_bundle(bundle_a)

      assert report_a.generated_from.intent_id == intent_a.id
      assert report_a.decision_envelope.id == decision_a.id

      # Sanity: the workspace-B intent's id never appears in the
      # workspace-A report payload.
      json = Jason.encode!(report_a)
      refute json =~ intent_b.id
    end
  end

  describe "determinism under repeated calls" do
    test "same bundle produces identical reports across many calls" do
      intent = agent_intent()
      _claim = trust_assessment(intent: intent, current: true)
      _sim = simulation_report(intent: intent, status: :completed, current: true)
      _decision = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      {:ok, bundle} = Audit.replay(intent.id)

      reports = for _ <- 1..5, do: Report.from_bundle(bundle)

      # All five must equal each other.
      assert Enum.all?(reports, &(&1 == hd(reports)))

      # And their JSON serialisation must match too (defends against
      # accidental introduction of MapSet / non-deterministic map
      # iteration in deeper structures).
      jsons = Enum.map(reports, &Jason.encode!/1)
      assert Enum.all?(jsons, &(&1 == hd(jsons)))
    end
  end

  # --- locally-needed helpers (count assertions cleanly) -------------------

  defp oban_jobs_in_db do
    # `Oban.Testing.all_enqueued/1` already exists; rename the local
    # helper to avoid the default-args conflict.
    Repo.all(Oban.Job)
  end

  # Avoid an unused-warning if AuditEvent / TrustAssessment / etc.
  # become unused after refactors.
  _ = {AuditEvent, TrustAssessment, SimulationReport}
end
