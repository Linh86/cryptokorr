defmodule BankWeb.API.V1.AuditJSON do
  @moduledoc """
  JSON renderers for `/v1/audit` and `/v1/intents/:id/replay`.

  The shapes here are the contract the external API is held to, not a
  mirror of the Ecto schemas. Keep additions additive — fields may be
  added to the rendered object, but existing fields are load-bearing.
  """

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.{DecisionEnvelope, TrustAssessment, ExecutionPlan, SimulationReport}
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.PolicyRule

  @doc "Paged `/v1/audit` envelope."
  def index(%{events: events, next_cursor: cursor}) do
    %{
      data: Enum.map(events, &render_event/1),
      page: %{next_cursor: cursor}
    }
  end

  @doc "`/v1/intents/:id/replay` bundle."
  def replay(%{bundle: bundle}) do
    %{
      intent: render_intent(bundle.intent),
      policy_snapshot: Enum.map(bundle.policy_snapshot, &render_policy_rule/1),
      trust_assessments: Enum.map(bundle.trust_assessments, &render_claim/1),
      simulations: Enum.map(bundle.simulations, &render_simulation/1),
      decisions: Enum.map(bundle.decisions, &render_decision/1),
      plans: Enum.map(bundle.plans, &render_plan/1),
      audit: Enum.map(bundle.audit, &render_event/1),
      screening_evidence: bundle[:screening_evidence]
    }
  end

  # --- entity renderers --------------------------------------------------

  def render_event(%AuditEvent{} = event) do
    %{
      id: event.id,
      ts: event.ts,
      actor: event.actor,
      actor_id: event.actor_id,
      event_type: event.event_type,
      subject_type: event.subject_type,
      subject_id: event.subject_id,
      correlation_id: event.correlation_id,
      before_ref: event.before_ref,
      after_ref: event.after_ref,
      payload_hash: event.payload_hash,
      schema_version: event.schema_version
    }
  end

  defp render_intent(%AgentIntent{} = intent) do
    %{
      id: intent.id,
      agent_id: intent.agent_id,
      source: intent.source,
      idempotency_key: intent.idempotency_key,
      payload_hash: intent.payload_hash,
      kind: intent.kind,
      asset: intent.asset,
      chain: intent.chain,
      amount: decimal(intent.amount),
      target_counterparty_id: intent.target_counterparty_id,
      target_address_label_id: intent.target_address_label_id,
      target_raw_address: intent.target_raw_address,
      notes: intent.notes,
      schema_version: intent.schema_version,
      state: intent.state,
      submitted_at: intent.submitted_at
    }
  end

  defp render_policy_rule(%PolicyRule{} = rule) do
    %{
      id: rule.id,
      version: rule.version,
      state: rule.state,
      scope: rule.scope,
      rule_type: rule.rule_type,
      params: rule.params,
      priority: rule.priority,
      created_by: rule.created_by,
      supersedes_id: rule.supersedes_id,
      inserted_at: rule.inserted_at
    }
  end

  defp render_claim(%TrustAssessment{} = claim) do
    %{
      id: claim.id,
      intent_id: claim.intent_id,
      derived_trust: claim.derived_trust,
      confidence: claim.confidence,
      contradictions: claim.contradictions,
      supporting_assertion_ids: claim.supporting_assertion_ids,
      supporting_evidence_ids: claim.supporting_evidence_ids,
      rationale: claim.rationale,
      generated_at: claim.generated_at,
      generated_by: claim.generated_by,
      current: claim.current,
      supersedes_id: claim.supersedes_id
    }
  end

  defp render_simulation(%SimulationReport{} = report) do
    %{
      id: report.id,
      intent_id: report.intent_id,
      provider: report.provider,
      provider_trace_ref: report.provider_trace_ref,
      chain: report.chain,
      asset: report.asset,
      predicted_balance_changes: report.predicted_balance_changes,
      estimated_gas: report.estimated_gas,
      estimated_fees: report.estimated_fees,
      routing_path: report.routing_path,
      expected_output: decimal(report.expected_output),
      slippage_exposure: decimal(report.slippage_exposure),
      failure_conditions: report.failure_conditions,
      generated_at: report.generated_at,
      freshness_ttl_seconds: report.freshness_ttl_seconds,
      status: report.status,
      current: report.current,
      supersedes_id: report.supersedes_id
    }
  end

  defp render_decision(%DecisionEnvelope{} = envelope) do
    %{
      id: envelope.id,
      intent_id: envelope.intent_id,
      outcome: envelope.outcome,
      risk_tier: envelope.risk_tier,
      reasons: envelope.reasons,
      policy_snapshot_ref: envelope.policy_snapshot_ref,
      trust_assessment_id: envelope.trust_assessment_id,
      simulation_report_id: envelope.simulation_report_id,
      decided_at: envelope.decided_at,
      decided_by: envelope.decided_by,
      state: envelope.state,
      current: envelope.current,
      approval_expires_at: envelope.approval_expires_at,
      supersedes_id: envelope.supersedes_id
    }
  end

  defp render_plan(%ExecutionPlan{} = plan) do
    %{
      id: plan.id,
      decision_id: plan.decision_id,
      intent_id: plan.intent_id,
      chain: plan.chain,
      asset: plan.asset,
      smart_account_id: plan.smart_account_id,
      steps: plan.steps,
      signing_requirements: plan.signing_requirements,
      adapter_ref: plan.adapter_ref,
      nonce: plan.nonce,
      execution_status: plan.execution_status,
      tx_refs: plan.tx_refs,
      final_outcome: plan.final_outcome,
      final_reason: plan.final_reason,
      active: plan.active
    }
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp decimal(other), do: other
end
