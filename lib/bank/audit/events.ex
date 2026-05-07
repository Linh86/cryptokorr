defmodule Bank.Audit.Events do
  @moduledoc """
  Thin builders for the common audit event shapes that engine issues
  will emit.

  Each helper returns an attrs map ready for `Bank.Audit.append_event/1`.
  Helpers never write. Keeping build and write separate lets the
  caller decide whether to emit the event inside an existing
  `Ecto.Multi` or in a simple one-off call, without this module
  reaching into the repo itself.

  The helpers here are not exhaustive. They cover the highest-leverage
  transitions from the runtime-flow doc so the engine issues can
  start emitting events without re-deriving the envelope shape each
  time. Extending the set is cheap: add a small wrapper that fills in
  `subject_type`, `subject_id`, `correlation_id`, and references.
  """

  alias Bank.Access.AccessInvite
  alias Bank.Accounts.User
  alias Bank.APIKeys.APIKey
  alias Bank.Counterparties.{AddressLabel, Counterparty, EvidenceArtifact, TrustAssertion}
  alias Bank.Decisions.{DecisionEnvelope, TrustAssessment, ExecutionPlan, SimulationReport}
  alias Bank.DefiVenues.Morpho.PersistedVaultSnapshot
  alias Bank.DefiVenues.Morpho.VaultSnapshot
  alias Bank.Delegations.Delegation
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.PolicyRule
  alias Bank.Workspaces.Membership

  @type attrs :: map()

  @doc """
  `intent.submitted` — the agent's POST was accepted and deduped.
  """
  @spec intent_submitted(AgentIntent.t(), keyword()) :: attrs()
  def intent_submitted(%AgentIntent{} = intent, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :agent),
      actor_id: intent.agent_id,
      event_type: "intent.submitted",
      subject_type: "agent_intent",
      subject_id: intent.id,
      correlation_id: intent.id,
      after_ref: intent_snapshot(intent),
      workspace_id: intent.workspace_id
    }
  end

  @doc """
  `intent.state_changed` — the intent moved to a new lifecycle state.
  """
  @spec intent_state_changed(AgentIntent.t(), atom(), atom(), keyword()) :: attrs()
  def intent_state_changed(%AgentIntent{} = intent, from, to, opts \\ [])
      when is_atom(from) and is_atom(to) do
    %{
      actor: Keyword.get(opts, :actor, :runtime),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "intent.state_changed",
      subject_type: "agent_intent",
      subject_id: intent.id,
      correlation_id: intent.id,
      before_ref: %{state: Atom.to_string(from)},
      after_ref: %{state: Atom.to_string(to)},
      workspace_id: intent.workspace_id
    }
  end

  @doc """
  `trust.assessed` — a new trust assessment is the current claim for
  an intent.

  Options:

    * `:workspace_id` — the parent intent's workspace_id (#158d-b).
      Carried as a passthrough field on the audit row; not part of
      the canonical hash.
  """
  @spec trust_assessed(TrustAssessment.t(), keyword()) :: attrs()
  def trust_assessed(%TrustAssessment{} = claim, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :runtime),
      event_type: "trust.assessed",
      subject_type: "trust_assessment",
      subject_id: claim.id,
      correlation_id: claim.intent_id,
      before_ref: ref_from_supersedes(claim.supersedes_id, "trust_assessment"),
      after_ref: %{
        id: claim.id,
        derived_trust: atom_or_nil(claim.derived_trust),
        confidence: atom_or_nil(claim.confidence)
      },
      workspace_id: Keyword.get(opts, :workspace_id)
    }
  end

  @doc """
  `simulation.produced` — a new simulation report is current.
  """
  @spec simulation_produced(SimulationReport.t(), keyword()) :: attrs()
  def simulation_produced(%SimulationReport{} = report, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :runtime),
      event_type: "simulation.produced",
      subject_type: "simulation_report",
      subject_id: report.id,
      correlation_id: report.intent_id,
      before_ref: ref_from_supersedes(report.supersedes_id, "simulation_report"),
      after_ref: %{
        id: report.id,
        provider: report.provider,
        status: atom_or_nil(report.status)
      },
      workspace_id: Keyword.get(opts, :workspace_id)
    }
  end

  @doc """
  `simulation.requested` — an agent or operator asked the runtime
  for an on-demand simulation through `POST /v1/intents/:id/simulate`.

  Distinct from `simulation.produced` because the simulate endpoint
  can be called with reasons that do *not* mark the produced report
  as current (`pre_submit_dry_run`, `operator_inspection`). The
  event records the request, the resulting report id, and the
  reason — replay readers can see who asked, why, and whether the
  produced report became the active one.
  """
  @spec simulation_requested(SimulationReport.t(), String.t(), keyword()) :: attrs()
  def simulation_requested(%SimulationReport{} = report, reason, opts \\ [])
      when is_binary(reason) do
    %{
      actor: Keyword.get(opts, :actor, :agent),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "simulation.requested",
      subject_type: "simulation_report",
      subject_id: report.id,
      correlation_id: report.intent_id,
      after_ref: %{
        id: report.id,
        provider: report.provider,
        status: atom_or_nil(report.status),
        current: report.current,
        reason: reason
      },
      workspace_id: Keyword.get(opts, :workspace_id)
    }
  end

  @doc """
  `decision.decided` — a new decision envelope is current for an
  intent. If this envelope supersedes another (retry, approval
  successor), pass the prior envelope via `:supersedes` so the
  `before_ref` carries the prior outcome.

  Options:

    * `:workspace_id` — parent intent's workspace_id (#158d-b).
  """
  @spec decision_decided(DecisionEnvelope.t(), keyword()) :: attrs()
  def decision_decided(%DecisionEnvelope{} = envelope, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :runtime),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "decision.decided",
      subject_type: "decision_envelope",
      subject_id: envelope.id,
      correlation_id: envelope.intent_id,
      before_ref: ref_from_supersedes(envelope.supersedes_id, "decision_envelope"),
      after_ref: decision_snapshot(envelope),
      workspace_id: Keyword.get(opts, :workspace_id)
    }
  end

  @doc """
  `approval.granted` — operator approved an envelope. `successor` is
  the new `:auto_exec` envelope produced by the approval.
  """
  @spec approval_granted(DecisionEnvelope.t(), DecisionEnvelope.t(), keyword()) :: attrs()
  def approval_granted(
        %DecisionEnvelope{} = prior,
        %DecisionEnvelope{} = successor,
        opts \\ []
      ) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.fetch!(opts, :actor_id),
      event_type: "approval.granted",
      subject_type: "decision_envelope",
      subject_id: prior.id,
      correlation_id: prior.intent_id,
      before_ref: decision_snapshot(prior),
      after_ref: decision_snapshot(successor),
      workspace_id: Keyword.get(opts, :workspace_id)
    }
  end

  @doc """
  `approval.rejected` — operator rejected an envelope; `successor` is
  the block envelope.
  """
  @spec approval_rejected(DecisionEnvelope.t(), DecisionEnvelope.t(), keyword()) :: attrs()
  def approval_rejected(
        %DecisionEnvelope{} = prior,
        %DecisionEnvelope{} = successor,
        opts \\ []
      ) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.fetch!(opts, :actor_id),
      event_type: "approval.rejected",
      subject_type: "decision_envelope",
      subject_id: prior.id,
      correlation_id: prior.intent_id,
      before_ref: decision_snapshot(prior),
      after_ref: decision_snapshot(successor),
      workspace_id: Keyword.get(opts, :workspace_id)
    }
  end

  @doc """
  `morpho.risk_explained` — Morpho deposit decision pipeline (#203)
  produced a `Bank.DefiVenues.Morpho.RiskExplanation` for an intent.
  Fired on every Morpho decision (approval / hold / block alike) so
  the audit log carries the full structured evidence inline with the
  decision row, not just the envelope's `reasons` jsonb.

  `after_ref` carries:

    * `morpho_risk_explanation` — full explanation map produced by
      `Bank.DefiVenues.Morpho.RiskExplanation.explain/3` (the
      vocabulary is fixed and already-redacted per #201);
    * `snapshot` — small reference to the persisted vault snapshot
      (`id`, `chain_id`, `vault_address`, `payload_hash`,
      `fetched_at`, source name + schema version) — never the raw
      GraphQL body or any provider secret;
    * `policy_rule_ids` — the workspace's matched Morpho rule ids,
      mirroring the envelope's `policy_snapshot_ref.rule_ids`;
    * `proposed_amount` — the deposit amount the agent requested,
      in the asset's canonical decimal string form.

  The constructor accepts a `nil` snapshot — the missing-snapshot
  `:hold` path still emits the event so replay can reconstruct what
  the engine actually saw.
  """
  @spec morpho_risk_explained(
          AgentIntent.t(),
          PersistedVaultSnapshot.t() | VaultSnapshot.t() | nil,
          map(),
          [String.t()],
          keyword()
        ) :: attrs()
  def morpho_risk_explained(
        %AgentIntent{} = intent,
        snapshot,
        explanation,
        rule_ids,
        opts \\ []
      )
      when is_map(explanation) and is_list(rule_ids) do
    %{
      actor: Keyword.get(opts, :actor, :runtime),
      event_type: "morpho.risk_explained",
      subject_type: "agent_intent",
      subject_id: intent.id,
      correlation_id: intent.id,
      after_ref: %{
        morpho_risk_explanation: explanation,
        snapshot: morpho_snapshot_ref(snapshot),
        policy_rule_ids: rule_ids,
        proposed_amount: decimal_to_string(intent.amount)
      },
      workspace_id: intent.workspace_id
    }
  end

  @doc """
  `morpho.policy_blocked` — Morpho deposit decision pipeline routed
  the intent to `:block`. Subset of `morpho.risk_explained` pinned
  to the block path so auditors can filter blocked Morpho actions
  by `event_type` without reading every explanation.

  `after_ref` carries the vault identity, the block-severity reason
  codes from the explanation's `primary_reasons`, the explanation
  summary, and the matched policy rule ids. Full explanation lives
  in the sibling `morpho.risk_explained` event for the same intent.
  """
  @spec morpho_policy_blocked(AgentIntent.t(), map(), [String.t()], keyword()) :: attrs()
  def morpho_policy_blocked(%AgentIntent{} = intent, explanation, rule_ids, opts \\ [])
      when is_map(explanation) and is_list(rule_ids) do
    block_codes =
      explanation
      |> Map.get("primary_reasons", [])
      |> Enum.filter(&(Map.get(&1, "severity") == "block"))
      |> Enum.map(&Map.get(&1, "code"))
      |> Enum.reject(&is_nil/1)

    %{
      actor: Keyword.get(opts, :actor, :runtime),
      event_type: "morpho.policy_blocked",
      subject_type: "agent_intent",
      subject_id: intent.id,
      correlation_id: intent.id,
      after_ref: %{
        vault_address: Map.get(explanation, "vault_address"),
        chain_id: Map.get(explanation, "chain_id"),
        block_reason_codes: block_codes,
        summary: Map.get(explanation, "summary"),
        policy_rule_ids: rule_ids
      },
      workspace_id: intent.workspace_id
    }
  end

  @doc """
  `morpho.snapshot_stale` — Morpho deposit decision pipeline saw a
  persisted vault snapshot whose freshness summary contains at
  least one `:stale` or `:expired` field. Fired alongside
  `morpho.risk_explained` whenever the underlying snapshot was not
  fully fresh, so operators can correlate stale-data warnings to
  the decisions they shaped.

  Subject is the `morpho_vault_snapshots` row id; `correlation_id`
  is the intent id so the replay bundle groups the event with the
  decision it influenced. `after_ref` lists every non-fresh field
  with its observed state (`stale` or `expired`).
  """
  @spec morpho_snapshot_stale(
          AgentIntent.t(),
          PersistedVaultSnapshot.t(),
          %{atom() => atom()},
          keyword()
        ) :: attrs()
  def morpho_snapshot_stale(
        %AgentIntent{} = intent,
        %PersistedVaultSnapshot{} = snapshot,
        freshness,
        opts \\ []
      )
      when is_map(freshness) do
    stale_fields =
      freshness
      |> Enum.filter(fn {_field, state} -> state in [:stale, :expired] end)
      |> Enum.map(fn {field, state} ->
        %{field: Atom.to_string(field), state: Atom.to_string(state)}
      end)
      |> Enum.sort_by(& &1.field)

    %{
      actor: Keyword.get(opts, :actor, :runtime),
      event_type: "morpho.snapshot_stale",
      subject_type: "morpho_vault_snapshot",
      subject_id: snapshot.id,
      correlation_id: intent.id,
      after_ref: %{
        vault_address: snapshot.vault_address,
        chain_id: snapshot.chain_id,
        fetched_at: DateTime.to_iso8601(snapshot.fetched_at),
        stale_fields: stale_fields
      },
      workspace_id: intent.workspace_id
    }
  end

  @doc """
  `morpho.deposit_dispatched` — Phoenix handed an approved Morpho
  deposit plan to the adapter for ERC-4626 broadcast (#206). Fires
  alongside the standard `execution.signing` transition; consumers
  filter on the `morpho.*` prefix to assemble the Morpho-specific
  replay narrative.

  Subject is the execution plan. Carries vault address, snapshot
  identity, asset/amount, receiver smart account, and the policy
  rule ids the operator approved against. Excludes calldata —
  that's adapter-built and not load-bearing for replay attribution.
  """
  @spec morpho_deposit_dispatched(ExecutionPlan.t(), Decimal.t(), keyword()) :: attrs()
  def morpho_deposit_dispatched(%ExecutionPlan{} = plan, %Decimal{} = amount, opts \\ []) do
    steps = plan.steps || %{}

    %{
      actor: Keyword.get(opts, :actor, :runtime),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "morpho.deposit_dispatched",
      subject_type: "execution_plan",
      subject_id: plan.id,
      correlation_id: plan.intent_id,
      after_ref: %{
        vault_address: Map.get(steps, "vault_address"),
        chain_id: Map.get(steps, "chain_id"),
        asset: plan.asset,
        amount: Decimal.to_string(amount, :normal),
        receiver: Map.get(steps, "receiver"),
        snapshot_id: Map.get(steps, "snapshot_id"),
        snapshot_payload_hash: Map.get(steps, "snapshot_payload_hash"),
        policy_rule_ids: Map.get(steps, "policy_rule_ids", []),
        decision_id: plan.decision_id
      },
      workspace_id: plan.workspace_id
    }
  end

  @doc """
  `morpho.deposit_aborted` — pre-dispatch Morpho safety gate
  (`Bank.Decisions.MorphoDispatchSafety`) refused, or the worker
  aborted the plan post-claim before any adapter call (#206).

  Subject is the execution plan. `after_ref.reason` is the gate's
  failure atom (`:morpho_chain_not_supported`,
  `:morpho_asset_not_supported`, `:morpho_vault_not_allowlisted`,
  `:morpho_snapshot_missing`, `:morpho_snapshot_expired`,
  `:morpho_snapshot_drifted`, `:morpho_steps_missing`).
  """
  @spec morpho_deposit_aborted(ExecutionPlan.t(), atom() | String.t(), keyword()) :: attrs()
  def morpho_deposit_aborted(%ExecutionPlan{} = plan, reason, opts \\ []) do
    steps = plan.steps || %{}

    %{
      actor: Keyword.get(opts, :actor, :runtime),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "morpho.deposit_aborted",
      subject_type: "execution_plan",
      subject_id: plan.id,
      correlation_id: plan.intent_id,
      after_ref: %{
        vault_address: Map.get(steps, "vault_address"),
        chain_id: Map.get(steps, "chain_id"),
        snapshot_id: Map.get(steps, "snapshot_id"),
        reason: reason_to_string(reason),
        decision_id: plan.decision_id
      },
      workspace_id: plan.workspace_id
    }
  end

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason), do: reason

  @doc """
  `morpho.withdraw_previewed` — operator inspected the vault's
  withdraw preview without yet committing to a request (#207).

  Subject is the vault snapshot the preview was computed against
  (so audit consumers grouping by snapshot see the operator's
  inspection alongside the agent's deposit attribution). Carries
  a `correlation_id` the caller threads across the
  `morpho.withdraw_*` chain so replay can rebuild the
  operator-action narrative independently of any intent.

  Withdraw is operator-only and never agent-initiated; the
  `actor` is hardcoded `:user` (operator).
  """
  @spec morpho_withdraw_previewed(String.t() | nil, map(), keyword()) :: attrs()
  def morpho_withdraw_previewed(workspace_id, preview, opts \\ []) do
    %{
      actor: :user,
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "morpho.withdraw_previewed",
      subject_type: "morpho_vault_snapshot",
      subject_id: Map.get(preview, :snapshot_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      after_ref: %{
        vault_address: Map.get(preview, :vault_address),
        chain_id: Map.get(preview, :chain_id),
        requested_assets: decimal_to_string(Map.get(preview, :requested_assets)),
        max_withdrawable: decimal_to_string(Map.get(preview, :max_withdrawable)),
        would_block: Map.get(preview, :would_block?),
        would_partial: Map.get(preview, :would_partial?),
        snapshot_payload_hash: Map.get(preview, :snapshot_payload_hash),
        snapshot_fetched_at: Map.get(preview, :snapshot_fetched_at)
      },
      workspace_id: workspace_id
    }
  end

  @doc """
  `morpho.withdraw_blocked` — operator-initiated withdraw refused
  by the safety gate (#207). Reason is one of the operator
  failure atoms (`:morpho_withdraw_blocked` for insufficient
  liquidity, `:morpho_withdraw_partial_required` for partial
  without explicit consent).

  Subject is the synthetic correlation_id (no vault snapshot
  context if the gate refused before snapshot lookup); audit
  consumers find the chain via `correlation_id`.
  """
  @spec morpho_withdraw_blocked(
          String.t() | nil,
          String.t() | nil,
          atom() | String.t(),
          keyword()
        ) :: attrs()
  def morpho_withdraw_blocked(workspace_id, vault_address, reason, opts \\ []) do
    correlation_id = Keyword.get(opts, :correlation_id)

    %{
      actor: :user,
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "morpho.withdraw_blocked",
      subject_type: "morpho_withdraw_request",
      subject_id: correlation_id,
      correlation_id: correlation_id,
      after_ref: %{
        vault_address: vault_address,
        reason: reason_to_string(reason)
      },
      workspace_id: workspace_id
    }
  end

  @doc """
  `morpho.withdraw_planned` — operator-initiated withdraw
  accepted by the safety gate; the request is recorded in the
  audit log and is ready for the (future) adapter dispatch
  slice to broadcast the ERC-4626 `withdraw(assets, receiver,
  owner)` UserOperation (#207 follow-up).

  `effective_assets` is the amount that will actually be
  requested at dispatch — equal to `requested_assets` for a
  full withdraw, or clamped to `max_withdrawable` when the
  operator explicitly accepted a partial flow.
  """
  @spec morpho_withdraw_planned(String.t() | nil, map(), Decimal.t(), boolean(), keyword()) ::
          attrs()
  def morpho_withdraw_planned(workspace_id, preview, effective_assets, partial?, opts \\ []) do
    correlation_id = Keyword.get(opts, :correlation_id)

    %{
      actor: :user,
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "morpho.withdraw_planned",
      subject_type: "morpho_withdraw_request",
      subject_id: correlation_id,
      correlation_id: correlation_id,
      after_ref: %{
        vault_address: Map.get(preview, :vault_address),
        chain_id: Map.get(preview, :chain_id),
        requested_assets: decimal_to_string(Map.get(preview, :requested_assets)),
        effective_assets: decimal_to_string(effective_assets),
        max_withdrawable: decimal_to_string(Map.get(preview, :max_withdrawable)),
        partial: partial?,
        snapshot_id: Map.get(preview, :snapshot_id),
        snapshot_payload_hash: Map.get(preview, :snapshot_payload_hash)
      },
      workspace_id: workspace_id
    }
  end

  @doc """
  `execution.<status>` — execution-plan status transition. The status
  is derived from the plan's `execution_status` so the caller only
  hands in the plan.
  """
  @spec execution_transition(ExecutionPlan.t(), atom(), keyword()) :: attrs()
  def execution_transition(%ExecutionPlan{} = plan, prior_status, opts \\ [])
      when is_atom(prior_status) or is_nil(prior_status) do
    after_ref =
      %{
        id: plan.id,
        execution_status: atom_or_nil(plan.execution_status),
        final_outcome: atom_or_nil(plan.final_outcome),
        final_reason: plan.final_reason,
        tx_refs: plan.tx_refs || []
      }
      |> Map.merge(swap_receipt_fields(plan))

    %{
      actor: Keyword.get(opts, :actor, :adapter),
      event_type: "execution.#{plan.execution_status}",
      subject_type: "execution_plan",
      subject_id: plan.id,
      correlation_id: plan.intent_id,
      before_ref: maybe_status_ref(prior_status),
      after_ref: after_ref,
      workspace_id: plan.workspace_id
    }
  end

  # Surface the swap-receipt fields on the audit `after_ref` for
  # swap plans only (#193 / #194). Transfer plans never populate
  # them, so the legacy transfer-audit shape stays unchanged.
  #
  # The route inputs (`:route_hash`, `:route_provider`, source /
  # destination asset, slippage and deadline) are read directly
  # off `plan.steps` (set by #190 at plan creation, immutable
  # thereafter) so replay never has to rejoin against the plan to
  # learn which route was dispatched. `:expected_output_amount`
  # comes off the same persisted route and is paired with
  # `:actual_output_amount` (filled in by the callback path —
  # #193 receipt persistence) so a single audit row tells the
  # "asked for X, got Y" story without joining to the plan or
  # downstream events.
  #
  # `:calldata`, `:spender`, `:swap_target_contract`, and other
  # raw-call inputs are deliberately NOT surfaced here — they
  # round-trip through `plan.steps` for dispatch but never need
  # to appear on every audit row, and keeping them off the
  # `after_ref` keeps secret-hygiene assertions simple.
  defp swap_receipt_fields(%ExecutionPlan{steps: %{"kind" => "swap"} = steps} = plan) do
    %{
      route_hash: Map.get(steps, "route_hash"),
      route_provider: Map.get(steps, "route_provider"),
      source_asset: Map.get(steps, "source_asset"),
      destination_asset: Map.get(steps, "destination_asset"),
      expected_output_amount: Map.get(steps, "expected_output_amount"),
      minimum_output_amount: Map.get(steps, "minimum_output_amount"),
      slippage_bps: Map.get(steps, "slippage_bps"),
      deadline: Map.get(steps, "deadline"),
      block_number: plan.block_number,
      actual_output_amount: decimal_string(plan.actual_output_amount)
    }
  end

  defp swap_receipt_fields(_plan), do: %{}

  defp decimal_string(nil), do: nil
  defp decimal_string(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)
  defp decimal_string(other), do: other

  @doc """
  `execution.dispatch_aborted_paused` — `RunExecution`'s pre-adapter
  re-check (audit C3) caught a pause that was activated *after* the
  pre-claim gate already cleared the plan and the worker had moved
  it `:prepared → :signing`. The dispatch was aborted before the
  adapter HTTP request left the BEAM and the plan was reverted to
  `:prepared` so a retry after the operator resumes can re-claim.

  The `after_ref` carries:
    * `prior_status` — the plan's `execution_status` at the moment
      of abort (always `:signing` in the production path).
    * `scope` — the active pause that tripped the gate. `kind` is
      `"global"` or `"chain"`; for chain scope, `value` is the chain
      and `workspace_id` is the workspace.
  """
  @spec execution_dispatch_aborted_paused(ExecutionPlan.t(), atom(), map(), keyword()) :: attrs()
  def execution_dispatch_aborted_paused(%ExecutionPlan{} = plan, prior_status, scope, opts \\ [])
      when is_atom(prior_status) and is_map(scope) do
    %{
      actor: Keyword.get(opts, :actor, :runtime),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "execution.dispatch_aborted_paused",
      subject_type: "execution_plan",
      subject_id: plan.id,
      correlation_id: plan.intent_id,
      after_ref: %{
        plan_id: plan.id,
        prior_status: atom_or_nil(prior_status),
        scope: stringify_scope(scope)
      },
      workspace_id: plan.workspace_id
    }
  end

  defp stringify_scope(scope) when is_map(scope) do
    Map.new(scope, fn
      {k, v} when is_atom(v) -> {to_string(k), Atom.to_string(v)}
      {k, v} -> {to_string(k), v}
    end)
  end

  @doc """
  `ops.stuck_plan_detected` — periodic detector flagged an
  execution plan as stuck past its per-status threshold (#230-b).

  Subject is the plan; `correlation_id` is the parent intent so
  audit replay can group with the plan's other lifecycle rows.
  `after_ref` carries:

    * `execution_status` — current non-terminal status (atom)
    * `stuck_for_seconds` — observed staleness at detection time
    * `threshold_seconds` — the per-status threshold that tripped
    * `window_start` — ISO 8601 detection-window start; the
      idempotency key the worker uses to skip an already-emitted
      plan within the same window
  """
  @spec ops_stuck_plan_detected(map(), keyword()) :: attrs()
  def ops_stuck_plan_detected(%{} = detail, opts \\ []) do
    window_start = Keyword.get(opts, :window_start, DateTime.utc_now())

    %{
      actor: :runtime,
      actor_id: nil,
      event_type: "ops.stuck_plan_detected",
      subject_type: "execution_plan",
      subject_id: detail.id,
      correlation_id: Map.get(detail, :intent_id),
      after_ref: %{
        execution_status: Atom.to_string(detail.execution_status),
        stuck_for_seconds: detail.stuck_for_seconds,
        threshold_seconds: detail.threshold_seconds,
        window_start: DateTime.to_iso8601(window_start)
      },
      workspace_id: Map.get(detail, :workspace_id)
    }
  end

  @doc """
  `counterparty.created` — operator created a new counterparty.
  Correlation is the counterparty id itself, matching the audit
  docstring's convention for counterparty-scoped events.
  """
  @spec counterparty_created(Counterparty.t(), keyword()) :: attrs()
  def counterparty_created(%Counterparty{} = cp, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "counterparty.created",
      subject_type: "counterparty",
      subject_id: cp.id,
      correlation_id: cp.id,
      after_ref: counterparty_snapshot(cp)
    }
  end

  @doc """
  `counterparty.updated` — operator edited a counterparty. The
  `before` / `after` snapshots carry the fields that actually changed
  so replay can diff without re-loading the row.
  """
  @spec counterparty_updated(Counterparty.t(), Counterparty.t(), keyword()) :: attrs()
  def counterparty_updated(%Counterparty{} = prior, %Counterparty{} = current, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "counterparty.updated",
      subject_type: "counterparty",
      subject_id: current.id,
      correlation_id: current.id,
      before_ref: counterparty_snapshot(prior),
      after_ref: counterparty_snapshot(current)
    }
  end

  @doc """
  `counterparty.archived` — soft-archival. Emitted when `active` flips
  from `true` to `false`; historical references stay intact.
  """
  @spec counterparty_archived(Counterparty.t(), keyword()) :: attrs()
  def counterparty_archived(%Counterparty{} = cp, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "counterparty.archived",
      subject_type: "counterparty",
      subject_id: cp.id,
      correlation_id: cp.id,
      before_ref: %{active: true},
      after_ref: %{active: false}
    }
  end

  @doc """
  `address_label.attached` — an `(chain, address)` label was attached
  to a counterparty. Correlation is the owning counterparty id, so a
  single counterparty-scoped audit read surfaces the full address
  book history.
  """
  @spec address_label_attached(AddressLabel.t(), keyword()) :: attrs()
  def address_label_attached(%AddressLabel{} = label, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "address_label.attached",
      subject_type: "address_label",
      subject_id: label.id,
      correlation_id: label.counterparty_id,
      after_ref: address_label_snapshot(label)
    }
  end

  @doc """
  `address_label.updated` — operator edited an address label's
  metadata (`alias`, `role`, `verified`). The address itself is
  immutable — mistakes get retired and replaced.
  """
  @spec address_label_updated(AddressLabel.t(), AddressLabel.t(), keyword()) :: attrs()
  def address_label_updated(%AddressLabel{} = prior, %AddressLabel{} = current, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "address_label.updated",
      subject_type: "address_label",
      subject_id: current.id,
      correlation_id: current.counterparty_id,
      before_ref: address_label_snapshot(prior),
      after_ref: address_label_snapshot(current)
    }
  end

  @doc """
  `address_label.retired` — stamps `retired_at`; the label can no
  longer satisfy a future intent but historical references remain.
  """
  @spec address_label_retired(AddressLabel.t(), keyword()) :: attrs()
  def address_label_retired(%AddressLabel{} = label, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "address_label.retired",
      subject_type: "address_label",
      subject_id: label.id,
      correlation_id: label.counterparty_id,
      before_ref: %{retired_at: nil},
      after_ref: %{retired_at: label.retired_at}
    }
  end

  @doc """
  `evidence.attached` — append-only. Correlation is the owning
  counterparty id (for counterparty-subject evidence, `subject_id`
  itself; for label-subject evidence, the label's
  `counterparty_id`, passed via `:counterparty_id` in `opts`).
  """
  @spec evidence_attached(EvidenceArtifact.t(), keyword()) :: attrs()
  def evidence_attached(%EvidenceArtifact{} = artifact, opts \\ []) do
    correlation_id =
      case artifact.subject_type do
        "counterparty" -> artifact.subject_id
        "address_label" -> Keyword.fetch!(opts, :counterparty_id)
      end

    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "evidence.attached",
      subject_type: artifact.subject_type,
      subject_id: artifact.subject_id,
      correlation_id: correlation_id,
      before_ref: ref_from_supersedes(artifact.supersedes_id, "evidence_artifact"),
      after_ref: evidence_snapshot(artifact)
    }
  end

  @doc """
  `trust_assertion.issued` — a new assertion is the current one for
  its subject + scope. Correlation is the owning counterparty id so
  all trust history for a counterparty (including assertions attached
  to its labels) is one filter away.

  When this assertion supersedes a prior one, pass it via
  `:supersedes` so `before_ref` carries the prior level and scope.
  """
  @spec trust_assertion_issued(TrustAssertion.t(), keyword()) :: attrs()
  def trust_assertion_issued(%TrustAssertion{} = assertion, opts \\ []) do
    correlation_id =
      case assertion.subject_type do
        "counterparty" -> assertion.subject_id
        "address_label" -> Keyword.fetch!(opts, :counterparty_id)
      end

    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "trust_assertion.issued",
      subject_type: assertion.subject_type,
      subject_id: assertion.subject_id,
      correlation_id: correlation_id,
      before_ref: trust_assertion_before_ref(opts[:supersedes]),
      after_ref: trust_assertion_snapshot(assertion)
    }
  end

  @doc """
  `policy.created` — operator authored a new policy rule. Correlation
  is the rule's own id, matching the audit docstring's convention
  for policy-admin events.
  """
  @spec policy_created(PolicyRule.t(), keyword()) :: attrs()
  def policy_created(%PolicyRule{} = rule, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "policy.created",
      subject_type: "policy_rule",
      subject_id: rule.id,
      correlation_id: rule.id,
      after_ref: policy_rule_snapshot(rule)
    }
  end

  @doc """
  `policy.revised` — operator edited a policy rule; a new version
  supersedes the prior one. Correlation is the new rule's id.
  """
  @spec policy_revised(PolicyRule.t(), PolicyRule.t(), keyword()) :: attrs()
  def policy_revised(%PolicyRule{} = prior, %PolicyRule{} = successor, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.fetch!(opts, :actor_id),
      event_type: "policy.revised",
      subject_type: "policy_rule",
      subject_id: successor.id,
      correlation_id: successor.id,
      before_ref: policy_rule_snapshot(prior),
      after_ref: policy_rule_snapshot(successor)
    }
  end

  @doc """
  `policy.archived` — operator retired an active rule. The prior
  state is always `:active` (the context guards non-active archival),
  so `before_ref` captures that explicitly.
  """
  @spec policy_archived(PolicyRule.t(), keyword()) :: attrs()
  def policy_archived(%PolicyRule{} = rule, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.fetch!(opts, :actor_id),
      event_type: "policy.archived",
      subject_type: "policy_rule",
      subject_id: rule.id,
      correlation_id: rule.id,
      before_ref: %{id: rule.id, state: "active", version: rule.version},
      after_ref: policy_rule_snapshot(rule)
    }
  end

  @doc """
  `policy.version.draft_created` — operator opened a new draft
  policy version (#223). The draft is editable and does not
  affect runtime; runtime continues to read the prior published
  version (or the active rule set, until #226 wires the runtime
  to consult `PolicyVersion`). `supersedes_id` points at the
  prior published version, or nil for the very first draft in a
  workspace.
  """
  @spec policy_version_draft_created(Bank.Policies.PolicyVersion.t(), keyword()) :: attrs()
  def policy_version_draft_created(%{__struct__: _} = version, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.fetch!(opts, :actor_id),
      event_type: "policy.version.draft_created",
      subject_type: "policy_version",
      subject_id: version.id,
      correlation_id: version.id,
      after_ref: policy_version_snapshot(version),
      workspace_id: version.workspace_id
    }
  end

  @doc """
  `policy.version.published` — a draft policy version was
  promoted to `:published` (#223). The prior `:published` row
  (if any) was atomically marked `:superseded` in the same
  transaction. `before_ref` captures the prior published id +
  version_number; `after_ref` captures the new published row.
  Future decisions can now pin against this version.
  """
  @spec policy_version_published(
          Bank.Policies.PolicyVersion.t(),
          Bank.Policies.PolicyVersion.t() | nil,
          keyword()
        ) :: attrs()
  def policy_version_published(%{__struct__: _} = published, prior, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.fetch!(opts, :actor_id),
      event_type: "policy.version.published",
      subject_type: "policy_version",
      subject_id: published.id,
      correlation_id: published.id,
      before_ref: policy_version_prior_ref(prior),
      after_ref: policy_version_snapshot(published),
      workspace_id: published.workspace_id
    }
  end

  @doc """
  `policy.version.rolled_back` — operator re-published a prior
  `:superseded` version, atomically marking the current
  `:published` version `:superseded` in the same transaction
  (#223). `before_ref` captures the row that was rolled out;
  `after_ref` captures the row that's now published again.
  """
  @spec policy_version_rolled_back(
          Bank.Policies.PolicyVersion.t(),
          Bank.Policies.PolicyVersion.t() | nil,
          keyword()
        ) :: attrs()
  def policy_version_rolled_back(%{__struct__: _} = restored, rolled_out, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.fetch!(opts, :actor_id),
      event_type: "policy.version.rolled_back",
      subject_type: "policy_version",
      subject_id: restored.id,
      correlation_id: restored.id,
      before_ref: policy_version_prior_ref(rolled_out),
      after_ref: policy_version_snapshot(restored),
      workspace_id: restored.workspace_id
    }
  end

  defp policy_version_prior_ref(nil), do: nil

  defp policy_version_prior_ref(%{__struct__: _} = version) do
    %{
      id: version.id,
      version_number: version.version_number,
      status: atom_or_nil(version.status)
    }
  end

  defp policy_version_snapshot(%{__struct__: _} = version) do
    items =
      case version.rule_ids do
        %{"items" => items} when is_list(items) -> items
        _ -> []
      end

    %{
      id: version.id,
      workspace_id: version.workspace_id,
      version_number: version.version_number,
      status: atom_or_nil(version.status),
      rule_id_count: length(items),
      rule_ids: items,
      supersedes_id: version.supersedes_id,
      created_by: atom_or_nil(version.created_by),
      published_by: atom_or_nil(version.published_by),
      published_at: maybe_dt_iso(version.published_at),
      effective_at: maybe_dt_iso(version.effective_at)
    }
  end

  defp maybe_dt_iso(nil), do: nil
  defp maybe_dt_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp maybe_dt_iso(other), do: other

  @doc """
  `delegation.state_changed` — the delegation projection transitioned
  to a new state (granted, revoking, revoke_failed, revoked, expired).
  Correlation is nil (runtime-scoped, same as security events).
  """
  @spec delegation_state_changed(Delegation.t(), atom() | nil, keyword()) :: attrs()
  def delegation_state_changed(%Delegation{} = delegation, prior_state, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :adapter),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "delegation.state_changed",
      subject_type: "delegation",
      subject_id: delegation.id,
      correlation_id: nil,
      before_ref: maybe_delegation_state_ref(prior_state),
      after_ref: delegation_snapshot(delegation),
      workspace_id: delegation.workspace_id
    }
  end

  # ---------------------------------------------------------------------------
  # Browser-signed install lifecycle (#474)
  # ---------------------------------------------------------------------------

  # Subject for the first three events is `wallet_binding` (the
  # delegation row does not exist yet at envelope-issued time and
  # is still `:pending` at submitted/broadcast time). The last two
  # events fire after the row exists, so they target `delegation`.
  # Correlation is the binding_id throughout so the full install
  # lineage threads under one filter (mirrors the design § 8
  # rule).

  @doc """
  `delegation.install_envelope_issued` — Phoenix returned the
  canonical install envelope to the browser for the given binding.
  Carries the binding id, the smart-account id Phoenix will
  reconcile against, the chain id, and the SHA-256 hash of the
  canonical scope JSON the browser is about to relay to the
  ZeroDev SDK.
  """
  @spec delegation_install_envelope_issued(map(), keyword()) :: attrs()
  def delegation_install_envelope_issued(%{} = envelope, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "delegation.install_envelope_issued",
      subject_type: "wallet_binding",
      subject_id: Map.fetch!(envelope, :binding_id),
      correlation_id: Map.fetch!(envelope, :binding_id),
      before_ref: nil,
      after_ref: %{
        binding_id: Map.fetch!(envelope, :binding_id),
        smart_account_id: Map.fetch!(envelope, :smart_account_id),
        chain_id: Map.fetch!(envelope, :chain_id),
        scope_hash: Map.fetch!(envelope, :scope_hash)
      },
      workspace_id: Map.fetch!(envelope, :workspace_id)
    }
  end

  @doc """
  `delegation.install_signed_by_user` — the browser reported the
  bundler accepted the install UserOp; the userop_hash is now the
  binding-scoped install attempt id. Phoenix has persisted a
  `:pending` delegation row keyed by `(binding_id,
  install_userop_hash)`.
  """
  @spec delegation_install_signed_by_user(Delegation.t(), keyword()) :: attrs()
  def delegation_install_signed_by_user(%Delegation{} = delegation, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "delegation.install_signed_by_user",
      subject_type: "wallet_binding",
      subject_id: delegation.binding_id,
      correlation_id: delegation.binding_id,
      before_ref: nil,
      after_ref: %{
        binding_id: delegation.binding_id,
        delegation_id: delegation.id,
        smart_account_id: delegation.smart_account_id,
        install_userop_hash: delegation.install_userop_hash
      },
      workspace_id: delegation.workspace_id
    }
  end

  @doc """
  `delegation.install_broadcast` — the bundler returned a receipt
  marking the install UserOp on chain. Carries the on-chain tx
  hash and block number; the on-chain *verification* fires next
  via `Bank.Runtime.Workers.VerifyInstallOnchain`.
  """
  @spec delegation_install_broadcast(Delegation.t(), map(), keyword()) :: attrs()
  def delegation_install_broadcast(%Delegation{} = delegation, %{} = receipt, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "delegation.install_broadcast",
      subject_type: "wallet_binding",
      subject_id: delegation.binding_id,
      correlation_id: delegation.binding_id,
      before_ref: nil,
      after_ref: %{
        binding_id: delegation.binding_id,
        delegation_id: delegation.id,
        smart_account_id: delegation.smart_account_id,
        install_userop_hash: delegation.install_userop_hash,
        tx_hash: Map.get(receipt, :tx_hash),
        block_number: Map.get(receipt, :block_number)
      },
      workspace_id: delegation.workspace_id
    }
  end

  @doc """
  `delegation.install_confirmed_onchain` — Phoenix verified the
  permission validator is installed on the user's smart account
  with the expected `validation_id`. The delegation row flips to
  `:active`.
  """
  @spec delegation_install_confirmed_onchain(Delegation.t(), keyword()) :: attrs()
  def delegation_install_confirmed_onchain(%Delegation{} = delegation, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :runtime),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "delegation.install_confirmed_onchain",
      subject_type: "delegation",
      subject_id: delegation.id,
      correlation_id: delegation.binding_id,
      before_ref: nil,
      after_ref: %{
        binding_id: delegation.binding_id,
        delegation_id: delegation.id,
        smart_account_id: delegation.smart_account_id,
        permission_id: maybe_hex(delegation.permission_id),
        validation_id: maybe_hex(delegation.validation_id),
        installed_at_block: delegation.installed_at_block
      },
      workspace_id: delegation.workspace_id
    }
  end

  @doc """
  `delegation.install_failed` — any failure in the browser-signed
  install flow. `reason` is one of the fixed-allowlist atoms named
  in `Bank.SessionPermissions.BrowserInstall.failure_categories/0`.
  Free-form upstream error strings never reach this audit row.
  """
  @spec delegation_install_failed(map(), keyword()) :: attrs()
  def delegation_install_failed(%{} = ctx, opts \\ []) do
    binding_id = Map.fetch!(ctx, :binding_id)

    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "delegation.install_failed",
      subject_type: Map.get(ctx, :subject_type, "wallet_binding"),
      subject_id: Map.get(ctx, :subject_id, binding_id),
      correlation_id: binding_id,
      before_ref: nil,
      after_ref: %{
        binding_id: binding_id,
        delegation_id: Map.get(ctx, :delegation_id),
        smart_account_id: Map.get(ctx, :smart_account_id),
        reason: Map.fetch!(ctx, :reason),
        install_userop_hash: Map.get(ctx, :install_userop_hash)
      },
      workspace_id: Map.fetch!(ctx, :workspace_id)
    }
  end

  defp maybe_hex(nil), do: nil
  defp maybe_hex(bin) when is_binary(bin), do: "0x" <> Base.encode16(bin, case: :lower)

  @doc """
  `execution.manually_requested` — an operator triggered manual
  execution for a decision envelope.

  When the plan is a swap dispatch, callers pass
  `route_metadata: %{route_hash: ..., route_provider: ...}` and the
  pair is merged into `after_ref` so replay can verify which route
  the plan was built from without rehydrating the full route.
  """
  @spec execution_manually_requested(ExecutionPlan.t(), keyword()) :: attrs()
  def execution_manually_requested(%ExecutionPlan{} = plan, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "execution.manually_requested",
      subject_type: "execution_plan",
      subject_id: plan.id,
      correlation_id: plan.intent_id,
      after_ref: execution_dispatch_after_ref(plan, opts),
      workspace_id: plan.workspace_id
    }
  end

  @doc """
  `execution.auto_dispatched` — the runtime materialised an
  `ExecutionPlan` for a fresh `:auto_exec` `DecisionEnvelope`
  without operator intervention.

  Distinct from `execution.manually_requested` so audit consumers
  can distinguish operator-triggered execution from runtime-driven
  auto-exec dispatch. Swap-dispatch metadata is surfaced the same
  way (`route_metadata` opt → merged into `after_ref`).
  """
  @spec execution_auto_dispatched(ExecutionPlan.t(), keyword()) :: attrs()
  def execution_auto_dispatched(%ExecutionPlan{} = plan, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :runtime),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "execution.auto_dispatched",
      subject_type: "execution_plan",
      subject_id: plan.id,
      correlation_id: plan.intent_id,
      after_ref: execution_dispatch_after_ref(plan, opts),
      workspace_id: plan.workspace_id
    }
  end

  defp execution_dispatch_after_ref(%ExecutionPlan{} = plan, opts) do
    base = %{
      id: plan.id,
      decision_id: plan.decision_id,
      execution_status: atom_or_nil(plan.execution_status),
      smart_account_id: plan.smart_account_id
    }

    base
    |> maybe_merge_route_metadata(Keyword.get(opts, :route_metadata))
    |> maybe_merge_morpho_metadata(Keyword.get(opts, :morpho_metadata))
  end

  defp maybe_merge_route_metadata(after_ref, %{route_hash: hash, route_provider: provider}),
    do: Map.merge(after_ref, %{route_hash: hash, route_provider: provider})

  defp maybe_merge_route_metadata(after_ref, _), do: after_ref

  defp maybe_merge_morpho_metadata(
         after_ref,
         %{morpho_vault_address: vault, morpho_snapshot_id: snap_id} = meta
       )
       when is_binary(vault) do
    Map.merge(after_ref, %{
      morpho_vault_address: vault,
      morpho_snapshot_id: snap_id,
      morpho_snapshot_payload_hash: Map.get(meta, :morpho_snapshot_payload_hash)
    })
  end

  defp maybe_merge_morpho_metadata(after_ref, _), do: after_ref

  @doc """
  `intent.auto_exec_held` — an `:auto_exec` decision was reached but
  dispatch was withheld because a safety gate failed (no executable
  smart account, ambiguous account, runtime paused, an active plan
  is already in flight, etc.).

  The decision envelope itself is still current and the intent
  remains in `:decided`; the operator can either resolve the gate
  and re-evaluate or call the manual execution path explicitly.
  """
  @spec intent_auto_exec_held(
          AgentIntent.t(),
          DecisionEnvelope.t(),
          atom() | String.t(),
          keyword()
        ) ::
          attrs()
  def intent_auto_exec_held(
        %AgentIntent{} = intent,
        %DecisionEnvelope{} = envelope,
        reason,
        opts \\ []
      ) do
    %{
      actor: Keyword.get(opts, :actor, :runtime),
      actor_id: Keyword.get(opts, :actor_id),
      event_type: "intent.auto_exec_held",
      subject_type: "agent_intent",
      subject_id: intent.id,
      correlation_id: intent.id,
      after_ref: %{
        decision_envelope_id: envelope.id,
        held_reason: atom_or_nil(reason)
      },
      workspace_id: intent.workspace_id
    }
  end

  # --- Access / auth events (issue #161) -------------------------------

  @doc """
  `auth.login_succeeded` — an OAuth callback completed and a session
  was started for the user.

  Correlation is the user id so the per-user trace (login → invite
  match → admin approve → membership) is one filter away.
  """
  @spec auth_login_succeeded(User.t(), keyword()) :: attrs()
  def auth_login_succeeded(%User{} = user, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: user.id,
      event_type: "auth.login_succeeded",
      subject_type: "user",
      subject_id: user.id,
      correlation_id: user.id,
      after_ref: %{
        email: user.email,
        provider: atom_or_nil(user.provider),
        status: atom_or_nil(user.status)
      }
    }
  end

  @doc """
  `auth.login_denied` — the OAuth callback identified a real user but
  refused to start a session (today: `:disabled` users only). The
  reason is recorded so the admin console can answer "why was X
  refused?".
  """
  @spec auth_login_denied(User.t(), atom() | String.t(), keyword()) :: attrs()
  def auth_login_denied(%User{} = user, reason, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: user.id,
      event_type: "auth.login_denied",
      subject_type: "user",
      subject_id: user.id,
      correlation_id: user.id,
      after_ref: %{
        email: user.email,
        status: atom_or_nil(user.status),
        reason: atom_or_nil(reason)
      }
    }
  end

  @doc """
  `access.invite_created` — operator issued a fresh invite. Subject +
  correlation are both the invite id; this is an invite-lifecycle
  event, queryable independently of any user trace.
  """
  @spec access_invite_created(AccessInvite.t(), User.t(), keyword()) :: attrs()
  def access_invite_created(%AccessInvite{} = invite, %User{} = invited_by, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: invited_by.id,
      event_type: "access.invite_created",
      subject_type: "access_invite",
      subject_id: invite.id,
      correlation_id: invite.id,
      after_ref: invite_snapshot(invite)
    }
  end

  @doc """
  `access.invite_revoked` — operator revoked an active invite. The
  before / after refs pin the status transition so replay can show
  the exact moment the invite became unusable.
  """
  @spec access_invite_revoked(AccessInvite.t(), User.t(), keyword()) :: attrs()
  def access_invite_revoked(%AccessInvite{} = invite, %User{} = revoked_by, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: revoked_by.id,
      event_type: "access.invite_revoked",
      subject_type: "access_invite",
      subject_id: invite.id,
      correlation_id: invite.id,
      before_ref: %{status: "active"},
      after_ref: %{
        status: atom_or_nil(invite.status),
        revoked_at: invite.revoked_at,
        revoked_by_user_id: revoked_by.id
      }
    }
  end

  @doc """
  `access.allowlist_matched` — an active invite was matched on a
  successful login.

  `match_type` is one of `:exact_email_accepted` (the invite was
  consumed and a membership was created or already existed) or
  `:domain_matched` (the invite stays active, `matched_at` is now
  stamped). Subject is the invite; correlation is the user so the
  per-user trace surfaces the match.
  """
  @spec access_allowlist_matched(AccessInvite.t(), User.t(), atom(), keyword()) :: attrs()
  def access_allowlist_matched(%AccessInvite{} = invite, %User{} = user, match_type, opts \\ [])
      when match_type in [:exact_email_accepted, :domain_matched] do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: user.id,
      event_type: "access.allowlist_matched",
      subject_type: "access_invite",
      subject_id: invite.id,
      correlation_id: user.id,
      before_ref: %{status: "active"},
      after_ref: %{
        match_type: Atom.to_string(match_type),
        invite_type: atom_or_nil(invite.invite_type),
        status: atom_or_nil(invite.status),
        workspace_id: invite.workspace_id,
        role: atom_or_nil(invite.role),
        accepted_at: invite.accepted_at,
        matched_at: invite.matched_at
      }
    }
  end

  @doc """
  `access.allowlist_missed` — login completed but no active invite
  matched. Recorded once per `apply_invites_for_user/1` call that
  returned no matches; the audit consumer can dedup by `subject_id`
  if they only want unique users.
  """
  @spec access_allowlist_missed(User.t(), keyword()) :: attrs()
  def access_allowlist_missed(%User{} = user, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: user.id,
      event_type: "access.allowlist_missed",
      subject_type: "user",
      subject_id: user.id,
      correlation_id: user.id,
      after_ref: %{
        email: user.email,
        no_matching_invites: true
      }
    }
  end

  @doc """
  `access.admin_approved` — bootstrap admin approved a pending user
  into a workspace. Emitted only on real state transitions
  (`:membership_created`, `:membership_reactivated`); the
  `:already_member` outcome is a no-op and produces no event.

  `prior_status` is `nil` for a fresh insert and `:inactive` for a
  reactivated row — that lets replay distinguish the two flows.
  """
  @spec access_admin_approved(Membership.t(), User.t(), atom() | nil, keyword()) :: attrs()
  def access_admin_approved(%Membership{} = membership, %User{} = admin, prior_status, opts \\ [])
      when is_atom(prior_status) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: admin.id,
      event_type: "access.admin_approved",
      subject_type: "membership",
      subject_id: membership.id,
      correlation_id: membership.user_id,
      before_ref: %{status: atom_or_nil(prior_status)},
      after_ref: %{
        status: atom_or_nil(membership.status),
        role: atom_or_nil(membership.role),
        workspace_id: membership.workspace_id,
        user_id: membership.user_id
      }
    }
  end

  @doc """
  `access.admin_rejected` — bootstrap admin disabled a pending user.
  Emitted only on a real state transition; the `:already_disabled`
  outcome is a no-op and produces no event.

  `prior_status` is the user's status before the flip
  (`:pending_access` or `:active`).
  """
  @spec access_admin_rejected(User.t(), User.t(), atom(), keyword()) :: attrs()
  def access_admin_rejected(%User{} = target, %User{} = admin, prior_status, opts \\ [])
      when is_atom(prior_status) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: admin.id,
      event_type: "access.admin_rejected",
      subject_type: "user",
      subject_id: target.id,
      correlation_id: target.id,
      before_ref: %{status: Atom.to_string(prior_status)},
      after_ref: %{
        status: atom_or_nil(target.status),
        email: target.email
      }
    }
  end

  @doc """
  `api_key.created` — operator minted a new API key (#218a).

  Subject + correlation are both the `api_key.id`; this is a key-
  lifecycle event, queryable independently of any user trace.
  Workspace stamping rides on the audit envelope passthrough so
  the row carries `api_key.workspace_id`.

  The `after_ref` MUST NOT include the raw secret or its hash —
  only public metadata (id, prefix, role, name, expires_at).
  Secret hygiene is enforced by `api_key_snapshot/1`.
  """
  @spec api_key_created(APIKey.t(), User.t(), keyword()) :: attrs()
  def api_key_created(%APIKey{} = api_key, %User{} = creator, opts \\ []) do
    %{
      actor: Keyword.get(opts, :actor, :user),
      actor_id: creator.id,
      event_type: "api_key.created",
      subject_type: "api_key",
      subject_id: api_key.id,
      correlation_id: api_key.id,
      after_ref: api_key_snapshot(api_key),
      workspace_id: api_key.workspace_id
    }
  end

  @doc """
  `api_key.revoked` — operator soft-revoked an active API key
  (#218a). Before / after refs pin the status flip so replay can
  show the exact moment the key became unusable.

  `actor_id` defaults to the API key's original `created_by_user_id`
  if no `:actor` opt is supplied — useful for batch-revoke jobs
  triggered by, e.g., a workspace-wide rotation.
  """
  @spec api_key_revoked(APIKey.t(), keyword()) :: attrs()
  def api_key_revoked(%APIKey{} = api_key, opts \\ []) do
    actor_id =
      case Keyword.get(opts, :actor) do
        %User{id: id} -> id
        nil -> api_key.created_by_user_id
        id when is_binary(id) -> id
      end

    %{
      actor: Keyword.get(opts, :actor_role, :user),
      actor_id: actor_id,
      event_type: "api_key.revoked",
      subject_type: "api_key",
      subject_id: api_key.id,
      correlation_id: api_key.id,
      before_ref: %{status: "active"},
      after_ref: %{
        status: "revoked",
        revoked_at: api_key.revoked_at,
        prefix: api_key.prefix
      },
      workspace_id: api_key.workspace_id
    }
  end

  @doc """
  `api_key.rotated` — operator atomically replaced an active API
  key (#220).

  ONE event captures the full transition:

    * `subject_id` = the NEW key id (forward-looking — this is the
      live credential going forward; querying its history starts
      here).
    * `before_ref` = old key snapshot at the moment of rotation
      (id, prefix, role, name, expires_at, workspace_id,
      created_by_user_id, plus a `revoked_at` flag so replay sees
      the old key's terminal state without a paired
      `api_key.revoked` row).
    * `after_ref` = new key snapshot, same allowlist as
      `api_key_snapshot/1` (no raw secret, no secret_hash).

  ## Actor attribution

  Mirrors `api_key.created`: `actor_id` is the human user who
  initiated the rotation. When the rotate request was itself
  authenticated by an API key (machine caller), the controller
  resolves the calling key's `created_by_user_id` and passes that
  here, so every issued key remains chained back to a real human.

  ## Workspace stamping

  Both old and new keys share `workspace_id` by construction —
  rotation cannot cross workspaces. The audit envelope rides on
  the new key's `workspace_id`.

  ## Secret hygiene

  Neither `before_ref` nor `after_ref` contains the raw secret or
  `secret_hash`. The hard-coded snapshot allowlist enforces this.
  """
  @spec api_key_rotated(APIKey.t(), APIKey.t(), keyword()) :: attrs()
  def api_key_rotated(%APIKey{} = old_key, %APIKey{} = new_key, opts \\ []) do
    actor_id =
      case Keyword.get(opts, :actor) do
        %User{id: id} -> id
        nil -> new_key.created_by_user_id
        id when is_binary(id) -> id
      end

    %{
      actor: Keyword.get(opts, :actor_role, :user),
      actor_id: actor_id,
      event_type: "api_key.rotated",
      subject_type: "api_key",
      subject_id: new_key.id,
      correlation_id: new_key.id,
      before_ref:
        api_key_snapshot(old_key)
        |> Map.put(:revoked_at, old_key.revoked_at),
      after_ref: api_key_snapshot(new_key),
      workspace_id: new_key.workspace_id
    }
  end

  @doc """
  `api_key.denied` — `BankWeb.Plugs.VerifyAPIKey` refused an
  authentication attempt (#222).

  Closes the auth-side observability gap: previously, rejected
  attempts only landed in `Logger.warning` lines, invisible to the
  audit/replay pipeline. Now every reject path emits ONE audit
  event, deduped per `(prefix-or-id, reason, window)` via
  `Bank.Audit.DedupeWindow.claim/2` so a brute-force probe cannot
  flood the audit log.

  ## Reasons

  The internal `verify_key/1` distinguishes seven reject reasons
  (`:missing_authorization`, `:invalid_authorization_scheme`,
  `:malformed`, `:not_found`, `:hash_mismatch`, `:revoked`,
  `:expired`) but maps them to fewer wire codes to avoid leaking
  timing / probing signal. The audit shape mirrors the wire
  collapse:

    * `:missing` — header absent or wrong scheme
    * `:malformed` — token did not match `cb_<base32>` shape
    * `:invalid_credentials` — prefix lookup missed OR hash compare
      failed (collapsed; same as the 401 wire code)
    * `:revoked` — key found and revoked
    * `:expired` — key found and expired
    * `:workspace_paused` — key valid, but its workspace has
      `agent_keys_paused_at` set (#231-a)

  ## Subject identity

  When `verify_key/1` found a row (`:hash_mismatch`, `:revoked`,
  `:expired`), `subject_id = api_key.id` and `workspace_id` is
  stamped — the row is real and the workspace tag is safe.

  When the prefix was parsed but no row matched (`:not_found`),
  `subject_id = "prefix:" <> prefix` — the bare prefix is a public
  identifier, no leakage.

  When no prefix was even parseable (`:missing`, `:malformed`),
  `subject_id = "anonymous"` — sentinel for unknown-credential
  events. `workspace_id` is `nil`.

  ## Actor

  `:runtime` with `actor_id = nil`. The runtime is the rejecting
  party; no calling-agent identity exists for failed auth. Same
  convention used by other runtime-emitted events
  (`intent.state_changed`, `simulation.produced`).

  ## Secret hygiene

  `after_ref` is a hard-coded allowlist: `reason` (string),
  `prefix` (8 chars or nil), `api_key_id` (uuid or nil). NEVER the
  raw bearer token, `secret_hash`, Authorization header bytes, or
  remote IP. Tests JSON-encode the row and refute every leakable
  substring.
  """
  @spec api_key_denied(atom(), keyword()) :: attrs()
  def api_key_denied(reason, opts \\ [])
      when reason in [
             :missing,
             :malformed,
             :invalid_credentials,
             :revoked,
             :expired,
             :workspace_paused
           ] do
    api_key = Keyword.get(opts, :api_key)
    prefix = Keyword.get(opts, :prefix)

    {subject_id, workspace_id, api_key_id} =
      case api_key do
        %APIKey{} = k -> {k.id, k.workspace_id, k.id}
        _ when is_binary(prefix) -> {"prefix:" <> prefix, nil, nil}
        _ -> {"anonymous", nil, nil}
      end

    %{
      actor: :runtime,
      actor_id: nil,
      event_type: "api_key.denied",
      subject_type: "api_key",
      subject_id: subject_id,
      after_ref: %{
        reason: Atom.to_string(reason),
        prefix: prefix,
        api_key_id: api_key_id
      },
      workspace_id: workspace_id
    }
  end

  @doc """
  `api_key.auth_failure_limited` — the per-bucket auth-failure
  threshold tripped (#221, second slice).

  Emitted at MOST ONCE per `(bucket_key, window)` slot via
  `Bank.Audit.DedupeWindow.claim/2`. The bucket key is one of:

    * `"auth_fail:id:" <> api_key.id` — the row was found but
      hash compare / revocation / expiry failed.
    * `"auth_fail:prefix:" <> prefix` — prefix parsed but no row
      matched (`:not_found`).
    * `"auth_fail:ip:" <> remote_ip` — token was malformed; bucket
      by source IP because there is no per-key identity to
      attribute the attempt to.

  This event fires IN ADDITION to the existing per-attempt
  `api_key.denied` (which has its own 60s dedupe). Operators
  querying `api_key.auth_failure_limited` see only events where a
  threshold was crossed, NOT every individual rejected attempt.

  ## Subject identity

    * Known key (id bucket) → `subject_id = api_key.id`,
      `workspace_id` stamped.
    * Prefix-only bucket → `subject_id = "prefix:" <> prefix`,
      `workspace_id` nil.
    * IP bucket → `subject_id = "ip:" <> ip`, `workspace_id` nil.

  ## Secret hygiene

  `after_ref` is a hard-coded allowlist: `bucket_kind`,
  `bucket_key` (already public-safe — see above), `prefix`
  (when known), `api_key_id` (when known), `limit`, `window`,
  `retry_after_seconds`. NEVER raw bearer, `secret_hash`, or
  Authorization header bytes.
  """
  @spec api_key_auth_failure_limited(
          %{
            required(:bucket_kind) => :id | :prefix | :ip,
            required(:bucket_id) => String.t(),
            required(:prefix) => String.t() | nil,
            required(:api_key) => APIKey.t() | nil,
            required(:window_start) => integer(),
            required(:window_end) => integer(),
            required(:limit) => pos_integer(),
            required(:retry_after_seconds) => pos_integer()
          },
          keyword()
        ) :: attrs()
  def api_key_auth_failure_limited(meta, _opts \\ []) do
    %{
      bucket_kind: bucket_kind,
      bucket_id: bucket_id,
      prefix: prefix,
      api_key: api_key,
      window_start: window_start_unix,
      window_end: window_end_unix,
      limit: limit,
      retry_after_seconds: retry_after
    } = meta

    {subject_id, workspace_id, api_key_id} =
      case {bucket_kind, api_key} do
        {:id, %APIKey{} = k} -> {k.id, k.workspace_id, k.id}
        {:prefix, _} -> {"prefix:" <> bucket_id, nil, nil}
        {:ip, _} -> {"ip:" <> bucket_id, nil, nil}
        _ -> {"anonymous", nil, nil}
      end

    %{
      actor: :runtime,
      actor_id: nil,
      event_type: "api_key.auth_failure_limited",
      subject_type: "api_key",
      subject_id: subject_id,
      after_ref: %{
        bucket_kind: Atom.to_string(bucket_kind),
        bucket_id: bucket_id,
        prefix: prefix,
        api_key_id: api_key_id,
        window_start: window_start_unix |> DateTime.from_unix!() |> DateTime.to_iso8601(),
        window_end: window_end_unix |> DateTime.from_unix!() |> DateTime.to_iso8601(),
        limit: limit,
        retry_after_seconds: retry_after
      },
      workspace_id: workspace_id
    }
  end

  @doc """
  `agent_keys.paused` — operator paused workspace-wide agent-key
  auth (#231-a, parent epic #212).

  Subject is the **workspace**, not any individual key. Pause is a
  workspace-level state flip; the per-key rows are unchanged. The
  per-request `api_key.denied` events from `VerifyAPIKey` carry
  the per-key context for the actual reject traffic.

  Emitted ONLY on the actual transition (NULL → paused). A repeat
  pause on an already-paused workspace is a no-op and does not
  emit. Mirrors `revoke_key/2`'s "first-transition only" rule.

  ## Actor

  Always `:user` — pause is an operator action, not service-account
  traffic. From a session caller (Google OAuth / LiveView),
  `actor_id = current_user.id`. From an API-key caller (a future
  admin-tier `/v1/security/pause_agent_keys` endpoint), the
  controller resolves `calling_api_key.created_by_user_id` and
  passes that. Every pause stays chained to a human.

  ## after_ref allowlist

  Hard-coded: `:paused_at`, `:paused_by_user_id`, `:reason` only.
  No API key prefixes, ids, secrets, or hashes — the events are
  workspace-level. JSON-scan tests refute every leakable substring.
  """
  @spec agent_keys_paused(Bank.Workspaces.Workspace.t(), keyword()) :: attrs()
  def agent_keys_paused(%Bank.Workspaces.Workspace{} = workspace, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)
    actor_id = actor_id(actor)

    %{
      actor: :user,
      actor_id: actor_id,
      event_type: "agent_keys.paused",
      subject_type: "workspace",
      subject_id: workspace.id,
      correlation_id: workspace.id,
      before_ref: %{paused_at: nil},
      after_ref: %{
        paused_at: workspace.agent_keys_paused_at,
        paused_by_user_id: workspace.agent_keys_paused_by_user_id,
        reason: workspace.agent_keys_paused_reason
      },
      workspace_id: workspace.id
    }
  end

  @doc """
  `agent_keys.resumed` — operator cleared the workspace-wide
  agent-key pause (#231-a).

  Emitted ONLY on the actual transition (paused → NULL). Repeat
  resume on an unpaused workspace is a no-op.

  `before_ref` carries the prior `paused_at` + `paused_by_user_id`
  so replay can reconstruct who initiated the pause that this
  resume cleared. `after_ref` is the empty resumed marker.
  """
  @spec agent_keys_resumed(Bank.Workspaces.Workspace.t(), map(), keyword()) :: attrs()
  def agent_keys_resumed(%Bank.Workspaces.Workspace{} = workspace, prior, opts \\ [])
      when is_map(prior) do
    actor = Keyword.fetch!(opts, :actor)
    actor_id = actor_id(actor)

    %{
      actor: :user,
      actor_id: actor_id,
      event_type: "agent_keys.resumed",
      subject_type: "workspace",
      subject_id: workspace.id,
      correlation_id: workspace.id,
      before_ref: %{
        paused_at: Map.get(prior, :paused_at),
        paused_by_user_id: Map.get(prior, :paused_by_user_id)
      },
      after_ref: %{paused_at: nil},
      workspace_id: workspace.id
    }
  end

  @doc """
  `security.scope_paused` — operator paused a DB-backed
  workspace-scoped resource (#228 Phase 1: `:chain`; later phases
  extend to `:smart_account` / `:api_key`).

  Subject is the **resource being paused**, not the workspace —
  `subject_type` is the scope kind (e.g. `"chain"`) and
  `subject_id` is the scope value (e.g. `"base"`). Workspace
  isolation rides on the envelope `:workspace_id` field so that
  `BankWeb.SecurityLive`'s `visible_to_workspace?/3` clause can
  gate timeline visibility on the row's `workspace_id` rather than
  overloading `subject_id`.

  Emitted ONLY on the actual transition. Idempotent re-pause does
  not emit a second event (the context returns the existing row).

  ## `after_ref` allowlist

  Hard-coded: `:scope_type`, `:scope_value`, `:paused_at`,
  `:reason`, `:created_by_user_id`. No secrets, no API key
  prefixes/hashes, no tx hashes — pause events live above the
  chain layer. JSON-scan tests refute every leakable substring.

  No `expires_at` in Phase 1; the column itself is deferred to
  Phase 1.5 (column + sweeper land together).
  """
  @spec security_scope_paused(Bank.Security.Pause.t(), keyword()) :: attrs()
  def security_scope_paused(%Bank.Security.Pause{} = pause, opts \\ []) do
    raw_actor = Keyword.get(opts, :actor, :user)
    actor = normalize_actor(raw_actor)
    actor_id = Keyword.get(opts, :actor_id) || actor_id_or_nil(raw_actor)

    %{
      actor: actor,
      actor_id: actor_id,
      event_type: "security.scope_paused",
      subject_type: subject_type_for(pause.scope_type),
      subject_id: pause.scope_value,
      correlation_id: nil,
      before_ref: %{paused_at: nil},
      after_ref: %{
        scope_type: subject_type_for(pause.scope_type),
        scope_value: pause.scope_value,
        paused_at: pause.paused_at,
        reason: pause.reason,
        created_by_user_id: pause.created_by_user_id
      },
      workspace_id: pause.workspace_id
    }
  end

  @doc """
  `security.scope_resumed` — operator cleared a DB-backed
  workspace-scoped pause (#228 Phase 1: `:chain`).

  `before_ref` carries the prior pause snapshot (paused_at,
  reason, created_by_user_id) so replay can reconstruct the pause
  this resume cleared. `after_ref` records the resume terminator.

  Emitted ONLY on the actual transition. Idempotent re-resume on
  an already-running scope does not emit.
  """
  @spec security_scope_resumed(Bank.Security.Pause.t(), map(), keyword()) :: attrs()
  def security_scope_resumed(%Bank.Security.Pause{} = pause, prior, opts \\ [])
      when is_map(prior) do
    raw_actor = Keyword.get(opts, :actor, :user)
    actor = normalize_actor(raw_actor)
    actor_id = Keyword.get(opts, :actor_id) || actor_id_or_nil(raw_actor)

    %{
      actor: actor,
      actor_id: actor_id,
      event_type: "security.scope_resumed",
      subject_type: subject_type_for(pause.scope_type),
      subject_id: pause.scope_value,
      correlation_id: nil,
      before_ref: %{
        paused_at: Map.get(prior, :paused_at),
        reason: Map.get(prior, :reason),
        created_by_user_id: Map.get(prior, :created_by_user_id)
      },
      after_ref: %{
        scope_type: subject_type_for(pause.scope_type),
        scope_value: pause.scope_value,
        resumed_at: pause.resumed_at,
        resumed_by_user_id: pause.resumed_by_user_id
      },
      workspace_id: pause.workspace_id
    }
  end

  # Normalize the `:actor` opt into the atom enum stored on
  # `audit_events.actor`. A `%User{}` value rolls up to `:user`; the
  # atomic actor kinds (`:user`, `:agent`, `:runtime`, `:adapter`)
  # pass through unchanged so internal callers (the runtime worker,
  # the adapter callback path) record the right actor kind on the
  # scoped pause/resume event. Anything else collapses to `:user`
  # rather than crashing — operator-driven flows are the dominant
  # case.
  defp normalize_actor(%User{}), do: :user
  defp normalize_actor(actor) when actor in [:user, :agent, :runtime, :adapter], do: actor
  defp normalize_actor(_), do: :user

  @doc """
  `security.scope_expired` — the periodic
  `Bank.Runtime.Workers.SweepExpiredPauses` worker auto-resumed a
  scoped pause whose `expires_at` had passed (#228 Phase 1.5).

  Distinct from `security.scope_resumed` so replay readers can
  tell the difference between an operator-driven resume and a
  passive auto-expiry. Actor is always `:runtime` (no human in
  the loop).

  `before_ref` carries the prior pause snapshot (paused_at,
  reason, created_by_user_id, expires_at) so replay can
  reconstruct the pause this expiry cleared. `after_ref` records
  the resume terminator and echoes `expires_at` so consumers
  reading only the after-snapshot still see why the row resumed.
  """
  @spec security_scope_expired(Bank.Security.Pause.t(), map(), keyword()) :: attrs()
  def security_scope_expired(%Bank.Security.Pause{} = pause, prior, opts \\ [])
      when is_map(prior) do
    actor_id = Keyword.get(opts, :actor_id)

    %{
      actor: :runtime,
      actor_id: actor_id,
      event_type: "security.scope_expired",
      subject_type: subject_type_for(pause.scope_type),
      subject_id: pause.scope_value,
      correlation_id: nil,
      before_ref: %{
        paused_at: Map.get(prior, :paused_at),
        reason: Map.get(prior, :reason),
        created_by_user_id: Map.get(prior, :created_by_user_id),
        expires_at: Map.get(prior, :expires_at)
      },
      after_ref: %{
        scope_type: subject_type_for(pause.scope_type),
        scope_value: pause.scope_value,
        resumed_at: pause.resumed_at,
        expires_at: pause.expires_at
      },
      workspace_id: pause.workspace_id
    }
  end

  defp subject_type_for(:chain), do: "chain"
  defp subject_type_for(scope_type) when is_atom(scope_type), do: Atom.to_string(scope_type)

  defp actor_id_or_nil(%User{id: id}), do: id
  defp actor_id_or_nil(id) when is_binary(id), do: id
  defp actor_id_or_nil(_), do: nil

  defp actor_id(%User{id: id}), do: id
  defp actor_id(id) when is_binary(id), do: id

  @doc """
  `api_key.rate_limited` — the rate-limit plug refused a request
  because the per-key counter exceeded the window quota (#221, first
  slice).

  Emitted at MOST ONCE per (api_key, window) — the plug calls
  `Bank.RateLimit.claim_audit/2` and only proceeds if the claim
  succeeds. Without that dedupe, a bursty bot would generate one
  audit row per refused request, drowning the integrity log in
  noise.

  ## Actor

  `:agent` with `actor_id = api_key.id`. Same convention as
  `api_key.used`: the calling key is the responsible party for
  service-account-style traffic, even though it ultimately maps
  back to a human via `created_by_user_id`.

  ## Scope discriminator (#221, third + fourth slices)

  The `:scope` opt picks which limiter fired:

    * `:key` (default) — the per-key bucket from #286.
    * `:workspace` — the per-workspace collective bucket. Bucket
      key is the workspace id; `after_ref.bucket_id` carries it
      explicitly so operators can query by workspace without
      reconstructing it.
    * `:chain_action` — the stricter chain-action bucket from
      #221's fourth slice. Applies ONLY to `/v1/security/*`
      (pause / resume / revoke_delegation). Bucket key is the
      calling api_key.id; the lower threshold reflects that a
      legitimate operator does not pause the runtime 5+ times
      per minute.

  Same event_type and subject_id (the calling key) in all cases
  — minimal schema surface, single query for "all rate-limit
  events". The discriminator lives in `after_ref.scope` so SDK
  consumers and replay tools can filter without inventing a new
  event taxonomy.

  ## after_ref shape

  Hard-coded allowlist — explicitly excludes the raw key,
  `secret_hash`, and any Authorization header bytes. The fields
  recorded are the same `id` / `prefix` / `role` triple used by
  `api_key.used`, plus the window bounds, the configured `limit`,
  the `retry_after_seconds` returned to the client, the `scope`
  discriminator, and (for workspace scope) the `bucket_id`.
  Operators reading replay can answer "which key, when, and how
  badly was it over" without correlating against any other source.
  """
  @spec api_key_rate_limited(
          APIKey.t(),
          %{
            required(:window_start) => integer(),
            required(:window_end) => integer(),
            required(:limit) => pos_integer(),
            required(:retry_after_seconds) => pos_integer()
          },
          keyword()
        ) :: attrs()
  def api_key_rate_limited(api_key, meta, opts \\ [])

  def api_key_rate_limited(
        %APIKey{} = api_key,
        %{
          window_start: window_start_unix,
          window_end: window_end_unix,
          limit: limit,
          retry_after_seconds: retry_after
        },
        opts
      )
      when is_integer(window_start_unix) and is_integer(window_end_unix) and
             is_integer(limit) and is_integer(retry_after) and is_list(opts) do
    scope = Keyword.get(opts, :scope, :key)
    true = scope in [:key, :workspace, :chain_action]

    bucket_id =
      case scope do
        :key -> api_key.id
        :workspace -> api_key.workspace_id
        :chain_action -> api_key.id
      end

    %{
      actor: :agent,
      actor_id: api_key.id,
      event_type: "api_key.rate_limited",
      subject_type: "api_key",
      subject_id: api_key.id,
      correlation_id: api_key.id,
      after_ref: %{
        id: api_key.id,
        prefix: api_key.prefix,
        role: atom_or_nil(api_key.role),
        scope: Atom.to_string(scope),
        bucket_id: bucket_id,
        window_start: window_start_unix |> DateTime.from_unix!() |> DateTime.to_iso8601(),
        window_end: window_end_unix |> DateTime.from_unix!() |> DateTime.to_iso8601(),
        limit: limit,
        retry_after_seconds: retry_after
      },
      workspace_id: api_key.workspace_id
    }
  end

  @doc """
  `api_key.used` — daily aggregate emitted by
  `Bank.Runtime.Workers.AggregateAPIKeyUsage` (#218d).

  This event is intentionally NOT per-request. Each row reports
  that a single API key was used at least once in
  `[window_start, window_end)`. Per-request emission would be
  thousands of audit rows per workspace per day and the integrity
  pipeline (#161) is not a metrics surface.

  Workspace stamping: rides on the audit envelope passthrough
  from `api_key.workspace_id` (same as create / revoke).

  Actor attribution: `:agent`. The API key is a service-account-
  style credential; the audit row's `actor_id` is the api_key id
  itself (the human who created it is captured via the
  `created_by_user_id` link on the row, not on the audit event).
  """
  @spec api_key_used(APIKey.t(), %{
          required(:window_start) => DateTime.t(),
          required(:window_end) => DateTime.t(),
          required(:last_used_at) => DateTime.t() | nil
        }) :: attrs()
  def api_key_used(%APIKey{} = api_key, %{
        window_start: %DateTime{} = window_start,
        window_end: %DateTime{} = window_end,
        last_used_at: last_used_at
      }) do
    %{
      actor: :agent,
      actor_id: api_key.id,
      event_type: "api_key.used",
      subject_type: "api_key",
      subject_id: api_key.id,
      correlation_id: api_key.id,
      after_ref: %{
        id: api_key.id,
        prefix: api_key.prefix,
        role: atom_or_nil(api_key.role),
        window_start: DateTime.to_iso8601(window_start),
        window_end: DateTime.to_iso8601(window_end),
        last_used_at:
          case last_used_at do
            %DateTime{} = dt -> DateTime.to_iso8601(dt)
            nil -> nil
          end
      },
      workspace_id: api_key.workspace_id
    }
  end

  # --- snapshot builders ------------------------------------------------

  defp api_key_snapshot(%APIKey{} = api_key) do
    # Hard-coded field list (NOT `Map.from_struct/1` or similar) so
    # a future column added to `APIKey` does not silently leak into
    # the audit `after_ref`. `secret_hash` is deliberately absent.
    %{
      id: api_key.id,
      prefix: api_key.prefix,
      role: atom_or_nil(api_key.role),
      name: api_key.name,
      workspace_id: api_key.workspace_id,
      created_by_user_id: api_key.created_by_user_id,
      expires_at: api_key.expires_at
    }
  end

  defp invite_snapshot(%AccessInvite{} = invite) do
    %{
      id: invite.id,
      invite_type: atom_or_nil(invite.invite_type),
      email: invite.email,
      domain: invite.domain,
      role: atom_or_nil(invite.role),
      status: atom_or_nil(invite.status),
      workspace_id: invite.workspace_id,
      expires_at: invite.expires_at
    }
  end

  defp intent_snapshot(%AgentIntent{} = intent) do
    %{
      id: intent.id,
      state: atom_or_nil(intent.state),
      kind: atom_or_nil(intent.kind),
      asset: intent.asset,
      chain: intent.chain,
      amount: decimal_to_string(intent.amount)
    }
  end

  defp counterparty_snapshot(%Counterparty{} = cp) do
    %{
      id: cp.id,
      name: cp.name,
      ownership_context: cp.ownership_context,
      notes: cp.notes,
      active: cp.active,
      current_trust_level: atom_or_nil(cp.current_trust_level)
    }
  end

  defp address_label_snapshot(%AddressLabel{} = label) do
    %{
      id: label.id,
      counterparty_id: label.counterparty_id,
      chain: label.chain,
      address: label.address,
      alias: label.alias,
      role: atom_or_nil(label.role),
      verified: label.verified,
      retired_at: label.retired_at
    }
  end

  defp evidence_snapshot(%EvidenceArtifact{} = artifact) do
    %{
      id: artifact.id,
      subject_type: artifact.subject_type,
      subject_id: artifact.subject_id,
      kind: atom_or_nil(artifact.kind),
      source: artifact.source,
      content_uri: artifact.content_uri,
      weight: atom_or_nil(artifact.weight),
      captured_at: artifact.captured_at,
      captured_by: atom_or_nil(artifact.captured_by),
      supersedes_id: artifact.supersedes_id
    }
  end

  defp trust_assertion_snapshot(%TrustAssertion{} = assertion) do
    %{
      id: assertion.id,
      subject_type: assertion.subject_type,
      subject_id: assertion.subject_id,
      level: atom_or_nil(assertion.level),
      scope: assertion.scope,
      rationale: assertion.rationale,
      evidence_ids: assertion.evidence_ids,
      issued_at: assertion.issued_at,
      issued_by: atom_or_nil(assertion.issued_by),
      expires_at: assertion.expires_at,
      supersedes_id: assertion.supersedes_id
    }
  end

  defp trust_assertion_before_ref(nil), do: nil

  defp trust_assertion_before_ref(%TrustAssertion{} = prior) do
    %{
      id: prior.id,
      level: atom_or_nil(prior.level),
      scope: prior.scope
    }
  end

  defp policy_rule_snapshot(%PolicyRule{} = rule) do
    %{
      id: rule.id,
      version: rule.version,
      state: atom_or_nil(rule.state),
      rule_type: atom_or_nil(rule.rule_type),
      scope: rule.scope,
      params: rule.params,
      priority: rule.priority,
      supersedes_id: rule.supersedes_id
    }
  end

  defp decision_snapshot(%DecisionEnvelope{} = envelope) do
    %{
      id: envelope.id,
      outcome: atom_or_nil(envelope.outcome),
      risk_tier: atom_or_nil(envelope.risk_tier),
      state: atom_or_nil(envelope.state),
      approval_expires_at: envelope.approval_expires_at,
      policy_snapshot_ref: envelope.policy_snapshot_ref
    }
  end

  # Small reference to a Morpho vault snapshot — id (when
  # persisted) + public identity + the source-block metadata.
  # Never embeds the raw GraphQL payload, the upstream URL, the
  # source warnings list, or any provider secret. The snapshot's
  # `:source` map is already-redacted at ingestion time
  # (#198/#199); we still take only the two public fields
  # (`source_name`, `source_schema_version`) to keep the audit
  # row small and to make the no-secret-leakage contract obvious
  # to readers.
  #
  # Accepts both the persisted row (decision-pipeline default
  # path via `Snapshots.get_current/2`) and the in-memory struct
  # (test injection via the `:morpho_snapshot` opt). The
  # in-memory case carries no `:id` because the row was never
  # written.
  defp morpho_snapshot_ref(nil), do: nil

  defp morpho_snapshot_ref(%PersistedVaultSnapshot{} = s) do
    source = s.source || %{}

    %{
      id: s.id,
      chain_id: s.chain_id,
      vault_address: s.vault_address,
      payload_hash: s.payload_hash,
      fetched_at: s.fetched_at && DateTime.to_iso8601(s.fetched_at),
      source_name: Map.get(source, "source_name"),
      source_schema_version: Map.get(source, "source_schema_version")
    }
  end

  defp morpho_snapshot_ref(%VaultSnapshot{} = s) do
    source = s.source || %{}
    fetched_at = Map.get(source, :fetched_at) || Map.get(source, "fetched_at")

    %{
      id: nil,
      chain_id: s.chain_id,
      vault_address: s.vault_address,
      payload_hash: Map.get(source, :payload_hash) || Map.get(source, "payload_hash"),
      fetched_at: format_fetched_at(fetched_at),
      source_name: Map.get(source, :source_name) || Map.get(source, "source_name"),
      source_schema_version:
        Map.get(source, :source_schema_version) || Map.get(source, "source_schema_version")
    }
  end

  defp format_fetched_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_fetched_at(value) when is_binary(value), do: value
  defp format_fetched_at(_), do: nil

  defp delegation_snapshot(%Delegation{} = d) do
    %{
      id: d.id,
      smart_account_id: d.smart_account_id,
      delegation_id: d.delegation_id,
      state: atom_or_nil(d.state),
      chain: d.chain,
      last_tx_hash: d.last_tx_hash,
      last_reason: d.last_reason
    }
  end

  defp maybe_delegation_state_ref(nil), do: nil
  defp maybe_delegation_state_ref(state), do: %{state: atom_or_nil(state)}

  defp ref_from_supersedes(nil, _subject_type), do: nil

  defp ref_from_supersedes(id, subject_type) when is_binary(id) do
    %{subject_type: subject_type, subject_id: id}
  end

  defp maybe_status_ref(nil), do: nil
  defp maybe_status_ref(status), do: %{execution_status: Atom.to_string(status)}

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_or_nil(other), do: other

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp decimal_to_string(other), do: other
end
