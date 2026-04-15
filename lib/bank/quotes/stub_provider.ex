defmodule Bank.Quotes.StubProvider do
  @moduledoc """
  In-process provider used for tests and local development.

  Deterministic, side-effect-free, and understands a handful of
  knobs expressed through `Application.put_env/3` or per-call opts:

    * `:outcome` — `:ok` (default), `:unavailable`, `:stale`, or
      `{:simulation_failed, reason}` to force a branch.
    * `:slippage_bps` — integer bps to surface on swap-kind intents.
    * `:balance_impact` — override the default balance impact map.
    * `:freshness_ttl_seconds` — override the default 30s TTL.

  The stub never performs network calls.
  """

  @behaviour Bank.Quotes.Provider

  alias Bank.Intents.AgentIntent
  alias Bank.Quotes.Preview

  @impl Bank.Quotes.Provider
  def preview(%AgentIntent{} = intent, opts \\ []) do
    case outcome(opts) do
      :ok -> {:ok, build_preview(intent, opts)}
      :unavailable -> {:error, :provider_unavailable}
      :stale -> {:error, :stale}
      {:simulation_failed, reason} -> {:error, {:simulation_failed, reason}}
    end
  end

  defp outcome(opts) do
    Keyword.get(opts, :outcome) || Application.get_env(:bank, __MODULE__, [])[:outcome] || :ok
  end

  defp build_preview(%AgentIntent{} = intent, opts) do
    amount = intent.amount || Decimal.new(0)

    default_balance = %{
      intent.asset => Decimal.negate(amount)
    }

    slippage =
      case intent.kind do
        :swap -> Keyword.get(opts, :slippage_bps, 25)
        _ -> nil
      end

    expected_output =
      case intent.kind do
        :swap -> Decimal.mult(amount, Decimal.new("0.995"))
        _ -> nil
      end

    %Preview{
      balance_impact: Keyword.get(opts, :balance_impact, default_balance),
      estimated_gas: 120_000,
      estimated_fee: Decimal.new("0.00015"),
      fee_asset: "ETH",
      expected_output: expected_output,
      slippage_bps: slippage,
      route: route_for(intent),
      failure_conditions: failure_conditions(intent),
      provider: "stub",
      provider_trace_ref: "stub-" <> Integer.to_string(System.unique_integer([:positive])),
      generated_at: DateTime.utc_now(),
      freshness_ttl_seconds: Keyword.get(opts, :freshness_ttl_seconds, 30)
    }
  end

  defp route_for(%AgentIntent{kind: :transfer, asset: asset}),
    do: %{"type" => "erc20_transfer", "asset" => asset}

  defp route_for(%AgentIntent{kind: :swap, asset: asset}),
    do: %{"type" => "swap", "from_asset" => asset, "router" => "stub-router"}

  defp route_for(_), do: nil

  defp failure_conditions(%AgentIntent{}) do
    [
      "wallet balance falls below requested amount",
      "nonce contention with in-flight user-op"
    ]
  end
end
