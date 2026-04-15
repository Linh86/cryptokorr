defmodule Bank.Runtime.Workers.RunExecution do
  @moduledoc """
  Hand a decided, auto-executable envelope off to the TypeScript
  chain adapter.

  The adapter is a separate service that isn't wired in issue #6, so
  this worker stops at a safe boundary. It:

    1. Loads the decision envelope by id.
    2. Confirms it's the current envelope for the intent, in
       `outcome: :auto_exec, state: :decided`.
    3. Cancels with `:adapter_pending`. No plan is written, no
       intent state changes.

  Writing an `ExecutionPlan` skeleton here without the adapter would
  either block on a placeholder `smart_account_id` (which doesn't
  round-trip to a real account) or stall the execution queue with
  plans that can never progress.

  ## Retry posture

    * `{:cancel, :adapter_pending}` — expected while the adapter is
      un-wired. Deterministic, no retry.
    * `{:cancel, :not_found}` — decision envelope id doesn't resolve.
    * `{:cancel, {:not_current, ...}}` — a newer envelope supersedes
      this one; the old decision shouldn't be executed.
    * `{:cancel, {:wrong_outcome, outcome}}` — the envelope's outcome
      isn't `:auto_exec`; caller bug.
    * `{:error, reason}` — transient infrastructure; standard Oban
      retry.
  """

  use Oban.Worker,
    queue: :executions_run,
    max_attempts: 5

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"decision_id" => decision_id}}) do
    case Repo.get(DecisionEnvelope, decision_id) do
      nil ->
        Logger.warning("RunExecution: decision #{decision_id} not found")
        {:cancel, :not_found}

      %DecisionEnvelope{current: false} ->
        {:cancel, :not_current}

      %DecisionEnvelope{outcome: :auto_exec, state: :decided, intent_id: intent_id} ->
        Logger.info(
          "RunExecution: decision #{decision_id} (intent #{intent_id}) ready; adapter not wired"
        )

        {:cancel, :adapter_pending}

      %DecisionEnvelope{outcome: outcome} ->
        {:cancel, {:wrong_outcome, outcome}}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("RunExecution: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end
end
