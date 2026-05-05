defmodule Bank.Notifications.Emitter do
  @moduledoc """
  Runtime notification emitters (#234).

  Thin wrappers around `Bank.Notifications.create/1` that the
  domain pipeline calls *after* its own transaction commits, so a
  notification-side failure can never roll back the underlying
  state transition (the issue's "failure to create notification
  does not break safe runtime decision" acceptance bullet).

  ## Source paths wired today

    * `emit_decision_outcome/2` — every `Bank.Decisions.evaluate_intent/3`
      call. Surfaces `:approval_required` / `:hold` / `:block`
      envelopes; `:auto_exec` is intentionally silent (no operator
      action required).
    * `emit_execution_outcome/1` — every `Bank.Decisions.apply_execution_callback/1`
      call that transitions an `%ExecutionPlan{}` to a terminal
      status. Surfaces `:reverted` (critical) and `:aborted`
      (warning) on every call. `:confirmed` is gated on a
      workspace opt-in flag — `Bank.Workspaces.Workspace.notify_execution_confirmed?/1`
      — so success-side rows only land when an admin has
      explicitly opted in. Default is `false` (#234 acceptance:
      "execution confirmed if configured"); a workspace that
      hasn't flipped the flag keeps today's silent-on-success
      posture.
    * `emit_access_approved/1` — every `Bank.Access.approve_pending_user/3`
      call that creates or reactivates a membership. Surfaces an
      `:info` notification to the newly admitted user, scoped to
      the workspace they were just admitted to. The pending /
      requested and rejected access source paths are intentionally
      silent here because they have no clean workspace boundary in
      the current model — listed as remaining #234 blockers.
    * `emit_pause_scope_paused/1` — every `Bank.Security.Pauses.create_pause/4`
      transition that actually paused a scope (NOT the idempotent
      `:already_paused` short-circuit). Surfaces a `:warning`
      operator notification with the pause subject (chain id today,
      future scope types per #228 design). Audit emission lives
      inside the pause transaction; this emitter runs *after* the
      transaction commits so a notification-side failure cannot
      roll back the pause.
    * `emit_pause_scope_resumed/1` — every
      `Bank.Security.Pauses.resume/4` transition that actually
      resumed a paused scope (NOT the idempotent
      `:already_running` short-circuit). Surfaces an `:info`
      operator notification — recovery is informational, not a
      warning, mirroring the resolve-side severity convention from
      #256's `Bank.Ops.Alerts`.

  ## Dedupe semantics

  Each emitter computes a deterministic `dedupe_key` keyed on the
  domain identifier *and* the surfaced outcome — re-evaluating the
  same intent and landing on the same outcome again does not
  re-spam the inbox. Re-evaluating an intent and landing on a
  *different* outcome generates a fresh row (different dedupe key).

  ## Side-effect contract

  This module does NOT:

    * call any external delivery channel (#236 is a separate slice),
    * enqueue any Oban job,
    * broadcast on PubSub,
    * touch the chain adapter.

  It writes one inbox row to the `notifications` table and returns
  the result. The return value is `{:ok, n}` for a fresh insert,
  `{:duplicate, existing}` for an already-recorded `(workspace,
  dedupe_key)` pair, `{:skip, reason}` when the outcome is not
  one we surface (e.g. `:auto_exec`), or `{:error, changeset}` for
  a validation failure (callers log and move on — never raise).

  ## Secret hygiene

  The `title` / `body` / `action_link` we compose are derived only
  from controlled enum values (`outcome`, `risk_tier`), id
  fragments, and ISO timestamps. No free-text intent fields
  (`notes`, `target_raw_address`, etc.) and no provider /
  callback / authorization values reach the inbox.
  `Bank.Notifications.create/1` will additionally reject any
  unsafe-text shape via its existing secret-marker gate.
  """

  require Logger

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Intents.AgentIntent
  alias Bank.Notifications
  alias Bank.Security.Pause
  alias Bank.Workspaces
  alias Bank.Workspaces.Membership
  alias Bank.Workspaces.Workspace

  @type outcome_result ::
          {:ok, Notifications.Notification.t()}
          | {:duplicate, Notifications.Notification.t()}
          | {:skip, atom()}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Emit (or dedupe) a notification for an `evaluate_intent/3`
  decision. Always returns; never raises. Invalid outcomes return
  `{:skip, reason}` so callers can log and continue.
  """
  @spec emit_decision_outcome(AgentIntent.t(), DecisionEnvelope.t()) :: outcome_result()
  def emit_decision_outcome(%AgentIntent{} = intent, %DecisionEnvelope{} = envelope) do
    cond do
      is_nil(intent.workspace_id) ->
        # Legacy nullable-workspace_id paths (pre-#155 callers) have
        # no workspace boundary to scope an inbox row to. Skip
        # silently — these paths are being migrated separately and
        # do not need a runtime warning per evaluation.
        {:skip, :no_workspace_id}

      envelope.outcome == :auto_exec ->
        {:skip, :auto_exec_no_inbox_row}

      envelope.outcome in [:approval_required, :hold, :block] ->
        outcome = envelope.outcome
        attrs = build_decision_outcome_attrs(intent, envelope, outcome)

        case Notifications.create(attrs) do
          {:ok, _} = ok ->
            ok

          {:duplicate, _} = dup ->
            dup

          {:error, changeset} = err ->
            # Notification creation must never break the decision
            # path — log and return so the caller can move on.
            Logger.warning(
              "Bank.Notifications.Emitter: decision-outcome notification rejected " <>
                "(intent=#{intent.id} outcome=#{outcome} errors=#{inspect(changeset.errors)})"
            )

            err
        end

      true ->
        {:skip, :unknown_outcome}
    end
  end

  defp build_decision_outcome_attrs(intent, envelope, outcome) do
    %{
      workspace_id: intent.workspace_id,
      role_target: :operator,
      event_type: "decision.#{outcome}",
      severity: severity_for(outcome),
      subject_type: "decision_envelope",
      subject_id: envelope.id,
      correlation_id: intent.id,
      title: title_for(outcome, intent),
      body: body_for(envelope),
      action_link: action_link_for(outcome),
      # Same intent + same surfaced outcome dedupes; re-evaluating
      # to a *different* outcome generates a fresh row.
      dedupe_key: "decision:#{intent.id}:#{outcome}"
    }
  end

  @doc """
  Emit (or dedupe) a notification for a terminal
  `Bank.Decisions.apply_execution_callback/1` transition. Always
  returns; never raises. Non-terminal statuses, `:confirmed`
  (until a workspace opt-in setting ships), and intents whose
  workspace boundary is missing all return `{:skip, reason}` so
  the caller can ignore the result.

  Free-text adapter fields (`final_reason`, `tx_refs`, raw
  `params`) are intentionally never threaded into the
  notification payload — only the controlled enum
  `final_outcome` and id fragments reach the inbox.
  """
  @spec emit_execution_outcome(ExecutionPlan.t()) :: outcome_result()
  def emit_execution_outcome(%ExecutionPlan{} = plan) do
    cond do
      plan.execution_status not in [:reverted, :aborted, :confirmed] ->
        # `:broadcasting` / `:signing` / `:prepared` are interim
        # and never produce inbox rows.
        {:skip, {:not_terminal, plan.execution_status}}

      not match?(%AgentIntent{}, plan.intent) ->
        {:skip, :intent_not_loaded}

      is_nil(plan.intent.workspace_id) ->
        {:skip, :no_workspace_id}

      plan.execution_status == :confirmed ->
        # Success-side notification is gated on the workspace's
        # `notify_execution_confirmed` opt-in flag (#234). A
        # workspace that has not opted in keeps today's
        # silent-on-success posture.
        case maybe_emit_confirmed(plan) do
          {:ok, _} = ok -> ok
          {:duplicate, _} = dup -> dup
          {:skip, _} = skip -> skip
          {:error, _} = err -> err
        end

      true ->
        do_emit_execution_outcome(plan)
    end
  end

  defp maybe_emit_confirmed(%ExecutionPlan{intent: %AgentIntent{} = intent} = plan) do
    case Workspaces.get_workspace(intent.workspace_id) do
      %Workspace{} = workspace ->
        if Workspace.notify_execution_confirmed?(workspace) do
          do_emit_execution_outcome(plan)
        else
          {:skip, :confirmed_not_opted_in}
        end

      nil ->
        {:skip, :workspace_not_found}
    end
  end

  defp do_emit_execution_outcome(%ExecutionPlan{intent: %AgentIntent{} = intent} = plan) do
    outcome = plan.execution_status
    attrs = build_execution_outcome_attrs(intent, plan, outcome)

    case Notifications.create(attrs) do
      {:ok, _} = ok ->
        ok

      {:duplicate, _} = dup ->
        dup

      {:error, changeset} = err ->
        Logger.warning(
          "Bank.Notifications.Emitter: execution-outcome notification rejected " <>
            "(plan=#{plan.id} outcome=#{outcome} errors=#{inspect(changeset.errors)})"
        )

        err
    end
  end

  defp build_execution_outcome_attrs(intent, plan, outcome) do
    %{
      workspace_id: intent.workspace_id,
      role_target: :operator,
      event_type: "execution.#{outcome}",
      severity: execution_severity_for(outcome),
      subject_type: "execution_plan",
      subject_id: plan.id,
      correlation_id: intent.id,
      title: execution_title_for(outcome, intent),
      body: execution_body_for(plan),
      action_link: execution_action_link_for(intent),
      # Same plan + same terminal outcome dedupes. The lock-step
      # terminal guard in `apply_execution_callback/1` already
      # rejects duplicate callbacks at the DB layer; this is a
      # belt-and-suspenders check for retries that bypass the
      # transaction (e.g. an emitter-side retry after a
      # transient `Repo.insert` error).
      dedupe_key: "execution:#{plan.id}:#{outcome}"
    }
  end

  defp execution_severity_for(:reverted), do: :critical
  defp execution_severity_for(:aborted), do: :warning
  defp execution_severity_for(:confirmed), do: :info

  defp execution_title_for(:reverted, %AgentIntent{} = intent),
    do: "Execution reverted on #{intent.kind} intent #{short_id(intent.id)}"

  defp execution_title_for(:aborted, %AgentIntent{} = intent),
    do: "Execution aborted on #{intent.kind} intent #{short_id(intent.id)}"

  defp execution_title_for(:confirmed, %AgentIntent{} = intent),
    do: "Execution confirmed on #{intent.kind} intent #{short_id(intent.id)}"

  # Body is composed strictly from controlled fields. We
  # deliberately do NOT include `plan.final_reason` (operator-
  # /adapter-supplied free text), `plan.tx_refs` (chain-side
  # data), or any raw callback params.
  defp execution_body_for(%ExecutionPlan{} = plan) do
    chain = plan.chain || "unknown"
    asset = plan.asset || "unknown"
    "Plan #{short_id(plan.id)} on #{chain}/#{asset} reached terminal #{plan.execution_status}."
  end

  defp execution_action_link_for(%AgentIntent{id: intent_id}) when is_binary(intent_id),
    do: "/audit/replay/#{intent_id}"

  @doc """
  Emit (or dedupe) an inbox notification for a successful
  `Bank.Access.approve_pending_user/3` transition. The recipient
  is the newly admitted user (`user_id`), so they see a concrete
  inbox row when their membership lands. Always returns; never
  raises — the access path's own `safe_emit/1` audit pattern is
  preserved unchanged.

  Caller passes the `%Membership{}` returned from
  `Workspaces.create_membership/1` or
  `Workspaces.set_status(_, :active)`. The workspace slug is
  fetched here so the title can carry a stable, controlled-shape
  identifier without threading it through every call site.
  """
  @spec emit_access_approved(Membership.t() | %{required(:workspace) => Workspace.t()}) ::
          outcome_result()
  def emit_access_approved(%Membership{} = membership) do
    cond do
      is_nil(membership.user_id) ->
        {:skip, :no_user_id}

      is_nil(membership.workspace_id) ->
        {:skip, :no_workspace_id}

      true ->
        case Bank.Workspaces.get_workspace(membership.workspace_id) do
          %Workspace{} = workspace ->
            do_emit_access_approved(membership, workspace)

          nil ->
            {:skip, :workspace_not_found}
        end
    end
  end

  defp do_emit_access_approved(%Membership{} = membership, %Workspace{} = workspace) do
    attrs = build_access_approved_attrs(membership, workspace)

    case Notifications.create(attrs) do
      {:ok, _} = ok ->
        ok

      {:duplicate, _} = dup ->
        dup

      {:error, changeset} = err ->
        Logger.warning(
          "Bank.Notifications.Emitter: access-approved notification rejected " <>
            "(membership=#{membership.id} errors=#{inspect(changeset.errors)})"
        )

        err
    end
  end

  defp build_access_approved_attrs(%Membership{} = membership, %Workspace{} = workspace) do
    %{
      workspace_id: membership.workspace_id,
      user_id: membership.user_id,
      event_type: "access.approved",
      severity: :info,
      subject_type: "membership",
      subject_id: membership.id,
      correlation_id: membership.user_id,
      title: "Access approved: workspace #{workspace.slug}",
      body: "Role: #{membership.role}",
      action_link: "/dashboard",
      # Re-running the approve path on an existing membership
      # currently short-circuits at `Workspaces.set_status` /
      # `Workspaces.create_membership`. Even so, the dedupe key
      # keys on (user_id, workspace_id) so a hypothetical retry
      # of the emit does not double-write.
      dedupe_key: "access:approved:#{membership.user_id}:#{membership.workspace_id}"
    }
  end

  @doc """
  Emit (or dedupe) an inbox notification for a successful
  `Bank.Security.Pauses.create_pause/4` transition. The recipient
  is the workspace's operator role; the body carries only the
  scope_type / scope_value enum + the pause id, never the
  free-text `reason` (the schema's `:unsafe_text` gate would
  reject a leak anyway, but we don't even thread the field
  through).
  """
  @spec emit_pause_scope_paused(Pause.t()) :: outcome_result()
  def emit_pause_scope_paused(%Pause{} = pause) do
    cond do
      is_nil(pause.workspace_id) ->
        {:skip, :no_workspace_id}

      is_nil(pause.id) ->
        {:skip, :pause_not_persisted}

      true ->
        attrs = build_pause_paused_attrs(pause)

        case Notifications.create(attrs) do
          {:ok, _} = ok ->
            ok

          {:duplicate, _} = dup ->
            dup

          {:error, changeset} = err ->
            Logger.warning(
              "Bank.Notifications.Emitter: pause-paused notification rejected " <>
                "(pause=#{pause.id} errors=#{inspect(changeset.errors)})"
            )

            err
        end
    end
  end

  @doc """
  Emit (or dedupe) an inbox notification for a successful
  `Bank.Security.Pauses.resume/4` transition. The recipient is
  the workspace's operator role. Recovery is `:info` — operators
  may want to confirm a resume happened but it's not actionable
  on its own.
  """
  @spec emit_pause_scope_resumed(Pause.t()) :: outcome_result()
  def emit_pause_scope_resumed(%Pause{} = pause) do
    cond do
      is_nil(pause.workspace_id) ->
        {:skip, :no_workspace_id}

      is_nil(pause.id) ->
        {:skip, :pause_not_persisted}

      true ->
        attrs = build_pause_resumed_attrs(pause)

        case Notifications.create(attrs) do
          {:ok, _} = ok ->
            ok

          {:duplicate, _} = dup ->
            dup

          {:error, changeset} = err ->
            Logger.warning(
              "Bank.Notifications.Emitter: pause-resumed notification rejected " <>
                "(pause=#{pause.id} errors=#{inspect(changeset.errors)})"
            )

            err
        end
    end
  end

  defp build_pause_paused_attrs(%Pause{} = pause) do
    scope_label = scope_label_for(pause)

    %{
      workspace_id: pause.workspace_id,
      role_target: :operator,
      event_type: "security.scope_paused",
      severity: :warning,
      subject_type: "pause",
      subject_id: pause.id,
      correlation_id: pause.id,
      title: "Scope paused: #{scope_label}",
      body: "Operator-initiated pause; new dispatches in this scope will be refused.",
      action_link: "/security",
      # Each persisted pause row is a single transition. A re-pause
      # of an already-paused scope short-circuits in
      # `Bank.Security.Pauses.create_pause/4` and never reaches the
      # emitter.
      dedupe_key: "pause:scope_paused:#{pause.id}"
    }
  end

  defp build_pause_resumed_attrs(%Pause{} = pause) do
    scope_label = scope_label_for(pause)

    %{
      workspace_id: pause.workspace_id,
      role_target: :operator,
      event_type: "security.scope_resumed",
      severity: :info,
      subject_type: "pause",
      subject_id: pause.id,
      correlation_id: pause.id,
      title: "Scope resumed: #{scope_label}",
      body: "Pause cleared; new dispatches in this scope are allowed again.",
      action_link: "/security",
      dedupe_key: "pause:scope_resumed:#{pause.id}"
    }
  end

  # `scope_label_for/1` is intentionally narrow: only the
  # controlled enum (`scope_type`) and the workspace-public
  # `scope_value` (kebab-case chain id today, validated by the
  # OpsDashboardLive `safe_scope_value/1` family) reach the
  # notification title. Operator-typed `reason` is NOT threaded.
  defp scope_label_for(%Pause{scope_type: type, scope_value: value})
       when is_atom(type) and is_binary(value) do
    "#{type}:#{value}"
  end

  defp scope_label_for(_), do: "scope"

  defp severity_for(:approval_required), do: :warning
  defp severity_for(:hold), do: :warning
  defp severity_for(:block), do: :critical

  defp title_for(:approval_required, %AgentIntent{} = intent),
    do: "Approval required for #{intent.kind} intent #{short_id(intent.id)}"

  defp title_for(:hold, %AgentIntent{} = intent),
    do: "Decision held on #{intent.kind} intent #{short_id(intent.id)}"

  defp title_for(:block, %AgentIntent{} = intent),
    do: "Decision blocked on #{intent.kind} intent #{short_id(intent.id)}"

  defp body_for(%DecisionEnvelope{} = envelope) do
    decided_at = DateTime.to_iso8601(envelope.decided_at)
    "Risk #{envelope.risk_tier}, decided at #{decided_at}."
  end

  defp action_link_for(:approval_required), do: "/queue#pending-approvals-section"
  defp action_link_for(:hold), do: "/queue#held-actions-section"
  defp action_link_for(:block), do: "/queue#held-actions-section"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
end
