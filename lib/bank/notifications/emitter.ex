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
  alias Bank.Intents.AgentIntent
  alias Bank.Notifications

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
