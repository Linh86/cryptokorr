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
  transactions. The execution plan state is set to `:planned` to
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
      {:ok, result}
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
    %{
      stablecoin_route: %{
        decision: result.outcome,
        execution_state: result.execution_state,
        reason_code: result.reason_code,
        policy_decision: eval.decision,
        policy_reasons: Enum.map(eval.reasons, &Map.take(&1, [:rule, :detail, :severity])),
        score: eval.score,
        fee_summary: eval.fee_summary,
        route_kind: eval.quote.route_kind,
        provider: eval.quote.provider,
        input_amount: eval.quote.input_amount,
        output_amount: eval.quote.output_amount,
        legs:
          Enum.map(eval.quote.legs, fn leg ->
            %{
              step: leg.step,
              kind: leg.kind,
              source_chain: leg.source_chain,
              source_asset: leg.source_asset,
              dest_chain: leg.dest_chain,
              dest_asset: leg.dest_asset,
              protocol: leg.protocol
            }
          end),
        selector_metadata: %{
          considered: eval.selector_metadata[:considered],
          errors:
            Enum.map(eval.selector_metadata[:errors] || [], fn e ->
              %{provider: inspect(e.provider), error: inspect(e.error)}
            end)
        },
        evaluated_at: eval.quote.quoted_at
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
      :planned
    }
  end

  defp map_decision(:approval_required, eval) do
    rules = eval.reasons |> Enum.map(& &1.rule) |> Enum.join(", ")

    {
      :approval_required,
      :stablecoin_route_needs_approval,
      "Stablecoin route requires approval: #{rules}",
      :planned
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

      ProviderHealth.record_success(evaluation.quote.provider)
    end

    :ok
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
end
