defmodule Bank.Decisions.Report do
  @moduledoc """
  Deterministic decision report model (#248).

  Builds a stable, replay-derived report struct from a
  `Bank.Audit.replay/1` bundle. Same source bundle → same report
  payload, byte-for-byte. Missing evidence is **labelled** (not
  hidden) so a reader can tell "no simulation recorded" apart from
  "the report builder forgot the field". Secrets, raw provider
  payloads, and signing material are intentionally excluded.

  This module is read-only: it never persists rows, never enqueues
  workers, never calls adapter or broadcast paths.

  ## Building

      {:ok, bundle} = Bank.Audit.replay(intent_id)
      report = Bank.Decisions.Report.from_bundle(bundle)

      # Convenience wrapper:
      {:ok, report} = Bank.Decisions.Report.from_intent_id(intent_id)

  ## Determinism contract

  `from_bundle/1` is a pure function on its input. The replay bundle
  itself is deterministic-ordered (`Bank.Audit.replay/1` orders all
  child collections by domain timestamp + id tiebreak), so two
  consecutive calls with the same bundle produce identical structs.
  No `DateTime.utc_now/0` or other transient field is read inside
  this module — every timestamp comes from a persisted row.

  ## Sections

  Each section is one of:

    * a populated map (always carries `available: true` for
      optional sections), or
    * `%{available: false, reason: "<short label>"}` when the
      underlying replay rows are absent.

  Required sections (always populated from the intent itself):

    * `:intent`              — id, kind, asset, chain, amount, state,
      idempotency_key, target shape, submitted_at.
    * `:actor_source`        — agent_id, source, workspace_id.
    * `:flags`               — chain, mainnet?/testnet?, live?/stub?.
    * `:audit_trail`         — list of audit-event summaries
      (event_type, actor, ts, subject) — no `before_ref`/`after_ref`
      payloads, which can carry secrets / raw provider data.

  Optional / labelled-when-missing sections:

    * `:trust_assessment`    — derived_trust + confidence + counts.
    * `:simulation`          — provider, status, gas/output/slippage
      summary; raw `predicted_balance_changes` payloads excluded.
    * `:screening_evidence`  — outcome + winning record summary.
    * `:policy_snapshot`     — rules referenced by decisions
      (id, rule_type, priority, state, version, sorted param keys —
      values omitted to avoid leaking config that may carry
      provider-specific identifiers).
    * `:decision_envelope`   — outcome, risk_tier, decided_by,
      reasons.
    * `:approval`            — auto_exec / hold / approval_required /
      block summary derived from the latest decision envelope.
    * `:execution_plan`      — chain, asset, smart_account_id,
      execution_status, final_outcome, tx_refs (chain-public).
    * `:stablecoin_routes`   — pre-computed route evidence pulled
      from `stablecoin.route_evaluated` audit events.

  `:residual_limitations` is always a list of short strings naming
  the optional sections that were missing or that block the report
  from being a fully-closed evidence trail (e.g. "decision is hold;
  awaiting operator action").

  ## Secret hygiene

  This module never includes:

    * `signing_requirements` (key reference material)
    * audit `before_ref` / `after_ref` payloads
    * raw policy rule `params` values
    * raw simulation `predicted_balance_changes` /
      `routing_path` / `failure_conditions` items

  `tx_refs` and `provider_trace_ref` ARE included — both are
  publicly observable via chain explorers / provider dashboards
  and are required for incident replay.
  """

  alias Bank.Audit
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan, SimulationReport, TrustAssessment}
  alias Bank.Intents.AgentIntent

  @schema_version "1"
  @mainnet_chains ~w(base ethereum)
  @testnet_chains ~w(base-sepolia sepolia goerli)

  @type missing_section :: %{available: false, reason: String.t()}

  @type t :: %__MODULE__{
          version: String.t(),
          generated_from: %{intent_id: String.t(), workspace_id: String.t() | nil},
          intent: map(),
          actor_source: map(),
          trust_assessment: map() | missing_section(),
          simulation: map() | missing_section(),
          screening_evidence: map() | missing_section(),
          policy_snapshot: map() | missing_section(),
          decision_envelope: map() | missing_section(),
          approval: map() | missing_section(),
          execution_plan: map() | missing_section(),
          stablecoin_routes: [map()],
          flags: map(),
          residual_limitations: [String.t()],
          audit_trail: [map()]
        }

  @derive {Jason.Encoder,
           only: [
             :version,
             :generated_from,
             :intent,
             :actor_source,
             :trust_assessment,
             :simulation,
             :screening_evidence,
             :policy_snapshot,
             :decision_envelope,
             :approval,
             :execution_plan,
             :stablecoin_routes,
             :flags,
             :residual_limitations,
             :audit_trail
           ]}
  defstruct [
    :version,
    :generated_from,
    :intent,
    :actor_source,
    :trust_assessment,
    :simulation,
    :screening_evidence,
    :policy_snapshot,
    :decision_envelope,
    :approval,
    :execution_plan,
    :stablecoin_routes,
    :flags,
    :residual_limitations,
    :audit_trail
  ]

  @doc """
  Convenience wrapper: replay the intent then build the report.

  Returns `{:ok, %Report{}}` or `{:error, :not_found}` mirroring
  `Bank.Audit.replay/1`. Note that `Audit.replay/1` itself does not
  workspace-scope the lookup — callers that need workspace
  isolation should prefer building from a bundle they have already
  workspace-gated (e.g. via `Bank.Intents.get_in_workspace/2` →
  `Bank.Audit.replay/1`).
  """
  @spec from_intent_id(Ecto.UUID.t()) :: {:ok, t()} | {:error, :not_found}
  def from_intent_id(intent_id) when is_binary(intent_id) do
    with {:ok, bundle} <- Audit.replay(intent_id) do
      {:ok, from_bundle(bundle)}
    end
  end

  @doc """
  Build a deterministic report struct from a replay bundle.

  The bundle must match the shape returned by
  `Bank.Audit.replay/1` (must contain `:intent` keyed to an
  `%AgentIntent{}`).
  """
  @spec from_bundle(map()) :: t()
  def from_bundle(%{intent: %AgentIntent{} = intent} = bundle) do
    decisions = bundle[:decisions] || []
    plans = bundle[:plans] || []

    %__MODULE__{
      version: @schema_version,
      generated_from: %{
        intent_id: intent.id,
        workspace_id: intent.workspace_id
      },
      intent: intent_section(intent),
      actor_source: actor_source_section(intent),
      trust_assessment:
        latest_section(
          bundle[:trust_assessments],
          &trust_section/1,
          "no trust assessment recorded"
        ),
      simulation:
        latest_section(bundle[:simulations], &simulation_section/1, "no simulation recorded"),
      screening_evidence: screening_section(bundle[:screening_evidence]),
      policy_snapshot: policy_section(bundle[:policy_snapshot]),
      decision_envelope:
        latest_section(decisions, &decision_section/1, "no decision envelope recorded"),
      approval: approval_section(decisions),
      execution_plan: execution_plan_with_matches(plans, bundle[:matched_activities] || []),
      stablecoin_routes: bundle[:stablecoin_route_evidence] || [],
      flags: flags_section(intent, plans),
      residual_limitations: residual_limitations(bundle),
      audit_trail: audit_trail_section(bundle[:audit] || [])
    }
  end

  # --- intent ---------------------------------------------------------------

  defp intent_section(%AgentIntent{} = i) do
    %{
      id: i.id,
      kind: maybe_string(i.kind),
      asset: i.asset,
      chain: i.chain,
      amount: maybe_decimal_to_string(i.amount),
      state: maybe_string(i.state),
      idempotency_key: i.idempotency_key,
      target: target_section(i),
      submitted_at: maybe_iso(i.submitted_at)
    }
  end

  defp target_section(%AgentIntent{
         target_counterparty_id: cp_id,
         target_address_label_id: al_id,
         target_raw_address: nil
       })
       when not is_nil(cp_id) do
    %{kind: "counterparty", counterparty_id: cp_id, address_label_id: al_id}
  end

  defp target_section(%AgentIntent{target_raw_address: addr}) when is_binary(addr) do
    %{kind: "raw_address", address: addr}
  end

  defp target_section(_), do: %{kind: "unspecified"}

  # --- actor / source / workspace -------------------------------------------

  defp actor_source_section(%AgentIntent{} = i) do
    %{
      agent_id: i.agent_id,
      source: maybe_string(i.source),
      workspace_id: i.workspace_id
    }
  end

  # --- helpers for "latest of list" -----------------------------------------

  defp latest_section(nil, _fun, label), do: missing(label)
  defp latest_section([], _fun, label), do: missing(label)

  defp latest_section(list, fun, _label) when is_list(list) do
    list |> List.last() |> fun.()
  end

  # --- trust ----------------------------------------------------------------

  defp trust_section(%TrustAssessment{} = t) do
    %{
      available: true,
      id: t.id,
      derived_trust: maybe_string(t.derived_trust),
      confidence: maybe_string(t.confidence),
      generated_at: maybe_iso(t.generated_at),
      generated_by: maybe_string(t.generated_by),
      contradictions_count: count_items(t.contradictions),
      supporting_assertion_ids: t.supporting_assertion_ids || [],
      supporting_evidence_ids: t.supporting_evidence_ids || [],
      current: t.current,
      supersedes_id: t.supersedes_id
    }
  end

  # --- simulation -----------------------------------------------------------

  defp simulation_section(%SimulationReport{} = s) do
    %{
      available: true,
      id: s.id,
      provider: s.provider,
      provider_trace_ref: s.provider_trace_ref,
      chain: s.chain,
      asset: s.asset,
      status: maybe_string(s.status),
      generated_at: maybe_iso(s.generated_at),
      freshness_ttl_seconds: s.freshness_ttl_seconds,
      estimated_gas: s.estimated_gas,
      expected_output: maybe_decimal_to_string(s.expected_output),
      slippage_exposure: maybe_decimal_to_string(s.slippage_exposure),
      predicted_balance_change_count: count_items(s.predicted_balance_changes),
      failure_condition_count: count_items(s.failure_conditions),
      current: s.current
    }
  end

  # --- screening evidence ---------------------------------------------------

  defp screening_section(nil), do: missing("no screening evidence recorded")

  defp screening_section(map) when is_map(map) and map_size(map) == 0,
    do: missing("no screening evidence recorded")

  defp screening_section(%{outcome: _outcome} = ev) do
    %{
      available: true,
      outcome: maybe_string(ev[:outcome]),
      screened_address: ev[:screened_address],
      screened_chain: ev[:screened_chain],
      winning_tier: maybe_string(ev[:winning_tier]),
      winning_source: ev[:winning_source],
      winning_reason: ev[:winning_reason],
      total_records: ev[:total_records] || 0,
      record_count: length(ev[:records] || []),
      feed_health_count: length(ev[:feed_health] || [])
    }
  end

  defp screening_section(_), do: missing("screening evidence shape unknown")

  # --- policy snapshot ------------------------------------------------------

  defp policy_section(nil), do: missing("no policy snapshot captured")
  defp policy_section([]), do: missing("no policy snapshot captured")

  defp policy_section(rules) when is_list(rules) do
    %{
      available: true,
      rule_count: length(rules),
      rules: rules |> Enum.sort_by(& &1.id) |> Enum.map(&policy_rule_summary/1)
    }
  end

  defp policy_rule_summary(%{__struct__: _} = rule) do
    %{
      id: rule.id,
      rule_type: maybe_string(rule.rule_type),
      priority: rule.priority,
      state: maybe_string(rule.state),
      version: Map.get(rule, :version),
      param_keys: rule.params |> Map.keys() |> Enum.sort()
    }
  end

  # --- decision envelope ----------------------------------------------------

  defp decision_section(%DecisionEnvelope{} = d) do
    %{
      available: true,
      id: d.id,
      outcome: maybe_string(d.outcome),
      risk_tier: maybe_string(d.risk_tier),
      decided_at: maybe_iso(d.decided_at),
      decided_by: maybe_string(d.decided_by),
      state: maybe_string(d.state),
      current: d.current,
      supersedes_id: d.supersedes_id,
      approval_expires_at: maybe_iso(d.approval_expires_at),
      reasons: reasons_summary(d.reasons),
      policy_snapshot_rule_ids:
        d.policy_snapshot_ref
        |> snapshot_rule_ids()
        |> Enum.sort()
    }
  end

  defp snapshot_rule_ids(%{} = ref), do: Map.get(ref, "rule_ids") || Map.get(ref, :rule_ids) || []
  defp snapshot_rule_ids(_), do: []

  defp reasons_summary(%{} = reasons) do
    raw = Map.get(reasons, "items") || Map.get(reasons, :items) || []
    items = Enum.map(raw, &reason_item/1)
    %{item_count: length(items), items: items}
  end

  defp reasons_summary(_), do: %{item_count: 0, items: []}

  # `decision_envelope.reasons.items[]` is mixed-shape (#248 P2):
  #
  #   * Runtime-generated items are bare strings — programmer-written
  #     labels like `"policy.amount_limit ok"`. Safe to pass through.
  #   * Operator approval/rejection items (see
  #     `Bank.Decisions.apply_approval_decision/2`) are maps with
  #     `"code"`, `"message"`, `"actor_id"` keys. The `message`
  #     value is operator-supplied free text and CAN carry pasted
  #     secrets — a pasted Authorization header, RPC URL with
  #     embedded credentials, or PEM marker would otherwise flow
  #     through the report verbatim into any downstream
  #     #249/#250/#251 export. The audit-safe summary therefore
  #     drops `message` and `details` entirely and exposes only
  #     `code` + `actor_id`. A `redacted: true` marker tells
  #     downstream readers the operator wrote a free-text reason
  #     even though the body was suppressed.
  defp reason_item(text) when is_binary(text), do: text

  defp reason_item(%{} = item) do
    code = Map.get(item, "code") || Map.get(item, :code)
    actor_id = Map.get(item, "actor_id") || Map.get(item, :actor_id)

    redacted? =
      Map.has_key?(item, "message") or Map.has_key?(item, :message) or
        Map.has_key?(item, "details") or Map.has_key?(item, :details)

    base = %{"code" => code, "actor_id" => actor_id}
    if redacted?, do: Map.put(base, "redacted", true), else: base
  end

  defp reason_item(other), do: other

  # --- approval -------------------------------------------------------------

  defp approval_section([]), do: missing("no approval/rejection recorded")

  defp approval_section(decisions) when is_list(decisions) do
    decided = List.last(decisions)

    base = %{
      decided_by: maybe_string(decided.decided_by),
      decided_at: maybe_iso(decided.decided_at)
    }

    case decided.outcome do
      :auto_exec -> Map.merge(base, %{available: true, kind: "auto_exec"})
      :hold -> Map.merge(base, %{available: true, kind: "hold"})
      :approval_required -> %{available: true, kind: "approval_required_pending"}
      :block -> Map.merge(base, %{available: true, kind: "block"})
      other -> %{available: true, kind: maybe_string(other)}
    end
  end

  # --- execution plan -------------------------------------------------------

  defp execution_plan_with_matches(nil, _matches), do: missing("no execution plan recorded")
  defp execution_plan_with_matches([], _matches), do: missing("no execution plan recorded")

  defp execution_plan_with_matches(plans, matches) when is_list(plans) do
    plan = List.last(plans)

    plan
    |> execution_plan_section()
    |> Map.put(:matched_activity, matched_activity_section(plan, matches))
  end

  defp execution_plan_section(%ExecutionPlan{} = p) do
    %{
      available: true,
      id: p.id,
      decision_id: p.decision_id,
      chain: p.chain,
      asset: p.asset,
      smart_account_id: p.smart_account_id,
      execution_status: maybe_string(p.execution_status),
      final_outcome: maybe_string(p.final_outcome),
      final_reason: p.final_reason,
      tx_refs: p.tx_refs || [],
      nonce: p.nonce,
      adapter_ref: p.adapter_ref,
      active: p.active
    }
  end

  # Project the matched-activity rows for THIS plan into a list
  # of safe scalar maps. The reconciliation surface (#246) writes
  # `%{activity: %ImportedActivity{}, plan_id: ..., tx_hash: ...}`
  # into the bundle's `:matched_activities` key; this helper
  # filters by plan_id and exposes only the fields a reviewer
  # needs to follow the link, never raw `metadata` or
  # `provenance` strings (which can carry junk from the source
  # importer).
  defp matched_activity_section(%ExecutionPlan{id: plan_id}, matches) when is_list(matches) do
    matches
    |> Enum.filter(fn
      %{plan_id: ^plan_id} -> true
      _ -> false
    end)
    |> Enum.map(&matched_activity_summary/1)
  end

  defp matched_activity_section(_, _), do: []

  defp matched_activity_summary(%{activity: %{__struct__: _} = a}) do
    %{
      id: a.id,
      tx_hash: a.tx_hash,
      chain: a.chain,
      asset: a.asset,
      direction: maybe_string(a.direction),
      amount: maybe_decimal_to_string(a.amount),
      status: maybe_string(a.status),
      confidence: maybe_string(a.confidence),
      source_type: maybe_string(a.source_type),
      occurred_at: maybe_iso(a.occurred_at)
    }
  end

  # --- flags ----------------------------------------------------------------

  defp flags_section(%AgentIntent{} = i, plans) do
    chain = i.chain
    live? = any_plan_live?(plans)

    %{
      chain: chain,
      mainnet?: chain in @mainnet_chains,
      testnet?: chain in @testnet_chains,
      live?: live?,
      stub?: not live?
    }
  end

  defp any_plan_live?([]), do: false

  defp any_plan_live?(plans) when is_list(plans) do
    Enum.any?(plans, &(&1.execution_status in [:broadcasting, :pending_confirmation, :confirmed]))
  end

  # --- residual limitations -------------------------------------------------

  defp residual_limitations(bundle) do
    []
    |> add_if_missing(bundle[:trust_assessments], "no trust assessment recorded")
    |> add_if_missing(bundle[:simulations], "no simulation recorded")
    |> add_if_missing(bundle[:decisions], "no decision envelope recorded")
    |> add_if_missing(bundle[:plans], "no execution plan recorded")
    |> add_if_held(bundle[:decisions])
    |> Enum.sort()
  end

  defp add_if_missing(acc, nil, msg), do: [msg | acc]
  defp add_if_missing(acc, [], msg), do: [msg | acc]
  defp add_if_missing(acc, list, _msg) when is_list(list), do: acc

  defp add_if_held(acc, [_ | _] = decisions) do
    case List.last(decisions).outcome do
      o when o in [:hold, :approval_required] ->
        ["decision is #{o}; awaiting operator action" | acc]

      _ ->
        acc
    end
  end

  defp add_if_held(acc, _), do: acc

  # --- audit trail ----------------------------------------------------------

  defp audit_trail_section(events) when is_list(events) do
    Enum.map(events, fn e ->
      %{
        id: e.id,
        ts: maybe_iso(e.ts),
        event_type: e.event_type,
        actor: maybe_string(e.actor),
        actor_id: e.actor_id,
        subject_type: e.subject_type,
        subject_id: e.subject_id,
        correlation_id: e.correlation_id,
        workspace_id: e.workspace_id
      }
    end)
  end

  # --- shared helpers -------------------------------------------------------

  defp missing(reason), do: %{available: false, reason: reason}

  defp maybe_iso(nil), do: nil
  defp maybe_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp maybe_decimal_to_string(nil), do: nil
  defp maybe_decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp maybe_decimal_to_string(other), do: other

  defp maybe_string(nil), do: nil
  defp maybe_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp maybe_string(other), do: other

  defp count_items(%{"items" => items}) when is_list(items), do: length(items)
  defp count_items(%{items: items}) when is_list(items), do: length(items)
  defp count_items(items) when is_list(items), do: length(items)
  defp count_items(_), do: 0
end
