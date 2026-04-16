defmodule Bank.Runtime.Workers.ExpireApproval do
  @moduledoc """
  Fire when an approval-TTL deadline passes: supersede the
  `:approval_required` decision envelope with a `:block` successor,
  transition the intent to `:blocked`, audit, and broadcast.

  This is one of the workers that performs a **real** state
  transition today — it needs no engine, only the persisted envelope
  and intent. The whole transition runs inside a single `Ecto.Multi`
  so the partial unique index
  (`decision_envelopes_intent_current_idx`) stays valid at every
  commit boundary.

  ## Preconditions

  The envelope must be:

    * `current: true` — if a newer envelope (operator granted /
      rejected early) has already superseded it, we cancel as
      `:already_superseded`.
    * `outcome: :approval_required` — anything else is a caller bug.
    * `state in [:decided, :pending_decision]` — `:resolved` means
      the envelope is already final.

  ## Emitted effects

    1. A `decision.decided` audit event for the block successor
       (`before_ref` carries the prior envelope).
    2. An `intent.state_changed` audit event for `decided → blocked`.
    3. A PubSub message on `approval:queue` (`:expired`).
    4. A PubSub message on `intent:{id}` (`:decision_updated`).
    5. A PubSub message on `audit:stream` for each audit event
       (via `Bank.Runtime.emit_audit/1`).

  ## Retry posture

    * `:ok` on success.
    * `{:cancel, reason}` for `:not_found`, `:already_superseded`,
      wrong-outcome: retrying wouldn't help.
    * `{:error, reason}` for transient DB failure; standard Oban
      retry.
  """

  use Oban.Worker,
    queue: :approvals_expire,
    max_attempts: 5

  alias Bank.Audit.Events
  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime
  alias Bank.Runtime.Notifier
  alias Ecto.Multi

  require Logger

  @valid_prior_states [:decided, :pending_decision]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"decision_envelope_id" => envelope_id}}) do
    with {:ok, prior, intent} <- load(envelope_id) do
      expire(prior, intent)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("ExpireApproval: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end

  defp load(envelope_id) do
    case Repo.get(DecisionEnvelope, envelope_id) do
      nil ->
        {:cancel, :not_found}

      %DecisionEnvelope{current: false} ->
        {:cancel, :already_superseded}

      %DecisionEnvelope{outcome: :approval_required, state: state} = prior
      when state in @valid_prior_states ->
        case Repo.get(AgentIntent, prior.intent_id) do
          nil -> {:cancel, :intent_not_found}
          %AgentIntent{} = intent -> {:ok, prior, intent}
        end

      %DecisionEnvelope{outcome: outcome} ->
        {:cancel, {:wrong_outcome, outcome}}

      %DecisionEnvelope{state: state} ->
        {:cancel, {:wrong_state, state}}
    end
  end

  defp expire(prior, intent) do
    now = DateTime.utc_now()
    prior_state = intent.state

    multi =
      Multi.new()
      |> Multi.update(:mark_not_current, DecisionEnvelope.mark_not_current(prior))
      |> Multi.insert(:successor, fn _ ->
        DecisionEnvelope.supersede(prior, %{
          outcome: :block,
          risk_tier: prior.risk_tier,
          reasons: %{
            "items" => [
              %{
                "code" => "approval_expired",
                "message" => "approval deadline passed"
              }
            ]
          },
          policy_snapshot_ref: prior.policy_snapshot_ref,
          trust_assessment_id: prior.trust_assessment_id,
          simulation_report_id: prior.simulation_report_id,
          decided_at: now,
          decided_by: :runtime,
          state: :resolved,
          current: true,
          approval_expires_at: nil
        })
      end)
      |> Multi.update(:intent, fn %{successor: successor} ->
        AgentIntent.current_pointer_changeset(intent, %{
          current_decision_id: successor.id,
          state: :blocked
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{successor: successor, intent: updated_intent}} ->
        emit_side_effects(prior, successor, prior_state, updated_intent)
        :ok

      {:error, step, reason, _changes} ->
        Logger.error("ExpireApproval: multi failed at #{step}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp emit_side_effects(prior, successor, prior_intent_state, intent) do
    Runtime.emit_audit(Events.decision_decided(successor))

    Runtime.emit_audit(Events.intent_state_changed(intent, prior_intent_state, intent.state))

    # Broadcast after the audit write so subscribers see a consistent
    # ordering of events (DB first, realtime second). Using the prior
    # envelope's id lets `approval:queue` consumers find the row they
    # were tracking even though it is no longer current.
    Notifier.approval_queue(:expired, prior, %{
      successor_decision_envelope_id: successor.id,
      final_outcome: :block
    })

    Notifier.intent_lifecycle(intent, :decision_updated, %{
      decision_envelope_id: successor.id,
      outcome: :block,
      reason: :approval_expired
    })
  end
end
