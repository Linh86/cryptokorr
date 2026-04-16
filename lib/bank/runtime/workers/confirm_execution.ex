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

  alias Bank.Audit.Events
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime
  alias Bank.Runtime.Notifier

  require Logger

  @snooze_seconds 30

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
  defp finalise(%ExecutionPlan{} = plan) do
    target_state = target_intent_state(plan.final_outcome)

    case Repo.get(AgentIntent, plan.intent_id) do
      nil ->
        {:cancel, :intent_not_found}

      %AgentIntent{state: ^target_state} ->
        {:cancel, :already_finalised}

      %AgentIntent{} = intent ->
        apply_finalisation(intent, plan, target_state)
    end
  end

  defp apply_finalisation(intent, plan, target_state) do
    case intent
         |> AgentIntent.current_pointer_changeset(%{
           state: target_state,
           current_execution_plan_id: plan.id
         })
         |> Repo.update() do
      {:ok, updated_intent} ->
        # Sanity: we only touched the intent row; the plan keeps the
        # terminal state the adapter already wrote. No double-write.
        Runtime.emit_audit(
          Events.intent_state_changed(updated_intent, intent.state, target_state)
        )

        Notifier.execution_progressed(plan, plan.execution_status)

        Notifier.intent_lifecycle(updated_intent, :state_changed, %{
          from: intent.state,
          to: target_state,
          execution_plan_id: plan.id
        })

        :ok

      {:error, changeset} ->
        Logger.error(
          "ConfirmExecution: intent update failed for #{intent.id}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  defp target_intent_state(:confirmed), do: :executed
  defp target_intent_state(:reverted), do: :blocked
  defp target_intent_state(:aborted), do: :blocked
end
