defmodule BankWeb.API.V1.IntentJSON do
  @moduledoc """
  JSON renderers for `/v1/intents` create / show / cancel / simulate
  responses.

  Replay rendering for `GET /v1/intents/:id/replay` lives in
  `BankWeb.API.V1.AuditJSON.replay/1` — keeping this module narrow to
  the create + show + cancel + simulate shape avoids duplicate intent
  renderers across the audit and intent surfaces.
  """

  alias Bank.Decisions.SimulationReport
  alias Bank.Intents.AgentIntent

  @doc """
  `POST /v1/intents` payload. Returns the intent record, the
  current state, the related-resource links, and the
  `idempotent_replay` flag.
  """
  def created(%{intent: %AgentIntent{} = intent, replay?: replay?}) do
    %{
      intent_id: intent.id,
      state: intent.state,
      idempotent_replay: replay?,
      links: links(intent),
      intent: intent_payload(intent)
    }
  end

  @doc """
  `GET /v1/intents/:id` payload. Mirrors `created/1` so that
  consumers can read the same shape regardless of how they got
  there.
  """
  def show(%{intent: %AgentIntent{} = intent}) do
    %{
      intent_id: intent.id,
      state: intent.state,
      links: links(intent),
      intent: intent_payload(intent)
    }
  end

  @doc """
  `POST /v1/intents/:id/cancel` payload. Returns the now-`cancelled`
  intent, the cancellation `reason` echoed back to the caller, and
  an `idempotent` flag that is `true` when the call was a re-cancel
  of an already-`cancelled` intent.
  """
  def cancelled(%{intent: %AgentIntent{} = intent, idempotent?: idempotent?, reason: reason}) do
    %{
      intent_id: intent.id,
      state: intent.state,
      idempotent: idempotent?,
      reason: reason,
      links: links(intent),
      intent: intent_payload(intent)
    }
  end

  @doc """
  `POST /v1/intents/:id/simulate` payload. Returns the produced
  `SimulationReport`, the intent (whose `current_simulation_id` may
  have moved if `reason == "refresh"`), and the simulation `reason`
  echoed back to the caller. `refreshed?` is `true` when the
  produced report became the active one.
  """
  def simulated(%{
        intent: %AgentIntent{} = intent,
        report: %SimulationReport{} = report,
        reason: reason,
        refreshed?: refreshed?
      }) do
    %{
      intent_id: intent.id,
      state: intent.state,
      reason: reason,
      refreshed: refreshed?,
      links: links(intent),
      intent: intent_payload(intent),
      simulation: simulation_payload(report)
    }
  end

  defp simulation_payload(%SimulationReport{} = report) do
    %{
      id: report.id,
      provider: report.provider,
      provider_trace_ref: report.provider_trace_ref,
      chain: report.chain,
      asset: report.asset,
      status: report.status,
      current: report.current,
      generated_at: report.generated_at,
      freshness_ttl_seconds: report.freshness_ttl_seconds,
      predicted_balance_changes: report.predicted_balance_changes,
      estimated_gas: report.estimated_gas,
      estimated_fees: report.estimated_fees,
      routing_path: report.routing_path,
      expected_output: decimal(report.expected_output),
      slippage_exposure: decimal(report.slippage_exposure),
      failure_conditions: report.failure_conditions,
      supersedes_id: report.supersedes_id
    }
  end

  defp intent_payload(%AgentIntent{} = intent) do
    %{
      id: intent.id,
      agent_id: intent.agent_id,
      source: intent.source,
      kind: intent.kind,
      asset: intent.asset,
      chain: intent.chain,
      amount: decimal(intent.amount),
      idempotency_key: intent.idempotency_key,
      payload_hash: intent.payload_hash,
      schema_version: intent.schema_version,
      target: target(intent),
      notes: intent.notes,
      state: intent.state,
      submitted_at: intent.submitted_at,
      current_decision_id: intent.current_decision_id,
      current_simulation_id: intent.current_simulation_id,
      current_trust_assessment_id: intent.current_trust_assessment_id,
      current_execution_plan_id: intent.current_execution_plan_id
    }
  end

  defp target(%AgentIntent{target_raw_address: raw}) when is_binary(raw) do
    %{raw_address: raw}
  end

  defp target(%AgentIntent{
         target_counterparty_id: cp_id,
         target_address_label_id: label_id
       })
       when is_binary(cp_id) do
    %{counterparty_id: cp_id, address_label_id: label_id}
  end

  defp target(_intent), do: nil

  defp links(%AgentIntent{id: id}) do
    %{
      self: "/v1/intents/#{id}",
      replay: "/v1/intents/#{id}/replay"
    }
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp decimal(other), do: other
end
