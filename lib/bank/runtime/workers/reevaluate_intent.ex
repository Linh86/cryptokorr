defmodule Bank.Runtime.Workers.ReevaluateIntent do
  @moduledoc """
  Re-evaluation of an intent in response to a trigger — hold TTL
  firing, policy revision, trust downgrade, stale simulation.

  Same engines gate as `EvaluateIntent`: the decision pipeline lives
  in issues #7-#9, so this worker currently verifies the intent is a
  valid re-evaluation target and cancels with `:engines_pending`.
  `reason` is preserved in the job args — an operator reading the
  Oban dashboard can see why the runtime asked for a re-eval even
  though nothing wrote a new envelope.

  Re-eval targets are intents that already have at least one decision
  — i.e. `state in [:decided, :blocked]`. `:executing` and `:executed`
  are excluded because supersession after execution would need the
  adapter to be part of the decision.

  ## Retry posture

  Same as `EvaluateIntent`: `{:cancel, reason}` for deterministic
  don't-retry outcomes, `{:error, reason}` for transient
  infrastructure failures.
  """

  use Oban.Worker,
    queue: :intents_reevaluate,
    max_attempts: 5

  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  require Logger

  @valid_source_states [:decided, :blocked]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"intent_id" => intent_id} = args}) do
    reason = Map.get(args, "reason", "unspecified")

    case Repo.get(AgentIntent, intent_id) do
      nil ->
        Logger.warning("ReevaluateIntent: intent #{intent_id} not found")
        {:cancel, :not_found}

      %AgentIntent{state: state} when state in @valid_source_states ->
        Logger.info("ReevaluateIntent: #{intent_id} (reason=#{reason}); engines not built yet")
        {:cancel, :engines_pending}

      %AgentIntent{state: state} ->
        Logger.info("ReevaluateIntent: #{intent_id} in #{state}; not re-evaluable")
        {:cancel, {:wrong_state, state}}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("ReevaluateIntent: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end
end
