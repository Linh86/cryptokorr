defmodule Bank.Decisions.SwapRouteArtifacts do
  @moduledoc """
  Pure transformer that derives the persisted/audited artifacts for a
  swap execution plan from a validated swap-route map (#190).

  The producer (live quote provider, epic #165 / #173) emits a route
  validated by `Bank.Intents.SwapRoute`. This module turns that
  already-validated map into:

    * a deterministic `route_hash` that survives DB round-trips and
      stays stable for replay (sha256 over a canonical pipe-joined
      representation of the load-bearing route fields, with addresses
      downcased so case-only producer drift does not move the hash);
    * the JSON-friendly `:steps` payload persisted on
      `Bank.Decisions.ExecutionPlan` for future dispatch and replay;
    * the small `:audit_metadata` map surfaced on the
      `execution.manually_requested` / `execution.auto_dispatched`
      audit `after_ref` so replay can verify which route a plan was
      built from without rehydrating the full route payload.

  Calldata is needed downstream for dispatch and is persisted in
  `:steps`, but is intentionally excluded from the hash inputs and
  the audit metadata. That keeps audit rows compact and means the
  hash is reproducible from the persisted steps without depending
  on raw transaction bytes.

  This module is execution-plan side: it never mutates the route,
  never validates it (callers run `Bank.Intents.SwapRoute.validate/2`
  before calling here), never reads or persists provider secrets, and
  never `inspect/1`s the route into a string.
  """

  alias Bank.Intents.SwapRoute

  @type audit_metadata :: %{
          required(:route_hash) => String.t(),
          required(:route_provider) => String.t()
        }

  @type t :: %{
          required(:route_hash) => String.t(),
          required(:chain) => String.t(),
          required(:asset) => String.t(),
          required(:steps) => map(),
          required(:audit_metadata) => audit_metadata()
        }

  @doc """
  Build the artifacts bundle from a validated route. The caller is
  responsible for having run `SwapRoute.validate/2` first; this
  function trusts the shape.

  Returns a map with `:route_hash`, `:chain`, `:asset`, `:steps`,
  and `:audit_metadata`. The `:chain` and `:asset` are taken from
  the route (chain from `route.chain`; asset from
  `route.destination_asset` since that is what arrives in the smart
  account after the swap).
  """
  @spec from_route(SwapRoute.t()) :: t()
  def from_route(route) when is_map(route) do
    hash = route_hash(route)

    %{
      route_hash: hash,
      chain: route.chain,
      asset: route.destination_asset,
      steps: persisted_steps(route, hash),
      audit_metadata: %{route_hash: hash, route_provider: route.route_provider}
    }
  end

  @doc """
  Deterministic SHA-256 hex over the load-bearing route fields.

  Address strings are downcased so a case-only difference between
  the producer and the persisted form does not drift the hash.
  Decimal amounts go through `Decimal.to_string/2` with `:normal`
  so trailing zeros are not load-bearing. `:calldata` is excluded
  by design (see module docs).
  """
  @spec route_hash(SwapRoute.t()) :: String.t()
  def route_hash(route) when is_map(route) do
    payload =
      [
        route.chain,
        Integer.to_string(route.chain_id),
        route.source_asset,
        downcase(route.source_token_address),
        route.destination_asset,
        downcase(route.destination_token_address),
        decimal_string(route.input_amount),
        decimal_string(route.expected_output_amount),
        decimal_string(route.minimum_output_amount),
        downcase(route.spender),
        downcase(route.swap_target_contract),
        decimal_string(route.value),
        route.route_provider,
        DateTime.to_iso8601(route.quote_timestamp),
        DateTime.to_iso8601(route.deadline),
        Integer.to_string(route.slippage_bps)
      ]
      |> Enum.join("|")

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp persisted_steps(route, hash) do
    %{
      "kind" => "swap",
      "route_hash" => hash,
      "route_provider" => route.route_provider,
      "chain" => route.chain,
      "chain_id" => route.chain_id,
      "source_asset" => route.source_asset,
      "destination_asset" => route.destination_asset,
      "source_token_address" => route.source_token_address,
      "destination_token_address" => route.destination_token_address,
      "input_amount" => decimal_string(route.input_amount),
      "expected_output_amount" => decimal_string(route.expected_output_amount),
      "minimum_output_amount" => decimal_string(route.minimum_output_amount),
      "spender" => route.spender,
      "swap_target_contract" => route.swap_target_contract,
      "value" => decimal_string(route.value),
      "calldata" => route.calldata,
      "slippage_bps" => route.slippage_bps,
      "quote_timestamp" => DateTime.to_iso8601(route.quote_timestamp),
      "deadline" => DateTime.to_iso8601(route.deadline)
    }
  end

  defp downcase(s) when is_binary(s), do: String.downcase(s)

  defp decimal_string(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)
end
