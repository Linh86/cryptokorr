defmodule Bank.Decisions.SwapRouteResolver do
  @moduledoc """
  Convert a real quote-provider response into an executable
  `Bank.Intents.SwapRoute.t()` map suitable for
  `Bank.Decisions.approve/2`'s `:swap_route` option.

  This module replaces the prior synthetic `sandbox_swap_route` that
  shipped `calldata: "0xdeadbeef"` and dummy router addresses. It
  fans out to `Bank.Stablecoins.RouteSelector.select/2` and accepts
  ONLY routes that carry real, executable on-chain calldata in the
  provider metadata.

  ## What it accepts

    * `route_quote.provider == "zerox"` — the only stablecoin
      provider in v0.1 that returns raw `transaction.to/data/value`
      bytes the dispatch worker can hand to the adapter.
    * `route_quote.provider_metadata["transaction"]` is a map with
      non-empty hex `"data"` and a non-empty hex `"to"` target.
    * The first leg carries a non-empty `"allowanceTarget"` in its
      metadata (the spender the smart account approves before the
      swap call).

  Anything else — `oneinch` / `circle_cctp` / `jupiter` (none
  executable today), missing `transaction`, empty `data`, the
  synthetic sentinel `"0xdeadbeef"`, missing `allowanceTarget` — is
  rejected with a stable atom. The resolver never falls back to a
  hand-built route.

  ## Failure mode atoms

  Every failure is one of:

    * `:missing_taker_address` — no smart account address passed
      in opts.
    * `:invalid_amount` — `intent_payload["amount"]` missing,
      non-positive, or unparseable.
    * `:invalid_chain` — `intent_payload["chain"]` missing or empty.
    * `:invalid_source_asset` — `intent_payload["asset"]` missing
      or empty.
    * `{:quote_request_build, reason}` — `QuoteRequest.build/1`
      rejected the request (e.g. `:unsupported_source_chain` for
      base-sepolia, which the stablecoin registry doesn't list).
    * `{:route_unavailable, reason}` — `RouteSelector.select/2`
      returned `{:error, reason}`.
    * `:non_executable_provider` — the selected quote came from a
      provider that doesn't expose executable calldata.
    * `:missing_executable_transaction` — provider metadata had no
      `"transaction"` map.
    * `:missing_calldata` — `transaction["data"]` is absent or
      empty.
    * `:synthetic_calldata_rejected` — `transaction["data"]` is the
      `"0xdeadbeef"` sentinel left over from the prior sandbox.
    * `:missing_transaction_target` — `transaction["to"]` is absent
      or empty.
    * `:missing_spender` — leg metadata has no `allowanceTarget`.

  All errors are stable atoms / `{atom, atom}` tuples — no raw
  HTTP body, calldata blob, or provider error term leaks into the
  failure reason. The LiveView humanises them into operator-facing
  copy.

  ## Secret hygiene

  This module never logs, inspects, or persists calldata, taker
  addresses, or any other potentially-sensitive material. The
  returned route map carries the calldata as a `String.t()`; that
  blob lives on the persisted plan and the audit row downstream.

  ## Test injection

  `resolve/2` accepts these keyword opts:

    * `:taker_address` (REQUIRED) — the on-chain smart account
      address the swap will execute from. Passed to the provider
      as the 0x `taker`.
    * `:dest_asset` — destination asset string. Defaults to
      `"USDT"` (the canonical USDC -> USDT swap the Test Intent
      uses).
    * `:caps` — `Bank.Intents.SwapRoute.caps()`-shaped map. The
      resolver uses `max_slippage_bps` as the QuoteRequest's
      slippage bound; the same map should be passed downstream as
      `swap_route_caps:` so the dispatch worker re-validates
      against identical caps.
    * `:selector` — module-like keyword that replaces
      `Bank.Stablecoins.RouteSelector` in tests. Defaults to the
      real selector. The injected module must export `select/2`.
    * `:providers` — passed through to `RouteSelector.select/2`
      verbatim (`providers: list_of_modules`).
    * `:now` — `DateTime.t()` for `quote_timestamp` / `deadline`.
      Tests pin a deterministic moment; production defaults to
      `DateTime.utc_now/0`.
  """

  alias Bank.Stablecoins.{QuoteRequest, RouteQuote, RouteSelector}

  @type error ::
          :missing_taker_address
          | :invalid_amount
          | :invalid_chain
          | :invalid_source_asset
          | {:quote_request_build, atom()}
          | {:route_unavailable, term()}
          | :non_executable_provider
          | :missing_executable_transaction
          | :missing_calldata
          | :synthetic_calldata_rejected
          | :missing_transaction_target
          | :missing_spender

  # The synthetic placeholder the prior `sandbox_swap_route` shipped.
  # We reject it explicitly so a stale upstream payload can never
  # reintroduce it through a back door.
  @synthetic_calldata "0xdeadbeef"

  # Deadline window matches the prior sandbox + most provider TTLs
  # (`Bank.Quotes.Preview.freshness_ttl_seconds`-adjacent). 10 minutes
  # gives the dispatch worker headroom across Oban retries.
  @deadline_seconds 600

  @doc """
  Resolve an executable swap route for `intent_payload`.

  `intent_payload` is the same map shape the LiveView submits to
  `Bank.Intents.submit_async/3` — required string keys: `"chain"`,
  `"asset"`, `"amount"`.

  Returns `{:ok, route_map}` only when every required SwapRoute
  field can be sourced from a real provider response. Otherwise
  `{:error, error()}` — see module docs for the atom vocabulary.
  """
  @spec resolve(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def resolve(intent_payload, opts) when is_map(intent_payload) and is_list(opts) do
    with {:ok, taker} <- require_taker(opts),
         {:ok, chain} <- require_chain(intent_payload),
         {:ok, source_asset} <- require_source_asset(intent_payload),
         {:ok, amount} <- require_amount(intent_payload),
         caps <- caps_from_opts(opts),
         dest_asset <- Keyword.get(opts, :dest_asset, "USDT"),
         {:ok, request} <-
           build_quote_request(chain, source_asset, dest_asset, amount, caps, taker),
         {:ok, route_quote} <- run_selector(request, opts),
         :ok <- require_zerox(route_quote),
         {:ok, transaction} <- require_transaction(route_quote),
         {:ok, target} <- require_target(transaction),
         {:ok, calldata} <- require_calldata(transaction),
         {:ok, spender} <- require_spender(route_quote) do
      {:ok, build_route_map(route_quote, transaction, target, calldata, spender, caps, opts)}
    end
  end

  # ── Input extraction ───────────────────────────────────────────────

  defp require_taker(opts) do
    case Keyword.get(opts, :taker_address) do
      addr when is_binary(addr) and addr != "" -> {:ok, addr}
      _ -> {:error, :missing_taker_address}
    end
  end

  defp require_chain(payload) do
    case Map.get(payload, "chain") || Map.get(payload, :chain) do
      chain when is_binary(chain) and chain != "" -> {:ok, chain}
      _ -> {:error, :invalid_chain}
    end
  end

  defp require_source_asset(payload) do
    case Map.get(payload, "asset") || Map.get(payload, :asset) do
      asset when is_binary(asset) and asset != "" -> {:ok, asset}
      _ -> {:error, :invalid_source_asset}
    end
  end

  defp require_amount(payload) do
    raw = Map.get(payload, "amount") || Map.get(payload, :amount)

    case raw do
      %Decimal{} = d ->
        if Decimal.compare(d, Decimal.new(0)) == :gt,
          do: {:ok, d},
          else: {:error, :invalid_amount}

      s when is_binary(s) and s != "" ->
        case Decimal.parse(s) do
          {%Decimal{} = d, ""} ->
            if Decimal.compare(d, Decimal.new(0)) == :gt,
              do: {:ok, d},
              else: {:error, :invalid_amount}

          _ ->
            {:error, :invalid_amount}
        end

      _ ->
        {:error, :invalid_amount}
    end
  end

  defp caps_from_opts(opts) do
    Keyword.get(opts, :caps) || Bank.Intents.SwapRoute.caps()
  end

  # ── Provider plumbing ──────────────────────────────────────────────

  defp build_quote_request(chain, source_asset, dest_asset, amount, caps, taker) do
    case QuoteRequest.build(%{
           source_chain: chain,
           source_asset: source_asset,
           dest_chain: chain,
           dest_asset: dest_asset,
           amount: amount,
           slippage_bps: caps.max_slippage_bps,
           metadata: %{taker_address: taker}
         }) do
      {:ok, %QuoteRequest{} = req} -> {:ok, req}
      {:error, reason} -> {:error, {:quote_request_build, reason}}
    end
  end

  defp run_selector(request, opts) do
    selector = Keyword.get(opts, :selector, RouteSelector)

    selector_opts =
      case Keyword.fetch(opts, :providers) do
        {:ok, list} -> [providers: list]
        :error -> []
      end

    case selector.select(request, selector_opts) do
      {:ok, %RouteQuote{} = quote_, _meta} -> {:ok, quote_}
      {:error, reason} -> {:error, {:route_unavailable, reason}}
    end
  end

  # ── Provider-shape gates ───────────────────────────────────────────

  defp require_zerox(%RouteQuote{provider: "zerox"}), do: :ok
  defp require_zerox(%RouteQuote{}), do: {:error, :non_executable_provider}

  defp require_transaction(%RouteQuote{provider_metadata: meta}) when is_map(meta) do
    case Map.get(meta, "transaction") do
      tx when is_map(tx) -> {:ok, tx}
      _ -> {:error, :missing_executable_transaction}
    end
  end

  defp require_transaction(_), do: {:error, :missing_executable_transaction}

  defp require_target(transaction) do
    case Map.get(transaction, "to") do
      addr when is_binary(addr) and addr != "" -> {:ok, addr}
      _ -> {:error, :missing_transaction_target}
    end
  end

  defp require_calldata(transaction) do
    case Map.get(transaction, "data") do
      nil ->
        {:error, :missing_calldata}

      "" ->
        {:error, :missing_calldata}

      "0x" ->
        {:error, :missing_calldata}

      data when is_binary(data) ->
        cond do
          String.downcase(data) == @synthetic_calldata ->
            {:error, :synthetic_calldata_rejected}

          true ->
            {:ok, data}
        end

      _ ->
        {:error, :missing_calldata}
    end
  end

  defp require_spender(%RouteQuote{legs: [%{metadata: meta} | _]}) when is_map(meta) do
    case Map.get(meta, "allowanceTarget") do
      addr when is_binary(addr) and addr != "" -> {:ok, addr}
      _ -> {:error, :missing_spender}
    end
  end

  defp require_spender(_), do: {:error, :missing_spender}

  # ── Route projection ───────────────────────────────────────────────

  defp build_route_map(%RouteQuote{} = quote_, transaction, target, calldata, spender, caps, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)
    request = quote_.request
    chain = request.source_chain

    %{
      source_asset: request.source_asset,
      source_token_address: request.source_token.address,
      destination_asset: request.dest_asset,
      destination_token_address: request.dest_token.address,
      input_amount: quote_.input_amount,
      expected_output_amount: quote_.output_amount,
      minimum_output_amount: minimum_output(quote_),
      spender: spender,
      swap_target_contract: target,
      calldata: calldata,
      value: parse_native_value(transaction),
      route_provider: quote_.provider,
      quote_timestamp: quote_.quoted_at,
      deadline: deadline(quote_, now),
      chain: chain,
      chain_id: chain_id_for(chain),
      slippage_bps: caps.max_slippage_bps
    }
  end

  # Provider metadata's `minBuyAmount` is the operator-facing slippage
  # floor. If the provider didn't return it (older 0x v1 responses),
  # fall back to the `output_amount` itself — `SwapRoute.validate/2`
  # only requires `minimum <= expected`, and the dispatch worker
  # enforces the real on-chain min via the calldata anyway.
  defp minimum_output(%RouteQuote{} = quote_) do
    case Map.get(quote_.provider_metadata || %{}, "minBuyAmount") do
      raw when is_binary(raw) or is_integer(raw) ->
        case parse_base_units(raw, quote_.request.dest_token.decimals) do
          {:ok, decimal} -> decimal
          _ -> quote_.output_amount
        end

      _ ->
        quote_.output_amount
    end
  end

  defp deadline(%RouteQuote{expires_at: %DateTime{} = exp}, _now),
    do: DateTime.truncate(exp, :microsecond)

  defp deadline(_quote, %DateTime{} = now), do: DateTime.add(now, @deadline_seconds, :second)

  defp parse_native_value(transaction) do
    case Map.get(transaction, "value") do
      nil ->
        Decimal.new(0)

      0 ->
        Decimal.new(0)

      n when is_integer(n) and n >= 0 ->
        Decimal.new(n)

      "0" ->
        Decimal.new(0)

      "0x" <> hex when is_binary(hex) ->
        case Integer.parse(hex, 16) do
          {n, ""} when n >= 0 -> Decimal.new(n)
          _ -> Decimal.new(0)
        end

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> Decimal.new(n)
          _ -> Decimal.new(0)
        end

      _ ->
        Decimal.new(0)
    end
  end

  defp parse_base_units(raw, decimals) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 ->
        {:ok, Decimal.div(Decimal.new(n), Decimal.new(Integer.pow(10, decimals)))}

      _ ->
        :error
    end
  end

  defp parse_base_units(raw, decimals) when is_integer(raw) and raw >= 0 do
    {:ok, Decimal.div(Decimal.new(raw), Decimal.new(Integer.pow(10, decimals)))}
  end

  defp parse_base_units(_, _), do: :error

  defp chain_id_for(chain), do: Bank.Intents.SwapRoute.chain_id_for(chain)
end
