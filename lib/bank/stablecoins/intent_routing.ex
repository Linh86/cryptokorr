defmodule Bank.Stablecoins.IntentRouting do
  @moduledoc """
  Bridges stablecoin route evaluation into the intent execution flow.

  Given an intent that represents a stablecoin swap, bridge, or
  swap+bridge, evaluates the route through `RoutePolicy`, maps the
  decision to autonomy-compatible outcomes, records audit evidence,
  updates provider health, and emits telemetry.

  ## Integration point

  Called from execution planning when `intent.kind == :swap` and the
  intent's asset/chain pair falls within stablecoin registry coverage.

  ## Decision mapping

    * `RoutePolicy` `:allowed` → autonomy outcome `:auto_exec`
    * `RoutePolicy` `:approval_required` → autonomy outcome `:approval_required`
    * `RoutePolicy` `:blocked` → autonomy outcome `:block`

  ## Execution state

  This module produces a route plan but does NOT submit on-chain
  transactions. The execution plan state is set to `:requires_adapter` to
  indicate that the route has been evaluated and a provider quote
  selected, but the adapter dispatch step has not yet been wired
  for stablecoin swap/bridge routes.
  """

  alias Bank.Stablecoins.{ProviderHealth, QuoteRequest, RoutePolicy}

  @type route_result :: %{
          outcome: :auto_exec | :approval_required | :block,
          reason_code: atom(),
          reason: String.t(),
          evaluation: RoutePolicy.evaluation() | nil,
          execution_state: :planned | :blocked | :requires_adapter
        }

  @doc """
  Evaluate a stablecoin route for an intent.

  Builds a `QuoteRequest` from the intent parameters, runs it through
  `RoutePolicy.evaluate/2`, maps the decision to an autonomy outcome,
  records audit evidence, and updates provider health.

  Returns a `route_result` map compatible with autonomy routing inputs.
  """
  @spec evaluate_for_intent(map(), keyword()) ::
          {:ok, route_result()} | {:error, term()}
  def evaluate_for_intent(params, opts \\ []) when is_map(params) do
    with {:ok, quote_req} <- build_quote_request(params),
         {:ok, evaluation} <- RoutePolicy.evaluate(quote_req, opts) do
      observe_health(evaluation)
      emit_telemetry(evaluation)

      result = build_result(evaluation)

      with :ok <- maybe_emit_audit(params, result) do
        {:ok, result}
      end
    else
      {:error, reason} ->
        emit_telemetry_error(reason)
        {:error, reason}
    end
  end

  @doc """
  Build audit evidence from a route evaluation result.

  Returns a map suitable for inclusion in `Bank.Audit.append_event/1`
  payloads, following the same shape as wallet screening evidence.
  """
  @spec build_evidence(route_result()) :: map()
  def build_evidence(%{evaluation: nil}), do: %{stablecoin_route: nil}

  def build_evidence(%{evaluation: eval} = result) do
    request = eval.request || eval.quote.request

    %{
      stablecoin_route: %{
        decision: atom_string(result.outcome),
        execution_state: atom_string(result.execution_state),
        reason_code: atom_string(result.reason_code),
        reason: result.reason,
        policy_decision: atom_string(eval.decision),
        policy_reasons: Enum.map(eval.reasons, &reason_json/1),
        score: eval.score,
        fee_summary: fee_summary_json(eval.fee_summary),
        route_kind: atom_string(eval.quote.route_kind),
        provider: eval.quote.provider,
        input_amount: decimal_string(eval.quote.input_amount),
        output_amount: decimal_string(eval.quote.output_amount),
        eta_seconds: eval.quote.eta_seconds,
        expires_at: datetime_string(eval.quote.expires_at),
        quoted_at: datetime_string(eval.quote.quoted_at),
        quote_request: quote_request_json(request),
        legs: Enum.map(eval.quote.legs, &leg_json/1),
        selector_metadata: selector_metadata_json(eval.selector_metadata),
        evaluated_at: datetime_string(eval.quote.quoted_at)
      }
    }
  end

  # -- Private -------------------------------------------------------------

  defp build_quote_request(params) do
    QuoteRequest.build(%{
      source_chain: params[:source_chain] || params["source_chain"],
      source_asset: params[:source_asset] || params["source_asset"],
      dest_chain: params[:dest_chain] || params["dest_chain"],
      dest_asset: params[:dest_asset] || params["dest_asset"],
      amount: params[:amount] || params["amount"],
      slippage_bps: params[:slippage_bps] || params["slippage_bps"],
      metadata: params[:metadata] || params["metadata"] || %{}
    })
  end

  defp build_result(evaluation) do
    {outcome, reason_code, reason, exec_state} = map_decision(evaluation.decision, evaluation)

    %{
      outcome: outcome,
      reason_code: reason_code,
      reason: reason,
      evaluation: evaluation,
      execution_state: exec_state
    }
  end

  defp map_decision(:allowed, eval) do
    {
      :auto_exec,
      :stablecoin_route_allowed,
      "Stablecoin #{eval.quote.route_kind} route via #{eval.quote.provider} — " <>
        "score #{eval.score}, fee #{eval.fee_summary.total_fee}",
      :requires_adapter
    }
  end

  defp map_decision(:approval_required, eval) do
    rules = eval.reasons |> Enum.map(& &1.rule) |> Enum.join(", ")

    {
      :approval_required,
      :stablecoin_route_needs_approval,
      "Stablecoin route requires approval: #{rules}",
      :requires_adapter
    }
  end

  defp map_decision(:blocked, eval) do
    rules = eval.reasons |> Enum.map(& &1.rule) |> Enum.join(", ")

    {
      :block,
      :stablecoin_route_blocked,
      "Stablecoin route blocked: #{rules}",
      :blocked
    }
  end

  defp observe_health(evaluation) do
    if GenServer.whereis(ProviderHealth) do
      meta = evaluation.selector_metadata

      Enum.each(meta[:errors] || [], fn %{provider: mod, error: reason} ->
        provider_id = provider_id_for(mod)
        ProviderHealth.record_failure(provider_id, reason)
      end)

      record_successes(evaluation)
    end

    :ok
  end

  defp record_successes(%{quote: %{provider: "composite"}, selector_metadata: meta}) do
    meta
    |> Map.take([:swap_meta, :bridge_meta])
    |> Map.values()
    |> Enum.flat_map(fn
      %{all_quotes: quotes} -> quotes
      _ -> []
    end)
    |> Enum.each(&ProviderHealth.record_success(&1.provider))
  end

  defp record_successes(evaluation) do
    ProviderHealth.record_success(evaluation.quote.provider)
  end

  defp maybe_emit_audit(params, result) do
    case intent_id(params) do
      nil ->
        :ok

      id ->
        case Bank.Runtime.emit_audit(%{
               actor: :runtime,
               event_type: "stablecoin.route_evaluated",
               subject_type: "agent_intent",
               subject_id: id,
               correlation_id: id,
               after_ref: build_evidence(result)
             }) do
          {:ok, _event} -> :ok
          {:error, reason} -> {:error, {:audit_failed, reason}}
        end
    end
  end

  defp intent_id(params) do
    params[:intent_id] || params["intent_id"]
  end

  defp emit_telemetry(evaluation) do
    Bank.Runtime.Telemetry.stablecoin_route(%{
      decision: evaluation.decision,
      route_kind: evaluation.quote.route_kind,
      provider: evaluation.quote.provider,
      score: evaluation.score
    })
  end

  defp emit_telemetry_error(reason) do
    Bank.Runtime.Telemetry.stablecoin_route(%{
      decision: :error,
      route_kind: :unknown,
      provider: :none,
      score: 0.0,
      error: reason
    })
  end

  defp provider_id_for(mod) when is_atom(mod) do
    if function_exported?(mod, :provider_id, 0), do: mod.provider_id(), else: inspect(mod)
  end

  defp provider_id_for(provider_id) when is_binary(provider_id), do: provider_id

  defp quote_request_json(nil), do: nil

  defp quote_request_json(request) do
    %{
      source_chain: request.source_chain,
      source_asset: request.source_asset,
      dest_chain: request.dest_chain,
      dest_asset: request.dest_asset,
      amount: decimal_string(request.amount),
      slippage_bps: request.slippage_bps,
      route_kind: atom_string(request.route_kind)
    }
  end

  defp reason_json(reason) do
    %{
      rule: atom_string(reason.rule),
      detail: reason.detail,
      severity: atom_string(reason.severity)
    }
  end

  defp fee_summary_json(nil), do: nil

  defp fee_summary_json(fees) do
    %{
      gas_fee: decimal_string(fees.gas_fee),
      protocol_fee: decimal_string(fees.protocol_fee),
      bridge_fee: decimal_string(fees.bridge_fee),
      cryptobank_fee: decimal_string(fees.cryptobank_fee),
      total_fee: decimal_string(fees.total_fee),
      output_impact_pct: decimal_string(fees.output_impact_pct)
    }
  end

  defp leg_json(leg) do
    %{
      step: leg.step,
      kind: atom_string(leg.kind),
      source_chain: leg.source_chain,
      source_asset: leg.source_asset,
      source_address: leg.source_address,
      dest_chain: leg.dest_chain,
      dest_asset: leg.dest_asset,
      dest_address: leg.dest_address,
      input_amount: decimal_string(leg.input_amount),
      output_amount: decimal_string(leg.output_amount),
      protocol: leg.protocol,
      pool_address: leg.pool_address,
      eta_seconds: leg.eta_seconds
    }
  end

  defp selector_metadata_json(nil), do: %{considered: 0, errors: []}

  defp selector_metadata_json(meta) do
    %{
      considered: meta[:considered] || 0,
      errors:
        Enum.map(meta[:errors] || [], fn e ->
          %{provider: provider_id_for(e.provider), error: inspect(e.error)}
        end)
    }
  end

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value), do: value

  defp decimal_string(nil), do: nil
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(value), do: to_string(value)

  defp datetime_string(nil), do: nil
  defp datetime_string(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
