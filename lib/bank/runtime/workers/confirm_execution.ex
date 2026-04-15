defmodule Bank.Runtime.Workers.ConfirmExecution do
  @moduledoc """
  Poll a given execution plan and apply its intent-level effect when
  the plan reaches a terminal state.

  The adapter owns the plan's own lifecycle (prepared → signing →
  broadcasting → pending_confirmation → confirmed | reverted |
  aborted) and writes each progression to the row. This worker is
  the piece that reacts to the plan *reaching a terminal state* and
  finalises the intent:

    * `final_outcome: :confirmed` → intent `:executing` → `:executed`
    * `final_outcome: :reverted`  → intent `:executing` → `:blocked`
    * `final_outcome: :aborted`   → intent `:executing` → `:blocked`

  ### With the adapter

  When the adapter is wired, this worker polls: it snoozes itself
  while the plan is still mid-flight, and on a subsequent run — once
  the adapter has written the terminal state — it applies the intent
  transition exactly once.

  ### Without the adapter (issue #6 today)

  A plan will sit in `:prepared` forever unless a test / fixture
  writes a terminal state directly. The worker recognises that case
  and cancels with `:adapter_pending` so the job doesn't burn forever
  in a snooze loop.

  ## Idempotency

  If the intent is already in the expected final state, the worker
  returns `{:cancel, :already_finalised}` — two confirms for the same
  plan do not double-write audit events.

  ## Retry posture

    * `:ok` on successful intent transition.
    * `{:snooze, 30}` while the plan is mid-flight; `max_attempts:
      20` caps the total wait at ~10 minutes before Oban discards.
    * `{:cancel, reason}` for `:not_found`, `:adapter_pending`,
      `:already_finalised`, wrong execution status.
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

      %ExecutionPlan{execution_status: :prepared} = plan ->
        Logger.info(
          "ConfirmExecution: plan #{plan.id} still :prepared; adapter not wired, cancelling"
        )

        {:cancel, :adapter_pending}

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
