defmodule Bank.Runtime.Workers.ConfirmExecution do
  @moduledoc """
  Safety-net worker that reconciles an execution plan's terminal
  state with the owning intent's lifecycle state.

  Since issue #30 the primary execution lifecycle writes are driven
  by adapter callbacks into `Bank.Decisions.apply_execution_callback/1`,
  which updates plan + intent atomically. This worker exists as a
  belt-and-braces poller for the rare case that a callback is lost
  between the adapter writing the plan status and Phoenix advancing
  the intent — e.g. a crash between the plan update and the intent
  update in the controller. In practice it is a no-op; if it ever
  does fire, it applies the same `intent.state_changed` transition
  the callback controller would have.

    * `final_outcome: :confirmed` → intent → `:executed`
    * `final_outcome: :reverted`  → intent → `:blocked`
    * `final_outcome: :aborted`   → intent → `:blocked`

  ### While the plan is mid-flight

  A plan still in `:prepared`, `:signing`, `:broadcasting`, or
  `:pending_confirmation` just snoozes. `max_attempts: 20` keeps the
  total wait bounded.

  ## Idempotency

  If the intent is already in the expected final state (which is the
  common case, because the callback controller got there first), the
  worker returns `{:cancel, :already_finalised}` — two confirms for
  the same plan do not double-write audit events.

  ## Retry posture

    * `:ok` on a successful intent transition.
    * `{:snooze, 30}` while the plan is mid-flight.
    * `{:cancel, reason}` for `:not_found`, `:already_finalised`,
      `:intent_not_found`.
    * `{:error, reason}` for transient failure; Oban retries with
      backoff.
  """

  use Oban.Worker,
    queue: :executions_confirm,
    max_attempts: 20

  import Ecto.Query

  alias Bank.Audit.Events
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime
  alias Bank.Runtime.Notifier

  require Logger

  @snooze_seconds 30

  # Mirrors `Bank.Decisions.advance_intent_for_kind/3` — the only
  # legitimate prior states for an `execution.*` finalisation. Other
  # states (`:cancelled`, `:expired`, etc.) reflect a different
  # operator/runtime decision and must NOT be overwritten by this
  # safety-net poller.
  @finalisable_prior_states [:executing, :decided]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"execution_plan_id" => plan_id}}) do
    case Repo.get(ExecutionPlan, plan_id) do
      nil ->
        {:cancel, :not_found}

      %ExecutionPlan{execution_status: status, final_outcome: final} = plan
      when status in [:confirmed, :reverted, :aborted] and not is_nil(final) ->
        finalise(plan)

      %ExecutionPlan{execution_status: status} ->
        Logger.debug("ConfirmExecution: plan #{plan_id} at #{status}; snoozing")
        {:snooze, @snooze_seconds}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("ConfirmExecution: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end

  # Guarded by the perform/1 pattern match — only called with terminal
  # status + set final_outcome.
  #
  # The intent row is locked `FOR UPDATE` inside a transaction so a
  # concurrent `Bank.Decisions.apply_execution_callback/1` (the
  # primary-path writer) cannot race the safety-net poller and
  # produce duplicate `intent.state_changed` audit rows or duplicate
  # PubSub broadcasts. After acquiring the lock we re-pattern-match
  # the locked row:
  #
  #   * intent already at `target_state` → no write, no audit, no
  #     broadcast (safety-net was beaten by the callback path).
  #   * intent in a non-finalisable state (`:cancelled`, `:expired`,
  #     etc.) → leave it alone; this safety-net must never overwrite
  #     a different operator/runtime decision.
  #   * intent in `:executing` / `:decided` → atomic update + audit
  #     inside the transaction; PubSub broadcasts emitted post-commit.
  defp finalise(%ExecutionPlan{} = plan) do
    target_state = target_intent_state(plan.final_outcome)

    Repo.transaction(fn ->
      case lock_intent(plan.intent_id) do
        nil ->
          Repo.rollback(:intent_not_found)

        %AgentIntent{state: ^target_state} ->
          Repo.rollback(:already_finalised)

        %AgentIntent{state: state} = intent when state in @finalisable_prior_states ->
          apply_finalisation_in_txn(intent, plan, target_state)

        %AgentIntent{state: state} ->
          Repo.rollback({:stale_intent_state, state})
      end
    end)
    |> case do
      {:ok, {updated_intent, prior_state}} ->
        # PubSub broadcasts are intentionally outside the
        # transaction: subscribers should only see them after the
        # write is durably committed. The audit row itself was
        # written inside the txn so it cannot be observed without
        # the state transition.
        Notifier.execution_progressed(plan, plan.execution_status)

        Notifier.intent_lifecycle(updated_intent, :state_changed, %{
          from: prior_state,
          to: target_state,
          execution_plan_id: plan.id
        })

        :ok

      {:error, :intent_not_found} ->
        {:cancel, :intent_not_found}

      {:error, :already_finalised} ->
        {:cancel, :already_finalised}

      {:error, {:stale_intent_state, state}} ->
        Logger.warning(
          "ConfirmExecution: intent #{plan.intent_id} in unexpected state " <>
            "#{inspect(state)}; refusing to overwrite from safety-net"
        )

        {:cancel, {:stale_intent_state, state}}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error(
          "ConfirmExecution: intent update failed for #{plan.intent_id}: " <>
            inspect(changeset.errors)
        )

        {:error, changeset}

      {:error, other} ->
        {:error, other}
    end
  end

  defp lock_intent(intent_id) do
    Repo.one(
      from(i in AgentIntent,
        where: i.id == ^intent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp apply_finalisation_in_txn(intent, plan, target_state) do
    with {:ok, updated_intent} <-
           intent
           |> AgentIntent.current_pointer_changeset(%{
             state: target_state,
             current_execution_plan_id: plan.id
           })
           |> Repo.update(),
         {:ok, _audit} <-
           Runtime.emit_audit(
             Events.intent_state_changed(updated_intent, intent.state, target_state)
           ) do
      # Return the prior state alongside the updated struct so the
      # post-commit PubSub broadcast can report the correct `from:`
      # without a second DB read.
      {updated_intent, intent.state}
    else
      {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp target_intent_state(:confirmed), do: :executed
  defp target_intent_state(:reverted), do: :blocked
  defp target_intent_state(:aborted), do: :blocked
end
