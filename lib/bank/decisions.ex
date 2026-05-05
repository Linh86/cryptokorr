defmodule Bank.Decisions do
  @moduledoc """
  Decisions bounded context.

  Owns the `DecisionEnvelope` lifecycle and the approval state machine
  that produces successor envelopes rather than editing them.

  The fixed v1 outcome vocabulary is `auto_exec`, `hold`,
  `approval_required`, `block`. The fixed v1 risk vocabulary is `low`,
  `moderate`, `elevated`, `severe`. Both are owned here to keep the
  decision surface small and explicit.

  ## Manual execution

  `request_manual_execution/3` is the operator path for triggering
  execution of a decided envelope. It requires:

    1. The envelope is current and outcome is `:auto_exec`
    2. No active execution plan already exists for this decision
    3. The runtime is not globally paused
    4. The smart account has an active delegation

  If all gates pass, an execution plan is created and enqueued. The
  plan references the delegation that was checked at the time of the
  request, so replay can verify the delegation was valid.

  ## Auto-exec dispatch

  `dispatch_auto_exec/3` is the runtime-driven counterpart to
  `request_manual_execution/3`. It is called from
  `evaluate_intent/2` when the decision the autonomy router produced
  is `:auto_exec`. The two paths share the same gate set; the only
  differences are the audit `event_type` (`execution.auto_dispatched`
  vs. `execution.manually_requested`) and the actor (`:runtime` vs.
  `:user`).

  ### Smart-account sourcing (v0.1)

  `AgentIntent` does not carry a `smart_account_id` field today and
  there is no per-deployment "default smart account" config that the
  runtime can read. Rather than guess, `evaluate_intent/2` resolves
  the dispatch account through `resolve_executable_account/0`, which
  uses a single-active-delegation fallback:

    * exactly one executable smart account → dispatch through it
      (the intended single-tenant v0.1 deployment shape);
    * zero executable accounts → hold dispatch with reason
      `:no_executable_account`;
    * two or more → hold dispatch with reason
      `:ambiguous_executable_account`.

  In a held state the `:auto_exec` `DecisionEnvelope` is still
  current, the intent stays in `:decided`, and an
  `intent.auto_exec_held` audit event captures the reason. The
  operator can resolve the gate and call `request_manual_execution/3`
  explicitly to dispatch — no decision is lost.

  Multi-tenant deployments will require an explicit
  `smart_account_id` on the intent contract; that is a follow-up,
  not a v0.1 hardcode.
  """

  import Ecto.Query

  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Autonomy
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan, SimulationReport, TrustAssessment}
  alias Bank.Delegations
  alias Bank.Intents.AgentIntent
  alias Bank.Policies
  alias Bank.Quotes
  alias Bank.Repo
  alias Bank.Runtime
  alias Bank.Runtime.Notifier
  alias Bank.Security
  alias Bank.TrustEngine
  alias Ecto.Multi

  require Logger

  @evaluable_states [:submitted, :evaluating, :decided, :blocked]
  @decided_outcomes [:auto_exec, :hold, :approval_required]
  @default_simulation_provider "stub"
  @default_simulation_freshness_ttl 30

  # --- Evaluation pipeline ------------------------------------------------

  @typedoc """
  Result of `evaluate_intent/2`. Carries the freshly-written current
  rows, the prior current rows that were superseded (if any), the
  outcome that drove the intent's new state, and — for `:auto_exec`
  decisions — the dispatch outcome.

  `dispatch` is one of:

    * `:dispatched`        — an `ExecutionPlan` was created and
      `RunExecution` was enqueued. `execution_plan` is populated.
    * `{:held, reason}`    — the decision is `:auto_exec` but a
      safety gate held dispatch. `execution_plan` is `nil`. The
      reason is the same atom vocabulary
      `request_manual_execution/3` returns
      (`:no_executable_account`, `:ambiguous_executable_account`,
      `:runtime_paused`, `:active_plan_exists`,
      `:delegation_not_active`, `:stablecoin_adapter_not_wired`,
      `:not_current`, `:outcome_is_*`).
    * `:not_applicable`    — outcome is not `:auto_exec`.
  """
  @type dispatch_outcome ::
          :dispatched
          | {:held, atom()}
          | :not_applicable

  @type evaluation_result :: %{
          intent: AgentIntent.t(),
          trust: TrustAssessment.t(),
          simulation: SimulationReport.t(),
          decision: DecisionEnvelope.t(),
          superseded: %{
            trust: TrustAssessment.t() | nil,
            simulation: SimulationReport.t() | nil,
            decision: DecisionEnvelope.t() | nil
          },
          outcome: Autonomy.outcome(),
          preview: Quotes.result(),
          dispatch: dispatch_outcome(),
          execution_plan: ExecutionPlan.t() | nil
        }

  @doc """
  Run the deterministic evaluation pipeline for an `%AgentIntent{}`
  and persist the resulting trust / simulation / decision rows.

  This is the single facade the workers `EvaluateIntent` and
  `ReevaluateIntent` call. It composes the existing primitives:

    * `Bank.TrustEngine.classify/2`        — produces trust attrs
    * `Bank.Quotes.preview/2`              — produces a Preview struct
    * `Bank.Policies.evaluate/2`           — produces a policy `%Evaluation{}`
    * `Bank.Autonomy.route/2`              — chooses outcome + risk tier

  Then, inside one `Ecto.Multi`:

    1. demotes the prior current `TrustAssessment` (if any) and
       inserts the new one;
    2. demotes the prior current `SimulationReport` (if any) and
       inserts the new one — `:completed` for a healthy preview,
       `:failed` otherwise;
    3. demotes the prior current `DecisionEnvelope` (if any) and
       inserts the new one with its policy snapshot, references to
       the new trust + simulation rows, and supersedes_id pointing
       at the prior envelope;
    4. updates the intent's cached `current_*_id` pointers and its
       `state` (`:decided` for `auto_exec | hold | approval_required`,
       `:blocked` for `block`).

  After the transaction commits, the audit events for the four
  effects are appended via `Bank.Runtime.emit_audit/1`. When the
  outcome is `:auto_exec`, the facade also tries to materialise an
  `ExecutionPlan` via `dispatch_auto_exec/3` (see the auto-exec
  dispatch section in the moduledoc). When dispatch is held the
  decision envelope is preserved as `:auto_exec` and the operator
  can fall back to `request_manual_execution/3` once the gate is
  resolved.

  ## Inputs

    * `intent_or_id` — `%AgentIntent{}` struct or its uuid string.
    * `opts`:
      * `:now`      — clock override (default `DateTime.utc_now/0`).
      * `:rules`    — pre-loaded policy rule list (avoids a second DB
        round-trip when the caller already holds the snapshot).
      * `:preview`  — pre-computed `Bank.Quotes.preview/2` result;
        skips the in-process call. Tests use this to drive specific
        branches of the autonomy router.
      * `:paused?`  — pre-computed paused state; defaults to
        `Bank.Security.paused?(:global)`.
      * `:thresholds` — autonomy threshold override, forwarded to
        `Bank.Autonomy.route/2`.
      * `:reason`   — string carried into the envelope's reasons list
        when present (e.g. `"policy_changed"` for re-evaluation).

  ## Returns

    * `{:ok, evaluation_result()}` on success.
    * `{:error, :not_found}` — the id resolves to no intent.
    * `{:error, {:wrong_state, state}}` — the intent is in a state
      where evaluation is not legal (`:executing`, `:executed`,
      `:cancelled`, `:expired`).

  Re-evaluation is the same call: pass an intent that is already in
  `:decided` or `:blocked`. The supersession chain on each child row
  preserves replay history.
  """
  @spec evaluate_intent(AgentIntent.t() | String.t(), keyword()) ::
          {:ok, evaluation_result()}
          | {:error, :not_found | {:wrong_state, atom()} | term()}
  def evaluate_intent(intent_or_id, opts \\ [])

  def evaluate_intent(%AgentIntent{} = intent, opts), do: do_evaluate_intent(intent, opts)

  def evaluate_intent(intent_id, opts) when is_binary(intent_id) do
    case Repo.get(AgentIntent, intent_id) do
      nil -> {:error, :not_found}
      %AgentIntent{} = intent -> do_evaluate_intent(intent, opts)
    end
  end

  defp do_evaluate_intent(%AgentIntent{state: state} = intent, opts)
       when state in @evaluable_states do
    intent = Repo.preload(intent, [:target_address_label, :target_counterparty])
    run_evaluation(intent, opts)
  end

  defp do_evaluate_intent(%AgentIntent{state: state}, _opts) do
    {:error, {:wrong_state, state}}
  end

  defp run_evaluation(%AgentIntent{} = intent, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    trust_attrs = TrustEngine.classify(intent, Keyword.put_new(opts, :now, now))
    preview_result = Keyword.get_lazy(opts, :preview, fn -> Quotes.preview(intent, opts) end)
    policy = evaluate_policy(intent, opts, now)
    paused? = Keyword.get_lazy(opts, :paused?, fn -> Security.paused?(:global) end)

    decision =
      Autonomy.route(
        %{
          intent: intent,
          policy: policy,
          trust: trust_attrs,
          preview: preview_result,
          paused?: paused?
        },
        opts
      )

    prior_trust = current_trust_for(intent.id)
    prior_simulation = current_simulation_for(intent.id)
    prior_decision = current_decision_for(intent.id)
    prior_intent_state = intent.state

    multi =
      Multi.new()
      |> maybe_demote(:demote_trust, prior_trust, &TrustAssessment.mark_not_current/1)
      |> Multi.insert(
        :trust,
        TrustAssessment.changeset(
          %TrustAssessment{},
          build_trust_attrs(intent, trust_attrs, prior_trust)
        )
      )
      |> maybe_demote(:demote_simulation, prior_simulation, &SimulationReport.mark_not_current/1)
      |> Multi.insert(
        :simulation,
        SimulationReport.changeset(
          %SimulationReport{},
          build_simulation_attrs(intent, preview_result, prior_simulation, now)
        )
      )
      |> maybe_demote(:demote_decision, prior_decision, &DecisionEnvelope.mark_not_current/1)
      |> Multi.insert(:decision, fn %{trust: t, simulation: s} ->
        DecisionEnvelope.changeset(
          %DecisionEnvelope{},
          build_decision_attrs(intent, decision, policy, t, s, prior_decision, opts)
        )
      end)
      |> Multi.update(:intent, fn %{trust: t, simulation: s, decision: d} ->
        AgentIntent.current_pointer_changeset(intent, %{
          state: intent_state_for_outcome(decision.outcome),
          current_trust_assessment_id: t.id,
          current_simulation_id: s.id,
          current_decision_id: d.id
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{trust: trust, simulation: simulation, decision: envelope, intent: updated_intent}} ->
        emit_evaluation_audits(
          updated_intent,
          prior_intent_state,
          trust,
          simulation,
          envelope,
          prior_trust,
          prior_simulation
        )

        # Inbox notification (#234). Best-effort: emitter logs and
        # returns on validation failure so the decision path is not
        # broken by a notification-side error.
        _ = Bank.Notifications.Emitter.emit_decision_outcome(updated_intent, envelope)

        maybe_enqueue_approval_expiry(envelope)

        {dispatch, plan} = maybe_dispatch_auto_exec(updated_intent, envelope, opts)

        {:ok,
         %{
           intent: updated_intent,
           trust: trust,
           simulation: simulation,
           decision: envelope,
           superseded: %{
             trust: prior_trust,
             simulation: prior_simulation,
             decision: prior_decision
           },
           outcome: decision.outcome,
           preview: preview_result,
           dispatch: dispatch,
           execution_plan: plan
         }}

      {:error, step, reason, _changes} ->
        Logger.error("Decisions.evaluate_intent: multi failed at #{step}: #{inspect(reason)}")
        {:error, {step, reason}}
    end
  end

  defp maybe_dispatch_auto_exec(_intent, %DecisionEnvelope{outcome: outcome}, _opts)
       when outcome != :auto_exec do
    {:not_applicable, nil}
  end

  defp maybe_dispatch_auto_exec(intent, %DecisionEnvelope{} = envelope, opts) do
    with {:ok, smart_account_id} <- resolve_dispatch_account(opts),
         {:ok, plan} <- dispatch_auto_exec(envelope.id, smart_account_id, opts) do
      {:dispatched, plan}
    else
      {:error, reason} ->
        emit_auto_exec_held(intent, envelope, reason)
        {{:held, reason}, nil}
    end
  end

  defp resolve_dispatch_account(opts) do
    case Keyword.get(opts, :smart_account_id) do
      account when is_binary(account) and account != "" ->
        {:ok, account}

      _ ->
        resolve_executable_account()
    end
  end

  defp emit_auto_exec_held(intent, envelope, reason) do
    _ =
      Runtime.emit_audit(Bank.Audit.Events.intent_auto_exec_held(intent, envelope, reason))

    Logger.info(
      "Decisions: auto_exec dispatch held for intent #{intent.id} " <>
        "(envelope=#{envelope.id}, reason=#{inspect(reason)})"
    )

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
          "Decisions.evaluate_intent: failed to enqueue approval expiry for #{id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_enqueue_approval_expiry(_envelope), do: :ok

  # If the workspace has a published `Bank.Policies.PolicyVersion`
  # (#223), use its rule_ids list as the authoritative pinned
  # snapshot (#226). Greenfield workspaces with no published
  # version fall back to legacy `Bank.Policies.load_active_ruleset/1`
  # — that's the documented backward-compatibility decision.
  defp evaluate_policy(intent, opts, now) do
    eval_opts = [now: now]

    {rules_opt, version_meta} =
      cond do
        Keyword.has_key?(opts, :rules) ->
          # Test-injected rules — preserve the existing test
          # injection path; no version pin (caller is in control).
          {[{:rules, opts[:rules]}], nil}

        intent.workspace_id ->
          case Bank.Policies.Versions.snapshot_for_workspace(intent.workspace_id) do
            nil ->
              {[], nil}

            %{rules: rules, version_id: vid, version_number: vnum} ->
              {[{:rules, rules}], %{id: vid, number: vnum}}
          end

        true ->
          {[], nil}
      end

    eval_opts = rules_opt ++ eval_opts

    intent
    |> Policies.evaluate(eval_opts)
    |> maybe_pin_version(version_meta)
    |> maybe_fail_closed(version_meta)
  end

  defp maybe_pin_version(%Bank.Policies.Evaluation{} = ev, nil), do: ev

  defp maybe_pin_version(%Bank.Policies.Evaluation{snapshot_ref: ref} = ev, %{
         id: vid,
         number: vnum
       }) do
    pinned =
      ref
      |> Map.put("policy_version_id", vid)
      |> Map.put("policy_version_number", vnum)

    %{ev | snapshot_ref: pinned}
  end

  # Fail-closed: when a published policy version exists for the
  # workspace BUT the resolved rule set is empty (every id in the
  # version's rule_ids list is missing or no longer `:active`), do
  # not pass-through. Append a `policy_version_unresolved` violation
  # so the autonomy router routes to `:hold`. This addresses the
  # #226 acceptance bullet "Missing/malformed policy fails closed"
  # — a published-but-broken policy must not run wide open.
  defp maybe_fail_closed(%Bank.Policies.Evaluation{} = ev, nil), do: ev

  defp maybe_fail_closed(
         %Bank.Policies.Evaluation{matched_rule_ids: matched, violations: violations} = ev,
         %{id: vid, number: vnum}
       ) do
    if matched == [] do
      violation = %{
        rule_id: nil,
        rule_type: :policy_version_unresolved,
        code: "policy_version_unresolved",
        message:
          "published policy version v#{vnum} (#{vid}) resolved to 0 active rules; failing closed",
        details: %{"policy_version_id" => vid, "policy_version_number" => vnum}
      }

      %{ev | pass?: false, violations: [violation | violations]}
    else
      ev
    end
  end

  defp maybe_demote(multi, _key, nil, _fun), do: multi

  defp maybe_demote(multi, key, %_{} = prior, fun) do
    Multi.update(multi, key, fun.(prior))
  end

  defp build_trust_attrs(intent, trust_attrs, prior) do
    trust_attrs
    |> Map.put(:intent_id, intent.id)
    |> Map.put(:current, true)
    |> Map.put(:supersedes_id, prior && prior.id)
    |> wrap_contradictions()
  end

  defp wrap_contradictions(%{contradictions: items} = attrs) when is_list(items) do
    Map.put(attrs, :contradictions, %{"items" => items})
  end

  defp wrap_contradictions(attrs), do: attrs

  @doc """
  Build a `SimulationReport`-shaped attribute map from the result of
  `Bank.Quotes.preview/2`. Returns the intent / preview-derived
  fields only — the caller layers in `:current` and `:supersedes_id`
  per its own state-machine semantics.

  Used by both `evaluate_intent/2` (which writes a `current: true`
  report on every evaluation) and `Bank.Intents.simulate/3` (which
  only sets `current: true` for `reason: "refresh"`).

  Options:

    * `:now` — clock for the failed-preview path (default
      `DateTime.utc_now/0`). For `{:ok, preview}`, `generated_at`
      comes from the preview struct itself.
  """
  @spec simulation_attrs_from_preview(AgentIntent.t(), Quotes.result(), keyword()) :: map()
  def simulation_attrs_from_preview(%AgentIntent{} = intent, preview_result, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    do_simulation_attrs(intent, preview_result, now)
  end

  defp do_simulation_attrs(intent, {:ok, %Quotes.Preview{} = preview}, _now) do
    %{
      intent_id: intent.id,
      provider: preview.provider,
      provider_trace_ref: preview.provider_trace_ref,
      chain: intent.chain,
      asset: intent.asset,
      predicted_balance_changes: balance_changes_payload(preview.balance_impact),
      estimated_gas: preview.estimated_gas,
      estimated_fees: estimated_fees_payload(preview),
      routing_path: preview.route,
      expected_output: preview.expected_output,
      slippage_exposure: nil,
      failure_conditions: %{"items" => preview.failure_conditions || []},
      generated_at: preview.generated_at,
      freshness_ttl_seconds: preview.freshness_ttl_seconds || @default_simulation_freshness_ttl,
      status: :completed
    }
  end

  defp do_simulation_attrs(intent, {:error, reason}, now) do
    %{
      intent_id: intent.id,
      provider: @default_simulation_provider,
      provider_trace_ref: nil,
      chain: intent.chain,
      asset: intent.asset,
      predicted_balance_changes: %{"items" => []},
      estimated_gas: nil,
      estimated_fees: nil,
      routing_path: nil,
      expected_output: nil,
      slippage_exposure: nil,
      failure_conditions: %{
        "items" => [
          %{
            "kind" => "preview_failed",
            "message" => simulation_failure_message(reason)
          }
        ]
      },
      generated_at: now,
      freshness_ttl_seconds: @default_simulation_freshness_ttl,
      status: :failed
    }
  end

  defp do_simulation_attrs(intent, _other, now) do
    do_simulation_attrs(intent, {:error, :preview_missing}, now)
  end

  defp build_simulation_attrs(intent, preview_result, prior, now) do
    intent
    |> simulation_attrs_from_preview(preview_result, now: now)
    |> Map.put(:current, true)
    |> Map.put(:supersedes_id, prior && prior.id)
  end

  defp simulation_failure_message(:provider_unavailable), do: "preview provider unavailable"
  defp simulation_failure_message(:stale), do: "preview stale; awaiting refresh"
  defp simulation_failure_message(:preview_missing), do: "no preview produced"
  defp simulation_failure_message({:simulation_failed, msg}), do: "simulation failed: #{msg}"
  defp simulation_failure_message({:unsupported, msg}), do: "preview unsupported: #{msg}"
  defp simulation_failure_message({:provider_exception, msg}), do: "provider exception: #{msg}"
  defp simulation_failure_message(other), do: "preview error: #{inspect(other)}"

  defp balance_changes_payload(%{} = balance_impact) do
    items =
      balance_impact
      |> Enum.map(fn {asset, delta} ->
        %{
          "asset" => to_string(asset),
          "delta" => decimal_to_string(delta)
        }
      end)

    %{"items" => items}
  end

  defp balance_changes_payload(_), do: %{"items" => []}

  defp estimated_fees_payload(%Quotes.Preview{estimated_fee: nil}), do: nil

  defp estimated_fees_payload(%Quotes.Preview{estimated_fee: fee, fee_asset: asset}) do
    %{
      "asset" => asset,
      "amount" => decimal_to_string(fee)
    }
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp decimal_to_string(other), do: to_string(other)

  defp build_decision_attrs(intent, decision, policy, trust, simulation, prior_decision, opts) do
    extras =
      %{
        intent_id: intent.id,
        trust_assessment_id: trust.id,
        simulation_report_id: simulation.id,
        policy_snapshot_ref: policy.snapshot_ref,
        state: :decided,
        supersedes_id: prior_decision && prior_decision.id
      }
      |> maybe_put_reason(opts)

    Autonomy.to_envelope_attrs(decision, extras)
  end

  defp maybe_put_reason(extras, opts) do
    case Keyword.get(opts, :reason) do
      nil -> extras
      _string -> extras
    end
  end

  defp intent_state_for_outcome(:block), do: :blocked
  defp intent_state_for_outcome(outcome) when outcome in @decided_outcomes, do: :decided

  defp current_trust_for(intent_id) do
    Repo.one(
      from(t in TrustAssessment,
        where: t.intent_id == ^intent_id and t.current == true,
        limit: 1
      )
    )
  end

  defp current_simulation_for(intent_id) do
    Repo.one(
      from(s in SimulationReport,
        where: s.intent_id == ^intent_id and s.current == true,
        limit: 1
      )
    )
  end

  defp current_decision_for(intent_id) do
    Repo.one(
      from(d in DecisionEnvelope,
        where: d.intent_id == ^intent_id and d.current == true,
        limit: 1
      )
    )
  end

  defp emit_evaluation_audits(
         intent,
         prior_intent_state,
         trust,
         simulation,
         envelope,
         prior_trust,
         prior_simulation
       ) do
    # Stamp every derived event with the parent intent's
    # workspace_id (#158d-b). The audit envelope passthrough field
    # (#158b) carries it onto the row without disturbing the
    # canonical hash.
    audit_opts = [workspace_id: intent.workspace_id]

    if is_nil(prior_trust) or prior_trust.id != trust.id do
      _ = Runtime.emit_audit(Events.trust_assessed(trust, audit_opts))
    end

    if is_nil(prior_simulation) or prior_simulation.id != simulation.id do
      _ = Runtime.emit_audit(Events.simulation_produced(simulation, audit_opts))
    end

    _ = Runtime.emit_audit(Events.decision_decided(envelope, audit_opts))

    if intent.state != prior_intent_state do
      _ =
        Runtime.emit_audit(Events.intent_state_changed(intent, prior_intent_state, intent.state))
    end

    Notifier.intent_lifecycle(intent, :decision_updated, %{
      decision_envelope_id: envelope.id,
      outcome: envelope.outcome,
      risk_tier: envelope.risk_tier
    })

    :ok
  end

  # --- Read API -----------------------------------------------------------

  @doc "Fetch a decision envelope by id."
  @spec get_envelope(String.t()) :: {:ok, DecisionEnvelope.t()} | {:error, :not_found}
  def get_envelope(id) when is_binary(id) do
    case Repo.get(DecisionEnvelope, id) do
      nil -> {:error, :not_found}
      envelope -> {:ok, envelope}
    end
  end

  @doc """
  Workspace-scoped `get_envelope/1` (#159b). Joins the envelope's
  parent intent and matches `intent.workspace_id`. Returns
  `:not_found` for missing ids AND for ids whose intent belongs
  to a different workspace.
  """
  @spec get_envelope_in_workspace(String.t(), String.t()) ::
          {:ok, DecisionEnvelope.t()} | {:error, :not_found}
  def get_envelope_in_workspace(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    case Repo.one(
           from e in DecisionEnvelope,
             join: i in AgentIntent,
             on: e.intent_id == i.id,
             where: e.id == ^id and i.workspace_id == ^workspace_id
         ) do
      nil -> {:error, :not_found}
      envelope -> {:ok, envelope}
    end
  end

  @doc "Fetch a decision envelope with its execution plans preloaded."
  @spec get_envelope_with_plans(String.t()) :: {:ok, DecisionEnvelope.t()} | {:error, :not_found}
  def get_envelope_with_plans(id) when is_binary(id) do
    case Repo.get(DecisionEnvelope, id) |> Repo.preload(:execution_plans) do
      nil -> {:error, :not_found}
      envelope -> {:ok, envelope}
    end
  end

  @doc """
  Workspace-scoped `get_envelope_with_plans/1` (#159b).
  """
  @spec get_envelope_with_plans_in_workspace(String.t(), String.t()) ::
          {:ok, DecisionEnvelope.t()} | {:error, :not_found}
  def get_envelope_with_plans_in_workspace(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    case Repo.one(
           from e in DecisionEnvelope,
             join: i in AgentIntent,
             on: e.intent_id == i.id,
             where: e.id == ^id and i.workspace_id == ^workspace_id,
             preload: [:execution_plans]
         ) do
      nil -> {:error, :not_found}
      envelope -> {:ok, envelope}
    end
  end

  @doc "Fetch the active execution plan for a decision, if any."
  @spec active_plan_for(String.t()) :: ExecutionPlan.t() | nil
  def active_plan_for(decision_id) do
    Repo.one(
      from(p in ExecutionPlan,
        where: p.decision_id == ^decision_id and p.active == true,
        limit: 1
      )
    )
  end

  @doc """
  List current decision envelopes with outcome `:approval_required`.

  Returns envelopes ordered by `decided_at` descending, preloaded with
  the parent intent. Used by the action queue to show pending approvals.
  """
  @spec list_pending_approvals(keyword()) :: [DecisionEnvelope.t()]
  def list_pending_approvals(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(e in DecisionEnvelope,
      where: e.current == true and e.outcome == :approval_required,
      order_by: [desc: e.decided_at],
      preload: [:intent]
    )
    |> scope_envelope_to_workspace(workspace_id)
    |> Repo.all()
  end

  @doc """
  Count of current envelopes awaiting approval.

  Options:

    * `:workspace_id` — narrow to one workspace (#158b.2). Default
      `nil` keeps the legacy "all workspaces" path open until every
      caller is migrated.
  """
  @spec count_pending_approvals(keyword()) :: non_neg_integer()
  def count_pending_approvals(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(e in DecisionEnvelope,
      where: e.current == true and e.outcome == :approval_required,
      select: count(e.id)
    )
    |> scope_envelope_to_workspace(workspace_id)
    |> Repo.one()
  end

  @doc """
  List recent current decision envelopes, most recent first.

  Accepts an optional `limit` (default 10). Preloads the parent intent
  for display in the dashboard.

  Options:

    * `:workspace_id` — narrow to one workspace (#158b.2). Default
      `nil` (all workspaces).
  """
  @spec list_recent_decisions(pos_integer(), keyword()) :: [DecisionEnvelope.t()]
  def list_recent_decisions(limit \\ 10, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(e in DecisionEnvelope,
      where: e.current == true,
      order_by: [desc: e.decided_at],
      limit: ^limit,
      preload: [:intent]
    )
    |> scope_envelope_to_workspace(workspace_id)
    |> Repo.all()
  end

  @doc """
  Count active (non-terminal) execution plans.

  Terminal statuses are `:confirmed`, `:reverted`, `:aborted`.

  Options:

    * `:workspace_id` — narrow to one workspace (#158b.2). Default
      `nil` (all workspaces).
  """
  @spec count_active_executions(keyword()) :: non_neg_integer()
  def count_active_executions(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(p in ExecutionPlan,
      where:
        p.active == true and
          p.execution_status not in [:confirmed, :reverted, :aborted],
      select: count(p.id)
    )
    |> scope_plan_to_workspace(workspace_id)
    |> Repo.one()
  end

  @doc """
  List active (non-terminal) execution plans, most recent first.

  Preloads the parent intent for display purposes.

  Options:

    * `:workspace_id` — narrow to one workspace (#158b.2). Default
      `nil` (all workspaces).
  """
  @spec list_active_executions(keyword()) :: [ExecutionPlan.t()]
  def list_active_executions(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(p in ExecutionPlan,
      where:
        p.active == true and
          p.execution_status not in [:confirmed, :reverted, :aborted],
      order_by: [desc: p.inserted_at],
      preload: [:intent]
    )
    |> scope_plan_to_workspace(workspace_id)
    |> Repo.all()
  end

  @doc """
  List current envelopes with outcome `:hold`, most recent first.
  Preloads the parent intent for the action queue held-items view.

  Options:

    * `:workspace_id` — narrow to one workspace (#158b.2). Default
      `nil` (all workspaces).
  """
  @spec list_held_decisions(keyword()) :: [DecisionEnvelope.t()]
  def list_held_decisions(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(e in DecisionEnvelope,
      where: e.current == true and e.outcome == :hold,
      order_by: [desc: e.decided_at],
      preload: [:intent]
    )
    |> scope_envelope_to_workspace(workspace_id)
    |> Repo.all()
  end

  @doc """
  List current envelopes with outcome `:block`, most recent first.
  Preloads the parent intent for the action queue blocked-items view.

  Options:

    * `:workspace_id` — narrow to one workspace (#158b.2). Default
      `nil` (all workspaces).
  """
  @spec list_blocked_decisions(pos_integer(), keyword()) :: [DecisionEnvelope.t()]
  def list_blocked_decisions(limit \\ 20, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(e in DecisionEnvelope,
      where: e.current == true and e.outcome == :block,
      order_by: [desc: e.decided_at],
      limit: ^limit,
      preload: [:intent]
    )
    |> scope_envelope_to_workspace(workspace_id)
    |> Repo.all()
  end

  # `decision_envelopes` does not carry its own `workspace_id`; the
  # scope is derived from the parent intent (FK chain). Narrowing the
  # query JOINs to intent and filters there. The `nil` clause is the
  # legacy no-op default; existing callers stay unchanged.
  defp scope_envelope_to_workspace(query, nil), do: query

  defp scope_envelope_to_workspace(query, workspace_id) when is_binary(workspace_id) do
    from e in query,
      join: i in assoc(e, :intent),
      where: i.workspace_id == ^workspace_id
  end

  # `execution_plans` carries its own `workspace_id` read hint
  # (#158a), so the filter is a direct WHERE.
  defp scope_plan_to_workspace(query, nil), do: query

  defp scope_plan_to_workspace(query, workspace_id) when is_binary(workspace_id),
    do: where(query, [p], p.workspace_id == ^workspace_id)

  # --- Approval state transitions -----------------------------------------

  @approval_valid_prior_states [:decided, :pending_decision]

  @doc """
  Operator approval of an `:approval_required` envelope.

  Produces a successor envelope with outcome `:auto_exec`, re-pointing
  the intent to the successor. All effects (envelope supersede, intent
  pointer, audits, PubSub) run inside a single `Ecto.Multi` so the
  partial unique index stays valid at every commit boundary.

  ## Execution handoff (v0.1)

  Approval writes the successor `:auto_exec` envelope and then runs
  the same auto-dispatch path the runtime uses on
  `evaluate_intent/2` (see `dispatch_auto_exec/3`). The two outcomes:

    * `{:ok, successor, {:dispatched, plan}}` — an executable smart
      account resolved (single active delegation, or an explicit
      `:smart_account_id` opt), the runtime was not paused, and an
      `ExecutionPlan` was created and enqueued for `RunExecution`.
    * `{:ok, successor, {:held, reason}}` — the approval was
      recorded but dispatch did not proceed because a safety gate
      held it (`:no_executable_account`,
      `:ambiguous_executable_account`, `:runtime_paused`,
      `:active_plan_exists`, `:delegation_not_active`,
      `:stablecoin_adapter_not_wired`). The successor envelope is
      preserved as `:auto_exec` and current; the operator can call
      `POST /v1/decisions/{id}/execute` with an explicit
      `smart_account_id` once the gate is resolved.

  Approval itself is unaffected by pause state — operators can
  approve while the runtime is paused; the dispatch step is the
  one that observes pause. This preserves the "nothing enters
  `:executing` while paused" invariant.

  ## Options

    * `:actor_id` — required, identifies the operator (used for audit).
    * `:reason`   — optional string stored on the successor's reasons
      list.
    * `:smart_account_id` — optional explicit smart-account override
      for dispatch. Defaults to `Bank.Decisions.resolve_executable_account/0`.
  """
  @spec approve(String.t(), keyword()) ::
          {:ok, DecisionEnvelope.t(), {:dispatched, ExecutionPlan.t()} | {:held, atom()}}
          | {:error, term()}
  def approve(envelope_id, opts) when is_binary(envelope_id) and is_list(opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)
    reason = Keyword.get(opts, :reason, "operator_approved")

    case apply_approval_decision(envelope_id, :auto_exec, reason, actor_id) do
      {:ok, successor, _legacy_disposition} ->
        {:ok, successor, dispatch_after_approval(successor, opts)}

      {:error, _} = err ->
        err
    end
  end

  defp dispatch_after_approval(%DecisionEnvelope{} = successor, opts) do
    case resolve_dispatch_account(opts) do
      {:ok, smart_account_id} ->
        case dispatch_auto_exec(successor.id, smart_account_id, opts) do
          {:ok, plan} -> {:dispatched, plan}
          {:error, reason} -> handle_approval_held(successor, reason)
        end

      {:error, reason} ->
        handle_approval_held(successor, reason)
    end
  end

  defp handle_approval_held(%DecisionEnvelope{} = successor, reason) do
    # Mirror the evaluation-driven held path: write `intent.auto_exec_held`
    # so replay surfaces the same audit row regardless of which path
    # produced the held state. The intent row is already updated by
    # `apply_approval_decision/4` (same DB connection); reload it here
    # so the audit `before_ref` carries the post-approve state.
    case Repo.get(AgentIntent, successor.intent_id) do
      %AgentIntent{} = intent -> emit_auto_exec_held(intent, successor, reason)
      _ -> :ok
    end

    {:held, reason}
  end

  @doc """
  Operator rejection of an `:approval_required` envelope.

  Produces a successor with outcome `:block`, moving the intent to
  `:blocked`. Same transactional guarantees as `approve/2`.

  Rejection never dispatches execution, so the disposition is always
  `:no_dispatch`. Pause state is irrelevant — operators can reject
  approvals while the runtime is paused.
  """
  @spec reject(String.t(), keyword()) ::
          {:ok, DecisionEnvelope.t(), :no_dispatch} | {:error, term()}
  def reject(envelope_id, opts) when is_binary(envelope_id) and is_list(opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)
    reason = Keyword.get(opts, :reason, "operator_rejected")

    apply_approval_decision(envelope_id, :block, reason, actor_id)
  end

  defp apply_approval_decision(envelope_id, successor_outcome, reason, actor_id) do
    with {:ok, prior, intent} <- load_for_approval(envelope_id) do
      now = DateTime.utc_now()
      prior_intent_state = intent.state
      target_intent_state = target_state_for_outcome(successor_outcome)

      reason_code =
        case successor_outcome do
          :auto_exec -> "operator_approved"
          :block -> "operator_rejected"
        end

      multi =
        Multi.new()
        |> Multi.update(:mark_not_current, DecisionEnvelope.mark_not_current(prior))
        |> Multi.insert(:successor, fn _ ->
          DecisionEnvelope.supersede(prior, %{
            outcome: successor_outcome,
            risk_tier: prior.risk_tier,
            reasons: %{
              "items" => [
                %{
                  "code" => reason_code,
                  "message" => reason,
                  "actor_id" => actor_id
                }
              ]
            },
            policy_snapshot_ref: prior.policy_snapshot_ref,
            trust_assessment_id: prior.trust_assessment_id,
            simulation_report_id: prior.simulation_report_id,
            decided_at: now,
            decided_by: :user,
            state: successor_state_for(successor_outcome),
            current: true,
            approval_expires_at: nil
          })
        end)
        |> Multi.update(:intent, fn %{successor: successor} ->
          AgentIntent.current_pointer_changeset(intent, %{
            current_decision_id: successor.id,
            state: target_intent_state
          })
        end)

      case Repo.transaction(multi) do
        {:ok, %{successor: successor, intent: updated_intent}} ->
          emit_approval_effects(
            prior,
            successor,
            prior_intent_state,
            updated_intent,
            actor_id
          )

          {:ok, successor, post_decision_disposition(successor)}

        {:error, step, reason, _changes} ->
          Logger.error(
            "Decisions.apply_approval_decision: multi failed at #{step}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  defp post_decision_disposition(%DecisionEnvelope{outcome: :auto_exec}), do: :recorded
  defp post_decision_disposition(%DecisionEnvelope{outcome: :block}), do: :no_dispatch

  defp load_for_approval(envelope_id) do
    case Repo.get(DecisionEnvelope, envelope_id) do
      nil ->
        {:error, :not_found}

      %DecisionEnvelope{current: false} ->
        {:error, :already_superseded}

      %DecisionEnvelope{outcome: :approval_required, state: state} = prior
      when state in @approval_valid_prior_states ->
        case Repo.get(AgentIntent, prior.intent_id) do
          nil -> {:error, :intent_not_found}
          %AgentIntent{} = intent -> {:ok, prior, intent}
        end

      %DecisionEnvelope{outcome: outcome} ->
        {:error, {:wrong_outcome, outcome}}

      %DecisionEnvelope{state: state} ->
        {:error, {:wrong_state, state}}
    end
  end

  defp target_state_for_outcome(:auto_exec), do: :decided
  defp target_state_for_outcome(:block), do: :blocked

  defp successor_state_for(:auto_exec), do: :decided
  defp successor_state_for(:block), do: :resolved

  defp emit_approval_effects(prior, successor, prior_intent_state, intent, actor_id) do
    event_builder =
      case successor.outcome do
        :auto_exec -> &Events.approval_granted/3
        :block -> &Events.approval_rejected/3
      end

    audit_opts = [actor_id: actor_id, workspace_id: intent.workspace_id]

    Runtime.emit_audit(event_builder.(prior, successor, audit_opts))
    Runtime.emit_audit(Events.decision_decided(successor, audit_opts))
    Runtime.emit_audit(Events.intent_state_changed(intent, prior_intent_state, intent.state))

    Notifier.approval_queue(
      if(successor.outcome == :auto_exec, do: :approved, else: :rejected),
      prior,
      %{
        successor_decision_envelope_id: successor.id,
        final_outcome: successor.outcome,
        actor_id: actor_id
      }
    )

    Notifier.intent_lifecycle(intent, :decision_updated, %{
      decision_envelope_id: successor.id,
      outcome: successor.outcome,
      actor_id: actor_id
    })
  end

  # --- Manual execution ---------------------------------------------------

  @doc """
  Operator-triggered manual execution.

  Gates:
    1. Envelope must exist and be current with outcome `:auto_exec`
    2. No active execution plan already exists for this decision
    3. Stablecoin routes must not require an unwired adapter dispatch
    4. Runtime must not be globally paused
    5. Smart account delegation must be `:active`

  On success, creates an execution plan in `:prepared` state and
  enqueues it for execution via `Bank.Runtime.enqueue_execution/1`.

  Returns `{:ok, plan}` or `{:error, reason}`.
  """
  @spec request_manual_execution(String.t(), String.t(), keyword()) ::
          {:ok, ExecutionPlan.t()} | {:error, atom() | String.t()}
  def request_manual_execution(envelope_id, smart_account_id, opts \\ []) do
    with {:ok, envelope} <- get_envelope(envelope_id),
         {:ok, plan} <- create_execution_plan(envelope, smart_account_id, :manual, opts) do
      {:ok, plan}
    end
  end

  @doc """
  Runtime-driven counterpart to `request_manual_execution/3`. Called
  from `evaluate_intent/2` when the autonomy router produces
  `:auto_exec`. Reuses the same gate set so dispatch policy stays
  one piece of code; the only differences are the audit event type
  (`execution.auto_dispatched`), the actor (`:runtime`), and one
  extra safety gate.

  ## Extra intent-level safety gate

  In addition to the per-decision `:active_plan_exists` gate the
  manual path enforces, the auto path also rejects when **any**
  active execution plan exists for the same intent — even if it
  belongs to a prior, now-superseded decision. Without this gate, a
  re-evaluation that produces `:auto_exec` again (for example
  after a policy revision) would race the in-flight plan and
  dispatch a parallel one to the adapter.

  The manual path (`request_manual_execution/3`) intentionally does
  not enforce this gate so an operator can run a one-shot override
  after explicitly aborting a stuck plan.

  Returns `{:ok, plan}` on success, or the same `{:error, reason}`
  vocabulary the manual path returns.
  """
  @spec dispatch_auto_exec(String.t(), String.t(), keyword()) ::
          {:ok, ExecutionPlan.t()} | {:error, atom() | String.t()}
  def dispatch_auto_exec(envelope_id, smart_account_id, opts \\ []) do
    with {:ok, envelope} <- get_envelope(envelope_id),
         :ok <- validate_no_intent_in_flight(envelope.intent_id),
         {:ok, plan} <- create_execution_plan(envelope, smart_account_id, :auto, opts) do
      {:ok, plan}
    end
  end

  defp validate_no_intent_in_flight(intent_id) do
    case Repo.one(
           from(p in ExecutionPlan,
             where: p.intent_id == ^intent_id and p.active == true,
             limit: 1
           )
         ) do
      nil -> :ok
      _plan -> {:error, :active_plan_exists}
    end
  end

  @doc """
  Resolve a `smart_account_id` to dispatch a runtime-driven
  `:auto_exec` envelope through.

  v0.1 single-tenant policy: succeed iff there is exactly one
  currently-executable delegation across the projection. Zero
  matches return `{:error, :no_executable_account}`; two or more
  return `{:error, :ambiguous_executable_account}`. Held cases are
  recorded by the caller as `intent.auto_exec_held`; the decision
  envelope itself is preserved as `:auto_exec` so the manual
  execution path can still be invoked once the account is
  unambiguous.
  """
  @spec resolve_executable_account() ::
          {:ok, String.t()}
          | {:error, :no_executable_account | :ambiguous_executable_account}
  def resolve_executable_account do
    case executable_smart_accounts() do
      [single] -> {:ok, single}
      [] -> {:error, :no_executable_account}
      _ -> {:error, :ambiguous_executable_account}
    end
  end

  defp executable_smart_accounts do
    Delegations.list_active()
    |> Enum.map(& &1.smart_account_id)
    |> Enum.uniq()
    |> Enum.filter(&Delegations.executable?/1)
  end

  defp create_execution_plan(envelope, smart_account_id, source, opts)
       when source in [:manual, :auto] do
    # Resolve the workspace_id up front so the chain-pause gate
    # (#228 Phase 1) can consult `Bank.Security.paused?/2` with a
    # workspace key. Legacy unscoped intents (#158 tail) leave
    # `workspace_id` as `nil`; the chain-pause check tolerates that
    # and falls through to the global-pause result.
    workspace_id = lookup_intent_workspace_id(envelope.intent_id)
    chain = "base"

    with :ok <- validate_executable_envelope(envelope),
         :ok <- validate_no_active_plan(envelope.id),
         :ok <- validate_stablecoin_adapter_ready(envelope),
         :ok <- validate_not_paused(workspace_id, chain),
         :ok <- Bank.Chains.validate_mainnet_allowed(chain, workspace_id),
         :ok <- validate_delegation_active(smart_account_id) do
      reason = Keyword.get(opts, :reason, default_reason_for(source))

      plan_attrs = %{
        decision_id: envelope.id,
        intent_id: envelope.intent_id,
        chain: chain,
        asset: "USDC",
        smart_account_id: smart_account_id,
        execution_status: :prepared,
        signing_requirements: build_signing_requirements(smart_account_id),
        workspace_id: workspace_id
      }

      {:ok, plan} =
        %ExecutionPlan{}
        |> ExecutionPlan.changeset(plan_attrs)
        |> Repo.insert()

      _ = Runtime.emit_audit(audit_attrs_for_source(plan, source, opts))

      Runtime.broadcast_intent_lifecycle(envelope.intent_id, :execution_requested, %{
        decision_id: envelope.id,
        plan_id: plan.id,
        reason: reason,
        source: source
      })

      _ = Runtime.enqueue_execution(envelope.id)

      {:ok, plan}
    end
  end

  defp lookup_intent_workspace_id(intent_id) when is_binary(intent_id) do
    Repo.one(from(i in AgentIntent, where: i.id == ^intent_id, select: i.workspace_id))
  end

  defp default_reason_for(:manual), do: "manual_confirm"
  defp default_reason_for(:auto), do: "auto_exec_dispatch"

  defp audit_attrs_for_source(plan, :manual, opts) do
    Bank.Audit.Events.execution_manually_requested(plan,
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id)
    )
  end

  defp audit_attrs_for_source(plan, :auto, opts) do
    Bank.Audit.Events.execution_auto_dispatched(plan,
      actor: Keyword.get(opts, :actor, :runtime),
      actor_id: Keyword.get(opts, :actor_id)
    )
  end

  # --- Validation gates ---------------------------------------------------

  defp validate_executable_envelope(%DecisionEnvelope{current: true, outcome: :auto_exec}),
    do: :ok

  defp validate_executable_envelope(%DecisionEnvelope{current: false}),
    do: {:error, :not_current}

  defp validate_executable_envelope(%DecisionEnvelope{outcome: outcome}),
    do: {:error, :"outcome_is_#{outcome}"}

  defp validate_no_active_plan(envelope_id) do
    case active_plan_for(envelope_id) do
      nil -> :ok
      _plan -> {:error, :active_plan_exists}
    end
  end

  defp validate_stablecoin_adapter_ready(%DecisionEnvelope{} = envelope) do
    if stablecoin_route_requires_adapter?(envelope.reasons) do
      {:error, :stablecoin_adapter_not_wired}
    else
      :ok
    end
  end

  defp stablecoin_route_requires_adapter?(%{"items" => items}) when is_list(items) do
    Enum.any?(items, fn item ->
      item
      |> reason_details()
      |> stablecoin_route_from_details()
      |> route_requires_adapter?()
    end)
  end

  defp stablecoin_route_requires_adapter?(%{items: items}) when is_list(items) do
    stablecoin_route_requires_adapter?(%{"items" => items})
  end

  defp stablecoin_route_requires_adapter?(_), do: false

  defp reason_details(%{"details" => details}), do: details
  defp reason_details(%{details: details}), do: details
  defp reason_details(_), do: %{}

  defp stablecoin_route_from_details(%{"stablecoin_route" => route}), do: route
  defp stablecoin_route_from_details(%{stablecoin_route: route}), do: route
  defp stablecoin_route_from_details(_), do: nil

  defp route_requires_adapter?(%{"execution_state" => "requires_adapter"}), do: true
  defp route_requires_adapter?(%{execution_state: :requires_adapter}), do: true
  defp route_requires_adapter?(_), do: false

  # Chain-pause gate (#228 Phase 1) — global pause wins first to
  # preserve the existing `{:error, :runtime_paused}` shape;
  # workspace-scoped chain pauses surface as `{:error,
  # :chain_paused}`. Nil workspace_id is legacy-safe: the chain
  # check is skipped and only the global gate applies.
  defp validate_not_paused(workspace_id, chain) when is_binary(chain) do
    cond do
      Security.paused?(:global) ->
        {:error, :runtime_paused}

      is_binary(workspace_id) and Security.paused?(workspace_id, {:chain, chain}) ->
        {:error, :chain_paused}

      true ->
        :ok
    end
  end

  defp validate_delegation_active(smart_account_id) do
    if Delegations.executable?(smart_account_id) do
      :ok
    else
      {:error, :delegation_not_active}
    end
  end

  defp build_signing_requirements(smart_account_id) do
    case Delegations.get(smart_account_id) do
      %{delegation_id: del_id, scope: scope} ->
        %{"delegation_id" => del_id, "scope" => scope || %{}}

      _ ->
        %{}
    end
  end

  # --- Adapter callback application --------------------------------------

  @execution_callback_kinds ~w(execution.broadcast execution.confirmed execution.reverted execution.aborted)

  # Terminal `execution_status` values: rows in these states have
  # already been finalised (either by an operator abort or by a
  # prior adapter callback) and MUST NOT be mutated by a late /
  # duplicate adapter callback. See `terminal_execution_status?/1`
  # and `apply_execution_callback/1`.
  @terminal_execution_statuses [:confirmed, :reverted, :aborted]

  @doc """
  Apply an `execution.*` adapter callback to the referenced plan,
  atomically updating the plan's status (and final outcome for
  terminal callbacks) together with the owning intent's state.

  The returned shape exposes just enough information for the caller
  (the internal callback controller) to emit the matching audit
  events and realtime broadcasts, without having to re-query state.

      {:ok,
        %{
          plan: updated_plan,
          prior_plan_status: atom(),
          intent_transition:
            {:transitioned, prior_state, updated_intent}
            | {:no_transition, current_state}
            | :not_applicable
        }}
      | {:error, :plan_not_found}
      | {:error, :unknown_kind}
      | {:error, Ecto.Changeset.t()}

  Unknown `execution_plan_id` is the one soft-failure mode: the
  adapter is expected to dedupe on its side per
  `priv/adapter/contract.md §4`, so we log and return
  `{:error, :plan_not_found}` which the controller turns into
  `accepted_with_warning`.

  ### Kind → transitions

    * `execution.broadcast` → plan `:broadcasting`; intent unchanged
      (unless still `:decided`, in which case advance to
      `:executing` to recover from a dropped `RunExecution` side
      effect).
    * `execution.confirmed` → plan `:confirmed`, `final_outcome:
      :confirmed`; intent `:executing | :decided` → `:executed`.
    * `execution.reverted`  → plan `:reverted`, `final_outcome:
      :reverted`; intent `:executing | :decided` → `:blocked`.
    * `execution.aborted`   → plan `:aborted`, `final_outcome:
      :aborted`; intent `:executing | :decided` → `:blocked`.
  """
  @spec apply_execution_callback(map()) ::
          {:ok,
           %{
             plan: ExecutionPlan.t(),
             prior_plan_status: atom(),
             intent_transition:
               {:transitioned, atom(), AgentIntent.t()}
               | {:no_transition, atom()}
               | :not_applicable
           }}
          | {:error,
             :plan_not_found
             | :unknown_kind
             | {:terminal_state, atom()}
             | Ecto.Changeset.t()}
  def apply_execution_callback(%{"kind" => kind, "execution_plan_id" => plan_id} = params)
      when kind in @execution_callback_kinds and is_binary(plan_id) do
    # Lock the row `FOR UPDATE` inside the transaction so a concurrent
    # operator `abort_plan/3` (which locks the same row) serialises
    # against this writer rather than racing it. After the lock is
    # held, refuse callbacks against rows already in a terminal
    # state — without this guard a late or duplicated
    # `execution.confirmed` from the adapter could overwrite an
    # operator-`:aborted` plan back to `:confirmed`. The controller
    # converts `{:terminal_state, _}` to `200 accepted_with_warning`
    # so the adapter does not retry.
    Repo.transaction(fn ->
      case lock_plan_for_callback(plan_id) do
        nil ->
          Repo.rollback(:plan_not_found)

        %ExecutionPlan{execution_status: status} when status in @terminal_execution_statuses ->
          Repo.rollback({:terminal_state, status})

        %ExecutionPlan{} = plan ->
          prior_status = plan.execution_status

          case progress_plan_for_kind(plan, kind, params) do
            {:ok, updated_plan} ->
              intent_transition = advance_intent_for_kind(plan.intent, updated_plan, kind)

              %{
                plan: updated_plan,
                prior_plan_status: prior_status,
                intent_transition: intent_transition,
                # Carry the preloaded intent forward so the
                # post-commit notification emitter can pull
                # `intent.workspace_id` without an extra round-
                # trip. The wrapper below pops this out of the
                # public return shape.
                __intent: plan.intent
              }

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, %{__intent: intent, plan: %ExecutionPlan{} = plan} = result} ->
        # Inbox notification (#234). Best-effort: the emitter logs
        # and returns rather than raising on a validation failure,
        # so the callback path is never broken by a notification-
        # side error. Emission happens *after* the multi commits
        # so the underlying execution-state transition is durable
        # before the inbox row is attempted.
        plan_with_intent = %{plan | intent: intent}
        _ = Bank.Notifications.Emitter.emit_execution_outcome(plan_with_intent)

        {:ok, Map.delete(result, :__intent)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_execution_callback(_), do: {:error, :unknown_kind}

  @doc """
  True for `execution_status` values that have reached a terminal
  state — `:confirmed`, `:reverted`, or `:aborted`. Centralised so
  the callback guard, future replay tooling, and tests share a
  single definition.
  """
  @spec terminal_execution_status?(atom()) :: boolean()
  def terminal_execution_status?(status), do: status in @terminal_execution_statuses

  defp lock_plan_for_callback(plan_id) do
    query =
      from p in ExecutionPlan,
        where: p.id == ^plan_id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> nil
      plan -> Repo.preload(plan, :intent)
    end
  end

  # --- Worker dispatch claim / revert (#230 P1 race fix) -------------------

  @typedoc """
  Outcome of `claim_plan_for_dispatch/1`. The `:cancel` shape is
  modeled on Oban's worker `{:cancel, reason}` so the worker can
  re-emit it directly.
  """
  @type claim_result ::
          {:ok, ExecutionPlan.t()}
          | {:cancel, {:not_prepared, atom()}}
          | {:cancel, :not_found}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Atomically claim an execution plan for adapter dispatch (#230 P1).

  Locks the plan row `FOR UPDATE` and transitions
  `:prepared → :signing` only if the **current DB row** is still
  `:prepared`. Any other state — `:aborted` from an operator,
  `:signing` / `:broadcasting` / `:pending_confirmation` from a
  parallel claim or an adapter callback that already landed,
  `:confirmed` / `:reverted` — collapses to `{:cancel, {:not_prepared,
  status}}` and the caller MUST NOT proceed to call the adapter.

  Background: `RunExecution` previously read a `:prepared` plan
  without a lock, called the adapter, and only then transitioned
  `:prepared → :signing`. An operator's `abort_plan/3` could land
  between the read and the post-dispatch update, leaving the abort
  silently clobbered when the worker wrote `:signing`. Per the
  parent epic guardrail "abort beats dispatch", the worker now
  claims first and dispatches second.

  Lifecycle of an abort-vs-dispatch race:

    * Operator and worker both target the same `:prepared` plan.
    * Whichever transaction acquires the row lock first wins.
    * If abort wins → row is `:aborted`. The worker's claim sees
      `:aborted` and cancels without an adapter call.
    * If claim wins → row is `:signing`. The operator's
      `abort_plan/3` sees `:signing`, returns
      `{:error, {:not_safe_to_abort, :signing}}`. The adapter
      runs to completion via `RunExecution`.

  After a successful claim the caller is expected to dispatch and
  either (a) advance to `:broadcasting` via the adapter callback or
  (b) call `revert_claim/1` to flip `:signing → :prepared` so a
  retry can re-attempt. Adapter 4xx still goes through the existing
  `mark_plan_aborted` path — `:signing → :aborted` is allowed
  because the plan was dispatched but rejected.
  """
  @spec claim_plan_for_dispatch(ExecutionPlan.t()) :: claim_result()
  def claim_plan_for_dispatch(%ExecutionPlan{id: id}) do
    Repo.transaction(fn ->
      case Repo.one(from p in ExecutionPlan, where: p.id == ^id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        %ExecutionPlan{execution_status: :prepared} = locked ->
          case locked
               |> ExecutionPlan.progress_changeset(%{execution_status: :signing})
               |> Repo.update() do
            {:ok, claimed} -> Repo.preload(claimed, :intent)
            {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
          end

        %ExecutionPlan{execution_status: status} ->
          Repo.rollback({:not_prepared, status})
      end
    end)
    |> case do
      {:ok, %ExecutionPlan{} = claimed} -> {:ok, claimed}
      {:error, :not_found} -> {:cancel, :not_found}
      {:error, {:not_prepared, _} = reason} -> {:cancel, reason}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  @doc """
  Revert a previously-claimed dispatch when the adapter call could
  not complete (#230 P1).

  Guarded transition `:signing → :prepared` so a retry job can
  re-claim. If the row is no longer `:signing` (e.g. an
  `execution.broadcast` callback already landed, or an
  adapter-rejection abort moved it to `:aborted`), the revert is a
  no-op — terminal rows MUST NOT be resurrected. Returns
  `{:ok, :reverted}` on the happy path or
  `{:ok, {:no_revert, status}}` when the guard short-circuited.
  """
  @spec revert_claim(ExecutionPlan.t()) ::
          {:ok, :reverted}
          | {:ok, {:no_revert, atom()}}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
  def revert_claim(%ExecutionPlan{id: id}) do
    Repo.transaction(fn ->
      case Repo.one(from p in ExecutionPlan, where: p.id == ^id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        %ExecutionPlan{execution_status: :signing} = locked ->
          case locked
               |> ExecutionPlan.progress_changeset(%{execution_status: :prepared})
               |> Repo.update() do
            {:ok, _} -> :reverted
            {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
          end

        %ExecutionPlan{execution_status: status} ->
          {:no_revert, status}
      end
    end)
    |> case do
      {:ok, :reverted} -> {:ok, :reverted}
      {:ok, {:no_revert, status}} -> {:ok, {:no_revert, status}}
      {:error, :not_found} -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  # --- Operator manual abort (#230) ---------------------------------------

  @typedoc """
  Result of `abort_plan/3`. The discriminator atom signals whether
  the call performed the actual abort transition or short-circuited
  on an already-terminal row.
  """
  @type abort_intent_transition ::
          {:transitioned, atom(), AgentIntent.t()}
          | {:no_transition, atom()}
          | :not_applicable

  @type abort_result ::
          {:ok, :aborted | :already_terminal, ExecutionPlan.t(), abort_intent_transition()}
          | {:error, :not_found}
          | {:error, {:not_safe_to_abort, atom()}}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Manually abort a stuck execution plan (#230, #212).

  Forces a plan currently in `:prepared` to the terminal `:aborted`
  state and (when present) transitions the parent intent
  `:decided | :executing → :blocked`. Performs **no** chain
  dispatch, **no** adapter call, and **no** worker broadcast — the
  plan never reached the adapter while in `:prepared` (no
  `adapter_ref`, no `tx_refs`, no `nonce`), so this path is purely
  a DB state-machine flip plus audit emit.

  ## Concurrency / idempotency

  The plan row is locked `FOR UPDATE` for the entire transition so
  concurrent operators / a late adapter callback observe a single
  committed final state. Idempotent re-call against an
  already-terminal plan returns
  `{:ok, :already_terminal, plan, intent_transition}` — no second
  audit row is emitted.

  ## Workspace boundary

  The plan lookup filters by `workspace_id` inside the locked
  SELECT. Cross-workspace and missing-id collapse to the same
  `{:error, :not_found}` so existence is never disclosed across
  workspaces (mirrors `Bank.APIKeys.get_workspace_key/2`).

  ## Safe-state guard

  Only `:prepared` plans are abortable here. A plan in `:signing`,
  `:broadcasting`, or `:pending_confirmation` has already been
  dispatched to the adapter; aborting locally without an
  adapter-level cancel would orphan a real chain operation, so
  this function returns `{:error, {:not_safe_to_abort, status}}`
  for those cases. The future "abort dispatched plan" flow
  belongs in a separate slice paired with an adapter cancel
  endpoint.

  ## Caller contract

  The caller (typically `BankWeb.API.V1.SecurityController.abort_execution/2`)
  must already have authenticated the operator and resolved the
  workspace from `current_scope`. This function does **not** check
  caller role — that is the controller's pipeline (`:api_admin`).

  ## opts

    * `:reason` — atom; allowlisted at the controller boundary
      (`parse_abort_reason/1` rejects atom-table abuse). Defaults
      to `:operator_requested`. Persisted as a string on
      `final_reason` and on the audit `after_ref`.
    * `:actor` — atom; defaults to `:user`.
    * `:actor_id` — uuid; the operator's user id when known.
  """
  @spec abort_plan(String.t(), Bank.Workspaces.Workspace.t(), keyword()) :: abort_result()
  def abort_plan(plan_id, workspace, opts \\ [])

  def abort_plan(plan_id, %Bank.Workspaces.Workspace{id: ws_id}, opts) when is_binary(plan_id) do
    reason = Keyword.get(opts, :reason, :operator_requested)
    actor = Keyword.get(opts, :actor, :user)
    actor_id = Keyword.get(opts, :actor_id)

    Repo.transaction(fn ->
      case lock_plan_in_workspace(plan_id, ws_id) do
        nil ->
          Repo.rollback(:not_found)

        %ExecutionPlan{execution_status: status} = plan
        when status in [:confirmed, :reverted, :aborted] ->
          {:already_terminal, plan, no_intent_transition(plan)}

        %ExecutionPlan{execution_status: :prepared} = plan ->
          do_abort_prepared(plan, reason, actor, actor_id)

        %ExecutionPlan{execution_status: status} ->
          Repo.rollback({:not_safe_to_abort, status})
      end
    end)
    |> case do
      {:ok, {discriminator, plan, intent_transition}} ->
        {:ok, discriminator, plan, intent_transition}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, {:not_safe_to_abort, _status} = e} ->
        {:error, e}

      {:error, other} ->
        {:error, other}
    end
  end

  defp lock_plan_in_workspace(plan_id, ws_id) do
    query =
      from p in ExecutionPlan,
        where: p.id == ^plan_id and p.workspace_id == ^ws_id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> nil
      plan -> Repo.preload(plan, :intent)
    end
  end

  defp do_abort_prepared(%ExecutionPlan{} = plan, reason, actor, actor_id) do
    prior_status = plan.execution_status
    reason_str = Atom.to_string(reason)

    with {:ok, aborted} <-
           plan
           |> ExecutionPlan.progress_changeset(%{
             execution_status: :aborted,
             final_outcome: :aborted,
             final_reason: reason_str,
             # Flip `active: false` so the partial unique index
             # `execution_plans_decision_active_idx` releases the slot
             # and the operator can `request_manual_execution/3` for
             # the same decision again. The terminal-state-derived
             # filter on `count_active_executions/1` agrees with
             # this — both signals are now consistent. Adapter-driven
             # terminal transitions (`apply_execution_callback`'s
             # `confirmed` / `reverted` / `aborted` paths) flip the
             # same flag for the same reason; both code paths share
             # the symmetric "terminal → !active" invariant.
             active: false
           })
           |> Repo.update(),
         intent_transition =
           transition_intent_to_blocked(plan.intent, aborted, actor, actor_id),
         {:ok, _audit} <- emit_abort_audit(aborted, prior_status, actor, actor_id) do
      {:aborted, aborted, intent_transition}
    else
      {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
      {:error, other} -> Repo.rollback(other)
    end
  end

  defp transition_intent_to_blocked(nil, _plan, _actor, _actor_id), do: :not_applicable

  defp transition_intent_to_blocked(
         %AgentIntent{state: state} = intent,
         %ExecutionPlan{} = plan,
         actor,
         actor_id
       )
       when state in [:decided, :executing] do
    {:ok, updated} =
      intent
      |> AgentIntent.current_pointer_changeset(%{
        state: :blocked,
        current_execution_plan_id: plan.id
      })
      |> Repo.update()

    case Audit.append_event(intent_audit_attrs(updated, state, :blocked, actor, actor_id)) do
      {:ok, _} -> {:transitioned, state, updated}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transition_intent_to_blocked(%AgentIntent{state: state}, _plan, _actor, _actor_id) do
    {:no_transition, state}
  end

  defp emit_abort_audit(%ExecutionPlan{} = plan, prior_status, actor, actor_id) do
    plan
    |> Events.execution_transition(prior_status, actor: actor)
    |> Map.put(:actor_id, actor_id)
    |> Audit.append_event()
  end

  defp intent_audit_attrs(%AgentIntent{} = intent, from, to, actor, actor_id) do
    intent
    |> Events.intent_state_changed(from, to, actor: actor)
    |> Map.put(:actor_id, actor_id)
  end

  defp no_intent_transition(%ExecutionPlan{intent: %AgentIntent{state: state}}),
    do: {:no_transition, state}

  defp no_intent_transition(_), do: :not_applicable

  defp progress_plan_for_kind(plan, "execution.broadcast", params) do
    plan
    |> ExecutionPlan.progress_changeset(
      attrs_with_tx_refs(%{execution_status: :broadcasting, nonce: first_nonce(params)}, params)
    )
    |> Repo.update()
  end

  defp progress_plan_for_kind(plan, "execution.confirmed", params) do
    plan
    |> ExecutionPlan.progress_changeset(
      attrs_with_tx_refs(
        %{execution_status: :confirmed, final_outcome: :confirmed, active: false},
        params
      )
    )
    |> Repo.update()
  end

  defp progress_plan_for_kind(plan, "execution.reverted", params) do
    plan
    |> ExecutionPlan.progress_changeset(
      attrs_with_tx_refs(
        %{
          execution_status: :reverted,
          final_outcome: :reverted,
          final_reason: Map.get(params, "reason"),
          active: false
        },
        params
      )
    )
    |> Repo.update()
  end

  defp progress_plan_for_kind(plan, "execution.aborted", params) do
    plan
    |> ExecutionPlan.progress_changeset(%{
      execution_status: :aborted,
      final_outcome: :aborted,
      final_reason: Map.get(params, "reason"),
      active: false
    })
    |> Repo.update()
  end

  defp attrs_with_tx_refs(attrs, params) do
    case tx_hashes(params) do
      [] -> attrs
      refs -> Map.put(attrs, :tx_refs, refs)
    end
  end

  defp advance_intent_for_kind(nil, _plan, _kind), do: :not_applicable

  defp advance_intent_for_kind(%AgentIntent{} = intent, %ExecutionPlan{} = plan, kind) do
    target_state = target_intent_state(kind)

    cond do
      is_nil(target_state) ->
        # execution.broadcast doesn't normally move the intent; the
        # only exception is recovering from a dropped RunExecution
        # side effect where the intent is still `:decided`.
        if intent.state == :decided do
          transition_intent(intent, plan, :executing)
        else
          {:no_transition, intent.state}
        end

      intent.state == target_state ->
        {:no_transition, intent.state}

      true ->
        transition_intent(intent, plan, target_state)
    end
  end

  defp transition_intent(%AgentIntent{state: prior} = intent, %ExecutionPlan{} = plan, target) do
    {:ok, updated} =
      intent
      |> AgentIntent.current_pointer_changeset(%{
        state: target,
        current_execution_plan_id: plan.id
      })
      |> Repo.update()

    {:transitioned, prior, updated}
  end

  defp target_intent_state("execution.broadcast"), do: nil
  defp target_intent_state("execution.confirmed"), do: :executed
  defp target_intent_state("execution.reverted"), do: :blocked
  defp target_intent_state("execution.aborted"), do: :blocked

  # tx_refs now carry *either* an on-chain `hash` (EOA path) or an
  # EntryPoint `userop_hash` (ERC-4337 v0.7 AA path). The AA confirmed
  # callback carries both: the user-op hash anchors the bundler-side
  # identity, the tx hash anchors the chain-side inclusion. Phoenix
  # persists the union so audit / replay can reconstruct the full
  # lifecycle; ordering keeps `userop_hash` first so Basescan-style
  # links in the control tower default to the AA identifier when both
  # are present.
  defp tx_hashes(%{"tx_refs" => refs}) when is_list(refs) do
    refs
    |> Enum.flat_map(fn
      ref when is_map(ref) ->
        userop = Map.get(ref, "userop_hash")
        hash = Map.get(ref, "hash")

        [userop, hash]
        |> Enum.filter(&is_binary/1)

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp tx_hashes(_), do: []

  # AA 2D nonces are 256-bit values that don't fit the plan's
  # `:integer` column. When the adapter emits a hex nonce (AA path) we
  # leave `plan.nonce` nil and rely on `tx_refs` for full fidelity;
  # integer nonces (EOA path) are still persisted as before.
  defp first_nonce(%{"tx_refs" => [%{"nonce" => nonce} | _]}) when is_integer(nonce), do: nonce
  defp first_nonce(_), do: nil
end
