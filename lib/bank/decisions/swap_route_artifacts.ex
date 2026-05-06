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

  @doc """
  Reconstitute a canonical `Bank.Intents.SwapRoute.t()` map from a
  plan's persisted `:steps` (#193).

  `from_route/1` writes string keys with JSON-friendly scalar
  encodings (`Decimal` → string, `DateTime` → ISO8601). Dispatch
  call sites need the canonical atom-keyed shape so they can run
  `Bank.Decisions.SwapDispatchSafety.validate/3` without
  re-parsing route fields by hand.

  Returns `{:ok, route}` for a well-shaped persisted swap step or
  `{:error, :not_a_swap}` for a steps map that does not carry the
  swap kind marker. Returns `{:error, {:malformed_steps, field}}`
  when a load-bearing field cannot be parsed (decimal /
  datetime / integer); the safety gate's structural check then
  surfaces the failure in the same vocabulary as routes that
  never made it past validation.
  """
  @spec route_from_steps(map()) ::
          {:ok, SwapRoute.t()} | {:error, :not_a_swap | {:malformed_steps, atom()}}
  def route_from_steps(%{"kind" => "swap"} = steps) do
    with {:ok, input_amount} <- parse_decimal(steps, "input_amount"),
         {:ok, expected_output} <- parse_decimal(steps, "expected_output_amount"),
         {:ok, minimum_output} <- parse_decimal(steps, "minimum_output_amount"),
         {:ok, value} <- parse_decimal(steps, "value"),
         {:ok, quote_ts} <- parse_datetime(steps, "quote_timestamp"),
         {:ok, deadline} <- parse_datetime(steps, "deadline"),
         {:ok, chain_id} <- parse_integer(steps, "chain_id"),
         {:ok, slippage_bps} <- parse_integer(steps, "slippage_bps") do
      {:ok,
       %{
         source_asset: Map.get(steps, "source_asset"),
         source_token_address: Map.get(steps, "source_token_address"),
         destination_asset: Map.get(steps, "destination_asset"),
         destination_token_address: Map.get(steps, "destination_token_address"),
         input_amount: input_amount,
         expected_output_amount: expected_output,
         minimum_output_amount: minimum_output,
         spender: Map.get(steps, "spender"),
         swap_target_contract: Map.get(steps, "swap_target_contract"),
         calldata: Map.get(steps, "calldata"),
         value: value,
         route_provider: Map.get(steps, "route_provider"),
         quote_timestamp: quote_ts,
         deadline: deadline,
         chain: Map.get(steps, "chain"),
         chain_id: chain_id,
         slippage_bps: slippage_bps
       }}
    end
  end

  def route_from_steps(_), do: {:error, :not_a_swap}

  defp parse_decimal(steps, key) do
    case Map.get(steps, key) do
      v when is_binary(v) ->
        case Decimal.parse(v) do
          {dec, ""} -> {:ok, dec}
          _ -> {:error, {:malformed_steps, String.to_atom(key)}}
        end

      _ ->
        {:error, {:malformed_steps, String.to_atom(key)}}
    end
  end

  defp parse_datetime(steps, key) do
    case Map.get(steps, key) do
      v when is_binary(v) ->
        case DateTime.from_iso8601(v) do
          {:ok, dt, _offset} -> {:ok, dt}
          _ -> {:error, {:malformed_steps, String.to_atom(key)}}
        end

      _ ->
        {:error, {:malformed_steps, String.to_atom(key)}}
    end
  end

  defp parse_integer(steps, key) do
    case Map.get(steps, key) do
      v when is_integer(v) -> {:ok, v}
      _ -> {:error, {:malformed_steps, String.to_atom(key)}}
    end
  end

  defp downcase(s) when is_binary(s), do: String.downcase(s)

  defp decimal_string(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)
end
