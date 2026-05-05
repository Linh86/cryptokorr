defmodule Bank.Decisions.MorphoEvaluator do
  @moduledoc """
  Decision pipeline for `kind: :defi_yield_deposit` intents that
  target a Morpho ERC-4626 vault (#203).

  The Morpho path is structurally distinct from the transfer
  pipeline owned by `Bank.Decisions.run_evaluation/2`:

    * No counterparty trust evaluation. The vault address is the
      "target" and the Morpho risk explanation is the trust-and-risk
      story; an `unknown` counterparty trust would be misleading
      noise on a yield action.
    * No `Bank.Quotes.preview/2` simulation. The transfer preview
      contract (`balance_impact`, `route`, `expected_output`) does
      not describe an ERC-4626 share mint; pre-execution snapshot
      refresh is the equivalent and is owned by the execution
      issue (#206/#207), not this one.
    * No execution dispatch. #203 ships the read-only decision
      surface only — the Morpho `ExecutionPlan` adapter and
      `RunExecution` enqueue path are explicitly out of scope.

  The Morpho path still produces a `DecisionEnvelope` with the
  same v1 outcome / risk-tier vocabulary as the transfer path, so
  the approvals queue, audit/replay surface, and inbox notifier
  consume it without special cases. The `morpho_risk_explanation`
  map is embedded in `reasons.items[0].details.morpho_risk_explanation`
  so replay readers see the structured evidence inline with the
  decision row.

  ## MVP routing

  Per the design doc and #203 acceptance criteria:

    * unknown vault, asset mismatch, severe warning, or empty
      critical allowlist → `:block`
    * stale critical snapshot, missing snapshot, or active
      incident → `:hold`
    * allowlisted low-risk vault → `:approval_required` (never
      `:auto_exec`)
    * Morpho warnings map into `primary_reasons` per the
      `RiskExplanation` aggregation table

  `RiskExplanation.explain/3` already enforces the
  "first-version Morpho deposit always requires operator
  approval" rule via the `mvp_morpho_deposit` `:approval`
  reason, so the explanation's reported `decision` is the
  authoritative route.

  ## Inputs

    * `intent` — `%AgentIntent{kind: :defi_yield_deposit}`. The
      vault address lives in `target_raw_address`; chain string
      lives in `intent.chain` and resolves to a Morpho chain id
      via `chain_id_for/1`.

  ## Options

    * `:now` — clock override (default `DateTime.utc_now/0`).
    * `:rules` — pre-loaded policy rule list (test-injection
      hook; otherwise the workspace's active ruleset is loaded
      via `Bank.Policies.load_active_ruleset/1`).
    * `:morpho_snapshot` — pre-resolved snapshot (test-injection
      hook; pass `nil` to force the missing-snapshot `:hold` path).
      Defaults to a `Snapshots.get_current/2` lookup.
    * `:current_exposure` — operator-supplied exposure used by
      the `RulesCompiler`. Defaults to `Decimal.new(0)`.

  ## Returns

  Same shape as `Bank.Decisions.evaluate_intent/2` so callers
  consume the result uniformly. `:trust`, `:simulation`,
  `:preview`, `:execution_plan` are all `nil`; `:dispatch` is
  always `:not_applicable`.
  """

  import Ecto.Query

  require Logger

  alias Bank.Audit.Events
  alias Bank.Decisions.DecisionEnvelope
  alias Bank.DefiVenues.Morpho.RiskExplanation
  alias Bank.DefiVenues.Morpho.Snapshots
  alias Bank.Intents.AgentIntent
  alias Bank.Notifications.Emitter
  alias Bank.Policies
  alias Bank.Policies.Morpho.RulesCompiler
  alias Bank.Policies.PolicyRule
  alias Bank.Repo
  alias Bank.Runtime
  alias Ecto.Multi

  # Mirrors `Bank.Autonomy.apply_approval_expiry/1` — keep the
  # approval TTL identical so the operator queue does not see
  # different expiries for transfer vs. Morpho approvals.
  @approval_ttl_seconds 3600

  @spec evaluate(AgentIntent.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def evaluate(%AgentIntent{} = intent, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    chain_id = chain_id_for(intent.chain)
    vault_address = intent.target_raw_address

    snapshot = resolve_snapshot(opts, chain_id, vault_address)

    rules = resolve_rules(opts, intent.workspace_id)

    morpho_rule_ids =
      rules
      |> Enum.filter(fn
        %PolicyRule{rule_type: rt} -> PolicyRule.morpho?(rt)
        _ -> false
      end)
      |> Enum.map(& &1.id)

    policy_input =
      RulesCompiler.compile(rules,
        vault_address: vault_address,
        asset: intent.asset,
        proposed_amount: intent.amount,
        current_exposure: Keyword.get(opts, :current_exposure, Decimal.new(0))
      )

    explanation = RiskExplanation.explain(snapshot, policy_input, now)

    outcome = explanation_outcome(explanation)
    risk_tier = explanation_risk_tier(explanation)

    prior_decision = current_decision_for(intent.id)
    prior_state = intent.state

    envelope_attrs =
      build_envelope_attrs(
        intent,
        outcome,
        risk_tier,
        explanation,
        morpho_rule_ids,
        prior_decision,
        now
      )

    multi =
      Multi.new()
      |> maybe_demote_decision(prior_decision)
      |> Multi.insert(
        :decision,
        DecisionEnvelope.changeset(%DecisionEnvelope{}, envelope_attrs)
      )
      |> Multi.update(:intent, fn %{decision: decision} ->
        AgentIntent.current_pointer_changeset(intent, %{
          state: intent_state_for_outcome(outcome),
          current_decision_id: decision.id
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{decision: envelope, intent: updated_intent}} ->
        emit_audits(updated_intent, prior_state, envelope)

        # Inbox notification (#234). Best-effort, mirroring
        # `Bank.Decisions.evaluate_intent/2`.
        _ = Emitter.emit_decision_outcome(updated_intent, envelope)

        maybe_enqueue_approval_expiry(envelope)

        {:ok, build_result(updated_intent, envelope, prior_decision, outcome)}

      {:error, step, reason, _changes} ->
        Logger.error("MorphoEvaluator: multi failed at #{step}: #{inspect(reason)}")

        {:error, {step, reason}}
    end
  end

  # --- explanation → envelope --------------------------------------------

  defp explanation_outcome(%{"decision" => "block"}), do: :block
  defp explanation_outcome(%{"decision" => "hold"}), do: :hold
  defp explanation_outcome(%{"decision" => "approval_required"}), do: :approval_required
  # MVP: any `auto_exec` recommendation from the explanation still
  # routes to `:approval_required`. The engine's `mvp_morpho_deposit`
  # reason makes this unreachable today; this clause is the
  # belt-and-suspenders fail-closed sentinel for a future engine
  # change.
  defp explanation_outcome(%{"decision" => "auto_exec"}), do: :approval_required
  defp explanation_outcome(_), do: :hold

  defp explanation_risk_tier(%{"risk_tier" => "severe"}), do: :severe
  defp explanation_risk_tier(%{"risk_tier" => "elevated"}), do: :elevated
  defp explanation_risk_tier(%{"risk_tier" => "moderate"}), do: :moderate
  defp explanation_risk_tier(%{"risk_tier" => "low"}), do: :low
  defp explanation_risk_tier(_), do: :elevated

  defp build_envelope_attrs(
         intent,
         outcome,
         risk_tier,
         explanation,
         rule_ids,
         prior_decision,
         now
       ) do
    base = %{
      intent_id: intent.id,
      outcome: outcome,
      risk_tier: risk_tier,
      reasons: %{
        "items" => [
          %{
            "code" => "morpho_risk_explanation",
            "message" => explanation["summary"],
            "details" => %{"morpho_risk_explanation" => explanation}
          }
        ]
      },
      policy_snapshot_ref: %{"rule_ids" => rule_ids},
      decided_at: DateTime.utc_now(),
      decided_by: :runtime,
      state: :decided,
      current: true,
      supersedes_id: prior_decision && prior_decision.id
    }

    if outcome == :approval_required do
      Map.put(
        base,
        :approval_expires_at,
        DateTime.add(now, @approval_ttl_seconds, :second)
      )
    else
      base
    end
  end

  # --- inputs -------------------------------------------------------------

  # Morpho chain-id mapping for the v0.1 supported chains
  # (`Bank.Intents.@supported_chains`). Anything else returns nil
  # so `Snapshots.get_current/2` is skipped and the engine emits
  # the documented `snapshot_missing` `:hold` reason.
  defp chain_id_for("base"), do: 8453
  defp chain_id_for("base-sepolia"), do: 84_532
  defp chain_id_for(_), do: nil

  defp resolve_snapshot(opts, chain_id, vault_address) do
    case Keyword.fetch(opts, :morpho_snapshot) do
      {:ok, snap} ->
        snap

      :error when is_integer(chain_id) and is_binary(vault_address) ->
        Snapshots.get_current(chain_id, vault_address)

      :error ->
        nil
    end
  end

  defp resolve_rules(opts, workspace_id) do
    case Keyword.fetch(opts, :rules) do
      {:ok, rules} when is_list(rules) ->
        rules

      :error when is_binary(workspace_id) ->
        Policies.load_active_ruleset(workspace_id: workspace_id)

      :error ->
        Policies.load_active_ruleset()
    end
  end

  # --- multi helpers ------------------------------------------------------

  defp current_decision_for(intent_id) do
    Repo.one(
      from(d in DecisionEnvelope,
        where: d.intent_id == ^intent_id and d.current == true,
        limit: 1
      )
    )
  end

  defp maybe_demote_decision(multi, nil), do: multi

  defp maybe_demote_decision(multi, %DecisionEnvelope{} = prior) do
    Multi.update(multi, :demote_decision, DecisionEnvelope.mark_not_current(prior))
  end

  defp intent_state_for_outcome(:block), do: :blocked
  defp intent_state_for_outcome(_other), do: :decided

  defp emit_audits(intent, prior_state, envelope) do
    audit_opts = [workspace_id: intent.workspace_id]

    _ = Runtime.emit_audit(Events.decision_decided(envelope, audit_opts))

    if intent.state != prior_state do
      _ =
        Runtime.emit_audit(Events.intent_state_changed(intent, prior_state, intent.state))
    end

    :ok
  end

  defp maybe_enqueue_approval_expiry(%DecisionEnvelope{
         outcome: :approval_required,
         id: id,
         approval_expires_at: %DateTime{} = expires_at
       }) do
    case Runtime.enqueue_approval_expiry(id, expires_at) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "MorphoEvaluator: approval expiry enqueue failed for #{id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_enqueue_approval_expiry(_envelope), do: :ok

  defp build_result(intent, envelope, prior_decision, outcome) do
    %{
      intent: intent,
      trust: nil,
      simulation: nil,
      decision: envelope,
      superseded: %{trust: nil, simulation: nil, decision: prior_decision},
      outcome: outcome,
      preview: nil,
      dispatch: :not_applicable,
      execution_plan: nil
    }
  end
end
