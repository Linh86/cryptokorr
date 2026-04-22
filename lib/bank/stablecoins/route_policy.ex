defmodule Bank.Stablecoins.RoutePolicy do
  @moduledoc """
  Scoring, fee engine, and policy gating for stablecoin routes.

  Sits on top of `Bank.Stablecoins.RouteSelector.select/2` and
  produces a machine-readable routing decision:

    * `:allowed` — route may execute without manual approval
    * `:approval_required` — route needs operator sign-off
    * `:blocked` — route must not execute

  ## Scoring

  Deterministic score for each candidate based on:

    1. Output efficiency (output / input ratio)
    2. Fee penalty (total_fee / input)
    3. ETA penalty (higher ETA → lower score)
    4. Risk flags penalty
    5. Token status / canonicality penalty

  ## Fee engine

  Produces a transparent `fee_summary` with categorized breakdown:

    * provider/protocol fee
    * bridge fee
    * gas fee
    * CryptoBank fee (configurable bps on input amount)
    * total fee (sum of all)
    * output impact (input − output as percentage)

  ## Policy gating

  Enforces registry token status truthfully:

    * `:blocked` tokens → decision `:blocked`
    * `:approval_only` tokens → decision `:approval_required`
    * non-canonical tokens → decision `:approval_required`

  Plus configurable thresholds:

    * max amount per route (above → `:approval_required`)
    * max fee bps (above → `:blocked`)
    * allowed route kinds
    * allowed chains
  """

  alias Bank.Stablecoins.{QuoteRequest, RouteQuote, RouteSelector}

  @type decision :: :allowed | :approval_required | :blocked

  @type evaluation :: %{
          decision: decision(),
          reasons: [reason()],
          score: float(),
          fee_summary: fee_summary(),
          quote: RouteQuote.t(),
          request: QuoteRequest.t(),
          selector_metadata: map()
        }

  @type reason :: %{
          rule: atom(),
          detail: String.t(),
          severity: :block | :approval | :info
        }

  @type fee_summary :: %{
          gas_fee: Decimal.t() | nil,
          protocol_fee: Decimal.t() | nil,
          bridge_fee: Decimal.t() | nil,
          cryptobank_fee: Decimal.t() | nil,
          total_fee: Decimal.t(),
          output_impact_pct: Decimal.t()
        }

  @default_cryptobank_fee_bps 10
  @default_max_amount nil
  @default_max_fee_bps 500

  @doc """
  Evaluate a quote request end-to-end: select route, score, gate.

  Options:
    * `:providers` / `:swap_providers` / `:bridge_providers` — passed to RouteSelector
    * `:cryptobank_fee_bps` — CryptoBank fee in basis points (default 10)
    * `:max_amount` — approval threshold (default nil = no limit)
    * `:max_fee_bps` — block if total fee exceeds this (default 500)
    * `:allowed_chains` — list of allowed chains (default nil = all)
    * `:allowed_route_kinds` — list of allowed route kinds (default nil = all)
    * `:allow_non_canonical` — opt in to non-canonical token routes without approval
  """
  @spec evaluate(QuoteRequest.t(), keyword()) ::
          {:ok, evaluation()} | {:error, term()}
  def evaluate(%QuoteRequest{} = req, opts \\ []) do
    selector_opts = Keyword.take(opts, [:providers, :swap_providers, :bridge_providers])

    case RouteSelector.select(req, selector_opts) do
      {:ok, route_quote, selector_meta} ->
        eval = build_evaluation(req, route_quote, selector_meta, opts)
        {:ok, eval}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Evaluate a pre-selected quote (skip route selection).
  """
  @spec evaluate_quote(QuoteRequest.t(), RouteQuote.t(), map(), keyword()) :: evaluation()
  def evaluate_quote(
        %QuoteRequest{} = req,
        %RouteQuote{} = route_quote,
        selector_meta,
        opts \\ []
      ) do
    build_evaluation(req, route_quote, selector_meta, opts)
  end

  # -- Evaluation builder ---------------------------------------------------

  defp build_evaluation(req, route_quote, selector_meta, opts) do
    fee_summary = compute_fee_summary(req, route_quote, opts)
    reasons = collect_reasons(req, route_quote, fee_summary, opts)
    decision = derive_decision(reasons)
    score = compute_score(req, route_quote, fee_summary, reasons)

    %{
      decision: decision,
      reasons: reasons,
      score: score,
      fee_summary: fee_summary,
      quote: route_quote,
      request: req,
      selector_metadata: selector_meta
    }
  end

  # -- Fee engine -----------------------------------------------------------

  defp compute_fee_summary(req, route_quote, opts) do
    cb_bps = Keyword.get(opts, :cryptobank_fee_bps, @default_cryptobank_fee_bps)

    cryptobank_fee =
      req.amount
      |> Decimal.mult(Decimal.new(cb_bps))
      |> Decimal.div(Decimal.new(10_000))

    provider_fee = route_quote.fees[:protocol_fee]
    bridge_fee = route_quote.fees[:bridge_fee]
    gas_fee = route_quote.fees[:gas_fee]
    raw_total = route_quote.fees[:total_fee] || Decimal.new(0)

    total_fee = Decimal.add(raw_total, cryptobank_fee)

    output_impact_pct =
      if Decimal.compare(req.amount, Decimal.new(0)) == :gt do
        req.amount
        |> Decimal.sub(route_quote.output_amount)
        |> Decimal.div(req.amount)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.round(4)
      else
        Decimal.new(0)
      end

    %{
      gas_fee: gas_fee,
      protocol_fee: provider_fee,
      bridge_fee: bridge_fee,
      cryptobank_fee: cryptobank_fee,
      total_fee: total_fee,
      output_impact_pct: output_impact_pct
    }
  end

  # -- Policy rules ---------------------------------------------------------

  defp collect_reasons(req, route_quote, fee_summary, opts) do
    []
    |> check_token_status(req)
    |> check_token_canonical(req, opts)
    |> check_amount_threshold(req, opts)
    |> check_fee_threshold(req, fee_summary, opts)
    |> check_allowed_chains(req, opts)
    |> check_allowed_route_kinds(route_quote, opts)
    |> check_risk_flags(route_quote)
  end

  defp check_token_status(reasons, req) do
    reasons
    |> maybe_add_token_reason(req.source_token, :source)
    |> maybe_add_token_reason(req.dest_token, :dest)
  end

  defp maybe_add_token_reason(reasons, %{status: :blocked} = token, side) do
    reason = %{
      rule: :token_blocked,
      detail: "#{side} token #{token[:asset]} on #{token[:chain]} is blocked",
      severity: :block
    }

    [reason | reasons]
  end

  defp maybe_add_token_reason(reasons, %{status: :approval_only} = token, side) do
    reason = %{
      rule: :token_approval_only,
      detail: "#{side} token #{token[:asset]} on #{token[:chain]} requires approval",
      severity: :approval
    }

    [reason | reasons]
  end

  defp maybe_add_token_reason(reasons, _, _), do: reasons

  defp check_token_canonical(reasons, req, opts) do
    if Keyword.get(opts, :allow_non_canonical, false) do
      reasons
    else
      reasons
      |> maybe_add_canonical_reason(req.source_token, :source)
      |> maybe_add_canonical_reason(req.dest_token, :dest)
    end
  end

  defp maybe_add_canonical_reason(reasons, %{canonical: false} = token, side) do
    reason = %{
      rule: :token_non_canonical,
      detail: "#{side} token #{token[:asset]} on #{token[:chain]} is non-canonical",
      severity: :approval
    }

    [reason | reasons]
  end

  defp maybe_add_canonical_reason(reasons, _, _), do: reasons

  defp check_amount_threshold(reasons, req, opts) do
    max = Keyword.get(opts, :max_amount, @default_max_amount)

    case max do
      nil ->
        reasons

      threshold when is_integer(threshold) ->
        if Decimal.compare(req.amount, Decimal.new(threshold)) == :gt do
          reason = %{
            rule: :amount_above_threshold,
            detail: "amount #{req.amount} exceeds threshold #{threshold}",
            severity: :approval
          }

          [reason | reasons]
        else
          reasons
        end

      %Decimal{} = threshold ->
        if Decimal.compare(req.amount, threshold) == :gt do
          reason = %{
            rule: :amount_above_threshold,
            detail: "amount #{req.amount} exceeds threshold #{threshold}",
            severity: :approval
          }

          [reason | reasons]
        else
          reasons
        end
    end
  end

  defp check_fee_threshold(reasons, req, fee_summary, opts) do
    max_bps = Keyword.get(opts, :max_fee_bps, @default_max_fee_bps)

    if Decimal.compare(req.amount, Decimal.new(0)) == :gt do
      actual_bps =
        fee_summary.total_fee
        |> Decimal.div(req.amount)
        |> Decimal.mult(Decimal.new(10_000))
        |> Decimal.round(0)
        |> Decimal.to_integer()

      if actual_bps > max_bps do
        reason = %{
          rule: :fee_above_threshold,
          detail: "total fee #{actual_bps}bps exceeds max #{max_bps}bps",
          severity: :block
        }

        [reason | reasons]
      else
        reasons
      end
    else
      reasons
    end
  end

  defp check_allowed_chains(reasons, req, opts) do
    case Keyword.get(opts, :allowed_chains) do
      nil ->
        reasons

      chains when is_list(chains) ->
        reasons
        |> check_chain_allowed(req.source_chain, :source, chains)
        |> check_chain_allowed(req.dest_chain, :dest, chains)
    end
  end

  defp check_chain_allowed(reasons, chain, side, allowed) do
    if chain in allowed do
      reasons
    else
      reason = %{
        rule: :chain_not_allowed,
        detail: "#{side} chain #{chain} is not in allowed list",
        severity: :block
      }

      [reason | reasons]
    end
  end

  defp check_allowed_route_kinds(reasons, route_quote, opts) do
    case Keyword.get(opts, :allowed_route_kinds) do
      nil ->
        reasons

      kinds when is_list(kinds) ->
        if route_quote.route_kind in kinds do
          reasons
        else
          reason = %{
            rule: :route_kind_not_allowed,
            detail: "route kind #{route_quote.route_kind} is not in allowed list",
            severity: :block
          }

          [reason | reasons]
        end
    end
  end

  defp check_risk_flags(reasons, route_quote) do
    Enum.reduce(route_quote.risk_flags, reasons, fn flag, acc ->
      reason = %{
        rule: :risk_flag,
        detail: "provider risk flag: #{flag}",
        severity: :approval
      }

      [reason | acc]
    end)
  end

  # -- Decision derivation --------------------------------------------------

  defp derive_decision(reasons) do
    cond do
      Enum.any?(reasons, &(&1.severity == :block)) -> :blocked
      Enum.any?(reasons, &(&1.severity == :approval)) -> :approval_required
      true -> :allowed
    end
  end

  # -- Scoring --------------------------------------------------------------

  defp compute_score(req, route_quote, fee_summary, reasons) do
    output_ratio = safe_ratio(route_quote.output_amount, req.amount)
    fee_ratio = safe_ratio(fee_summary.total_fee, req.amount)
    eta_penalty = eta_penalty(route_quote.eta_seconds)
    risk_penalty = length(route_quote.risk_flags) * 0.02
    reason_penalty = length(Enum.filter(reasons, &(&1.severity == :approval))) * 0.01

    base = Decimal.to_float(output_ratio)
    penalty = Decimal.to_float(fee_ratio) + eta_penalty + risk_penalty + reason_penalty

    Float.round(max(base - penalty, 0.0), 6)
  end

  defp safe_ratio(numerator, denominator) do
    if Decimal.compare(denominator, Decimal.new(0)) == :gt do
      Decimal.div(numerator, denominator)
    else
      Decimal.new(0)
    end
  end

  defp eta_penalty(nil), do: 0.0
  defp eta_penalty(seconds) when seconds <= 60, do: 0.0
  defp eta_penalty(seconds) when seconds <= 300, do: 0.01
  defp eta_penalty(seconds) when seconds <= 900, do: 0.03
  defp eta_penalty(_), do: 0.05
end
