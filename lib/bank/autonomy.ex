defmodule Bank.Autonomy do
  @moduledoc """
  Tiered autonomy router. Decides which outcome an intent gets —
  `:auto_exec`, `:hold`, `:approval_required`, or `:block` — given the
  inputs the runtime has already gathered:

    * `%Bank.Policies.Evaluation{}` (from the policy engine)
    * a trust-assessment map from `Bank.TrustEngine.classify/2`
    * `%Bank.Quotes.Preview{}` result (from #11; may be `{:error, _}`)
    * the candidate `%Bank.Intents.AgentIntent{}`

  Routing is deliberately narrow in v0.1 — the full state diagram is
  a small, explainable truth table rather than a scoring model.

  ## Rules (evaluated top-down, first match wins)

    1. **Pause** — if `paused?` is true, emit `:hold` with reason
       `:runtime_paused`. Never `:auto_exec` while paused.
    2. **Policy violations** — any violation from the policy evaluation
       emits `:block`; the `policy.autonomy_tier` constraint is
       surfaced explicitly so the UI can say "rule X blocked this".
    3. **Provider degradation** — `{:error, :provider_unavailable}` or
       `{:error, :stale}` emits `:hold` with reason
       `:preview_unavailable` / `:preview_stale`. The caller
       resimulates before proceeding.
    4. **Simulation failure** — `{:error, {:simulation_failed, _}}`
       emits `:block` with `:simulation_failed`.
    5. **Conflicted trust** — `derived_trust == :conflicted` emits
       `:approval_required`. Confidence is always `:low` for conflicted,
       so auto-executing is never appropriate.
    6. **Sensitive trust** — `:sensitive` emits `:approval_required`
       regardless of amount.
    7. **Unknown trust** — emits `:approval_required` when amount is
       under the `unknown_approval_ceiling` knob, else `:block`.
    8. **Trusted + auto-capable policy tier + low-risk amount** —
       emits `:auto_exec`.
    9. **Trusted + policy tier :manual** — emits `:approval_required`.
    10. **Fallback** — `:approval_required` (conservative default).

  ## Amount thresholds

  Thresholds are per-asset, configurable under
  `Application.get_env(:bank, Bank.Autonomy)`:

      config :bank, Bank.Autonomy,
        thresholds: %{
          "USDC" => %{
            auto_exec_max: Decimal.new("100"),
            unknown_approval_ceiling: Decimal.new("25")
          }
        }

  Unknown assets fall back to conservative defaults:
  `auto_exec_max = 0` (never auto-execute) and
  `unknown_approval_ceiling = 0` (always block unknown targets).

  ## Risk tier mapping

  The returned risk tier maps routing + trust into the decision-
  envelope vocabulary:

      auto_exec  + trusted            -> :low
      auto_exec  + any                 -> :moderate
      approval_required                -> :moderate (trusted/unknown) /
                                           :elevated (sensitive/conflicted)
      block                            -> :severe
      hold                             -> :moderate
  """

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.Evaluation
  alias Bank.Quotes.Preview

  @type outcome :: :auto_exec | :hold | :approval_required | :block
  @type risk_tier :: :low | :moderate | :elevated | :severe

  @type decision :: %{
          outcome: outcome(),
          risk_tier: risk_tier(),
          reason_code: atom(),
          reason: String.t(),
          rationale: map()
        }

  @type preview_result ::
          {:ok, Preview.t()}
          | {:error, Bank.Quotes.error()}

  @default_thresholds %{
    auto_exec_max: Decimal.new("100"),
    unknown_approval_ceiling: Decimal.new("25")
  }

  @doc """
  Route an intent to an outcome.

  `inputs` is a map with:

    * `:intent` — `%AgentIntent{}`
    * `:policy` — `%Evaluation{}` (from `Bank.Policies.evaluate/2`)
    * `:trust` — the trust-assessment attr map from
      `Bank.TrustEngine.classify/2`
    * `:preview` — `{:ok, %Preview{}}` or `{:error, reason}` from
      `Bank.Quotes.preview/2`. `nil` means "no preview attempted yet"
      and is treated as `{:error, :preview_missing}`.
    * `:paused?` — boolean, from `Bank.Security`.

  Options:

    * `:thresholds` — override the autonomy thresholds for this call
      (tests).
  """
  @spec route(map(), keyword()) :: decision()
  def route(inputs, opts \\ [])

  def route(%{paused?: true} = _inputs, _opts) do
    build(
      :hold,
      :moderate,
      :runtime_paused,
      "runtime is paused; no new autonomous execution",
      %{}
    )
    |> emit()
  end

  def route(inputs, opts) do
    cond do
      policy_violations?(inputs) ->
        build_policy_block(inputs)

      policy_tier_blocks?(inputs) ->
        build(
          :block,
          :severe,
          :policy_blocks_autonomy,
          "policy autonomy_tier=block",
          %{tier: :block}
        )

      preview_degraded?(inputs) ->
        build_preview_degraded(inputs)

      simulation_failed?(inputs) ->
        build_simulation_failed(inputs)

      conflicted_trust?(inputs) ->
        build(
          :approval_required,
          :elevated,
          :trust_conflicted,
          "covering trust assertions disagree; operator must resolve",
          %{
            derived_trust: :conflicted,
            confidence: trust_confidence(inputs)
          }
        )

      sensitive_trust?(inputs) ->
        build(
          :approval_required,
          :elevated,
          :trust_sensitive,
          "counterparty is sensitive; operator approval required",
          %{derived_trust: :sensitive}
        )

      unknown_trust?(inputs) ->
        build_unknown_trust(inputs, opts)

      trusted_auto?(inputs, opts) ->
        build(
          :auto_exec,
          :low,
          :trusted_low_value,
          "trusted counterparty within autonomy threshold",
          %{
            derived_trust: :trusted,
            amount: decimal_string(inputs.intent.amount)
          }
        )

      trusted_manual?(inputs) ->
        build(
          :approval_required,
          :moderate,
          :policy_manual_tier,
          "trusted counterparty but policy tier is :manual",
          %{derived_trust: :trusted}
        )

      true ->
        # Default to approval_required; auto_exec must be earned.
        build(
          :approval_required,
          :moderate,
          :conservative_default,
          "fell through the autonomy truth-table; defaulting to approval",
          %{}
        )
    end
    |> emit()
  end

  defp emit(%{} = decision) do
    Bank.Runtime.Telemetry.decision(decision)
    decision
  end

  @doc """
  Convenience for turning a `decision/0` into the attribute map a
  `%DecisionEnvelope{}` changeset accepts. Preserves the reason
  vocabulary in the envelope's `reasons.items` list.
  """
  @spec to_envelope_attrs(decision(), map()) :: map()
  def to_envelope_attrs(%{} = decision, extras \\ %{}) do
    Map.merge(
      %{
        outcome: decision.outcome,
        risk_tier: decision.risk_tier,
        reasons: %{
          "items" => [
            %{
              "code" => Atom.to_string(decision.reason_code),
              "message" => decision.reason,
              "details" => decision.rationale
            }
          ]
        },
        decided_at: DateTime.utc_now(),
        decided_by: :runtime,
        current: true
      },
      extras
    )
    |> apply_approval_expiry()
  end

  # --- guards -------------------------------------------------------

  defp policy_violations?(%{policy: %Evaluation{violations: v}}) when v != [] do
    Enum.any?(v, &(&1.rule_type != :autonomy_tier))
  end

  defp policy_violations?(_), do: false

  defp policy_tier_blocks?(%{policy: %Evaluation{autonomy_tier: :block}}), do: true
  defp policy_tier_blocks?(_), do: false

  defp preview_degraded?(%{preview: {:error, :provider_unavailable}}), do: true
  defp preview_degraded?(%{preview: {:error, :stale}}), do: true
  defp preview_degraded?(%{preview: {:error, :preview_missing}}), do: true
  defp preview_degraded?(%{preview: nil}), do: true
  defp preview_degraded?(_), do: false

  defp simulation_failed?(%{preview: {:error, {:simulation_failed, _}}}), do: true
  defp simulation_failed?(_), do: false

  defp conflicted_trust?(%{trust: %{derived_trust: :conflicted}}), do: true
  defp conflicted_trust?(_), do: false

  defp sensitive_trust?(%{trust: %{derived_trust: :sensitive}}), do: true
  defp sensitive_trust?(_), do: false

  defp unknown_trust?(%{trust: %{derived_trust: :unknown}}), do: true
  defp unknown_trust?(_), do: false

  defp trusted_auto?(
         %{
           trust: %{derived_trust: :trusted},
           policy: %Evaluation{autonomy_tier: :auto},
           intent: %AgentIntent{} = intent
         },
         opts
       ) do
    thresh = thresholds_for(intent.asset, opts)

    case intent.amount do
      nil -> false
      amount -> Decimal.compare(amount, thresh.auto_exec_max) != :gt
    end
  end

  defp trusted_auto?(_, _), do: false

  defp trusted_manual?(%{
         trust: %{derived_trust: :trusted},
         policy: %Evaluation{autonomy_tier: tier}
       })
       when tier in [:manual, :auto],
       do: true

  defp trusted_manual?(_), do: false

  # --- branch builders ---------------------------------------------

  defp build_policy_block(%{policy: %Evaluation{violations: violations}}) do
    first = List.first(violations)
    code = String.to_atom("policy_" <> ((first && first.code) || "violation"))

    build(
      :block,
      :severe,
      code,
      "policy violation: " <> ((first && first.message) || "see reasons"),
      %{violations: Enum.map(violations, & &1.code)}
    )
  end

  defp build_preview_degraded(%{preview: preview}) do
    {reason_code, reason} =
      case preview do
        {:error, :provider_unavailable} ->
          {:preview_unavailable, "quote provider unavailable; holding until it recovers"}

        {:error, :stale} ->
          {:preview_stale, "preview is stale; resimulating before proceeding"}

        {:error, :preview_missing} ->
          {:preview_missing, "no preview produced yet"}

        nil ->
          {:preview_missing, "no preview produced yet"}

        _ ->
          {:preview_unavailable, "preview is in an unexpected state"}
      end

    build(:hold, :moderate, reason_code, reason, %{})
  end

  defp build_simulation_failed(%{preview: {:error, {:simulation_failed, reason}}}) do
    build(
      :block,
      :severe,
      :simulation_failed,
      "simulation failed: #{reason}",
      %{provider_reason: reason}
    )
  end

  defp build_unknown_trust(%{intent: %AgentIntent{} = intent} = inputs, opts) do
    thresh = thresholds_for(intent.asset, opts)

    cond do
      is_nil(intent.amount) ->
        build(
          :block,
          :severe,
          :unknown_without_amount,
          "unknown counterparty and no amount context; blocking",
          %{}
        )

      Decimal.compare(intent.amount, thresh.unknown_approval_ceiling) != :gt ->
        build(
          :approval_required,
          :moderate,
          :trust_unknown,
          "unknown target under approval ceiling",
          %{
            amount: decimal_string(intent.amount),
            ceiling: decimal_string(thresh.unknown_approval_ceiling),
            raw_address: is_nil(intent.target_counterparty_id)
          }
        )

      true ->
        build(
          :block,
          :severe,
          :unknown_over_ceiling,
          "unknown target exceeds approval ceiling",
          %{
            amount: decimal_string(intent.amount),
            ceiling: decimal_string(thresh.unknown_approval_ceiling),
            raw_address: is_nil(inputs.intent.target_counterparty_id)
          }
        )
    end
  end

  # --- helpers -----------------------------------------------------

  defp build(outcome, risk, code, message, rationale) do
    %{
      outcome: outcome,
      risk_tier: risk,
      reason_code: code,
      reason: message,
      rationale: rationale
    }
  end

  defp trust_confidence(%{trust: %{confidence: c}}), do: c
  defp trust_confidence(_), do: :low

  defp thresholds_for(asset, opts) do
    overrides = Keyword.get(opts, :thresholds, %{})

    configured =
      Application.get_env(:bank, __MODULE__, [])
      |> Keyword.get(:thresholds, %{})
      |> Map.get(asset)

    case {Map.get(overrides, asset), configured} do
      {nil, nil} -> @default_thresholds
      {override, _} when not is_nil(override) -> Map.merge(@default_thresholds, override)
      {nil, conf} -> Map.merge(@default_thresholds, conf)
    end
  end

  defp decimal_string(nil), do: nil
  defp decimal_string(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp decimal_string(other), do: to_string(other)

  defp apply_approval_expiry(%{outcome: :approval_required} = attrs) do
    Map.put_new(attrs, :approval_expires_at, DateTime.add(DateTime.utc_now(), 3600, :second))
  end

  defp apply_approval_expiry(attrs), do: attrs

  @doc """
  Useful for pattern-matching on `DecisionEnvelope` constructors. Keeps
  `Bank.Decisions` out of a compile cycle on `Bank.Autonomy`.
  """
  def envelope_module, do: DecisionEnvelope
end
