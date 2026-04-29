defmodule Bank.Runtime.Workers.ReevaluateIntent do
  @moduledoc """
  Re-evaluation of an intent in response to a trigger — hold TTL
  firing, policy revision, trust downgrade, stale simulation.

  Delegates to `Bank.Decisions.evaluate_intent/2`. The facade demotes
  the prior current trust / simulation / decision rows and inserts
  successors with `supersedes_id` pointing at them, so replay shows
  the full chain of evaluations the runtime performed.

  Re-eval targets are intents that already have at least one decision
  — `state in [:decided, :blocked]`. `:executing` and `:executed` are
  excluded because supersession after execution would need the
  adapter to be part of the decision; `:cancelled` and `:expired`
  are terminal.

  ## Retry posture

  Same as `EvaluateIntent`: `{:cancel, reason}` for deterministic
  don't-retry outcomes, `{:error, reason}` for transient infrastructure
  failures.
  """

  use Oban.Worker,
    queue: :intents_reevaluate,
    max_attempts: 5

  alias Bank.Decisions
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

      %AgentIntent{state: state} = intent when state in @valid_source_states ->
        run(intent, reason)

      %AgentIntent{state: state} ->
        Logger.info("ReevaluateIntent: #{intent_id} in #{state}; not re-evaluable")
        {:cancel, {:wrong_state, state}}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("ReevaluateIntent: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end

  defp run(%AgentIntent{} = intent, reason) do
    case Decisions.evaluate_intent(intent, reason: reason) do
      {:ok, %{outcome: outcome, decision: envelope}} ->
        Logger.info(
          "ReevaluateIntent: #{intent.id} (reason=#{reason}) -> #{outcome} " <>
            "(envelope=#{envelope.id})"
        )

        :ok

      {:error, :not_found} ->
        Logger.warning("ReevaluateIntent: intent #{intent.id} disappeared mid-evaluation")
        {:cancel, :not_found}

      {:error, {:wrong_state, state}} ->
        Logger.info("ReevaluateIntent: #{intent.id} raced into state #{state}; cancelling")
        {:cancel, {:wrong_state, state}}

      {:error, reason} ->
        Logger.error("ReevaluateIntent: #{intent.id} re-evaluation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
