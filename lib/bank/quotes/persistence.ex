defmodule Bank.Quotes.Persistence do
  @moduledoc """
  Translate a `%Preview{}` into a persisted
  `%Bank.Decisions.SimulationReport{}` attr map, ready for insertion
  by the decision-engine transaction.

  Keeping the translation in a dedicated module prevents the rest of
  the runtime from constructing simulation reports from raw provider
  payloads — every persisted simulation flows through the same
  normalisation path so audit and replay see consistent shapes.
  """

  alias Bank.Quotes.Preview

  @doc """
  Build the attr map to insert into `simulation_reports`. `status`
  defaults to `:completed` for a healthy preview; pass `:stale` or
  `:failed` to record a degraded result that the decision engine
  should treat as a block/hold signal.
  """
  @spec to_simulation_attrs(
          Preview.t(),
          intent_id :: Ecto.UUID.t(),
          status :: :completed | :failed | :stale,
          keyword()
        ) :: map()
  def to_simulation_attrs(%Preview{} = preview, intent_id, status, opts \\ [])
      when status in [:completed, :failed, :stale] do
    %{
      intent_id: intent_id,
      provider: preview.provider,
      provider_trace_ref: preview.provider_trace_ref,
      chain: Keyword.get(opts, :chain, "base"),
      asset: Keyword.get(opts, :asset, "USDC"),
      predicted_balance_changes: %{
        "items" =>
          Enum.map(preview.balance_impact, fn {asset, amount} ->
            %{"asset" => asset, "amount" => Decimal.to_string(amount, :normal)}
          end)
      },
      estimated_gas: preview.estimated_gas,
      estimated_fees: %{
        "asset" => preview.fee_asset,
        "amount" =>
          case preview.estimated_fee do
            nil -> nil
            %Decimal{} = d -> Decimal.to_string(d, :normal)
          end
      },
      routing_path: preview.route || %{},
      expected_output: preview.expected_output,
      slippage_exposure:
        case preview.slippage_bps do
          nil -> nil
          bps -> Decimal.new(bps) |> Decimal.div(Decimal.new(10_000))
        end,
      failure_conditions: %{"items" => preview.failure_conditions},
      generated_at: preview.generated_at,
      freshness_ttl_seconds: preview.freshness_ttl_seconds,
      status: status,
      current: true
    }
  end
end
