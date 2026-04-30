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
  `execution.<status>` — execution-plan status transition. The status
  is derived from the plan's `execution_status` so the caller only
  hands in the plan.
  """
  @spec execution_transition(ExecutionPlan.t(), atom(), keyword()) :: attrs()
  def execution_transition(%ExecutionPlan{} = plan, prior_status, opts \\ [])
      when is_atom(prior_status) or is_nil(prior_status) do
    %{
      actor: Keyword.get(opts, :actor, :adapter),
      event_type: "execution.#{plan.execution_status}",
      subject_type: "execution_plan",
      subject_id: plan.id,
      correlation_id: plan.intent_id,
      before_ref: maybe_status_ref(prior_status),
      after_ref: %{
        id: plan.id,
        execution_status: atom_or_nil(plan.execution_status),
        final_outcome: atom_or_nil(plan.final_outcome),
        tx_refs: plan.tx_refs || []
      },
      workspace_id: plan.workspace_id
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

  @doc """
  `execution.manually_requested` — an operator triggered manual
  execution for a decision envelope.
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
      after_ref: %{
        id: plan.id,
        decision_id: plan.decision_id,
        execution_status: atom_or_nil(plan.execution_status),
        smart_account_id: plan.smart_account_id
      },
      workspace_id: plan.workspace_id
    }
  end

  @doc """
  `execution.auto_dispatched` — the runtime materialised an
  `ExecutionPlan` for a fresh `:auto_exec` `DecisionEnvelope`
  without operator intervention.

  Distinct from `execution.manually_requested` so audit consumers
  can distinguish operator-triggered execution from runtime-driven
  auto-exec dispatch.
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
      after_ref: %{
        id: plan.id,
        decision_id: plan.decision_id,
        execution_status: atom_or_nil(plan.execution_status),
        smart_account_id: plan.smart_account_id
      },
      workspace_id: plan.workspace_id
    }
  end

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
