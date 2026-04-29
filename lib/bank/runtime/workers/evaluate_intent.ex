defmodule Bank.Runtime.Workers.EvaluateIntent do
  @moduledoc """
  Initial evaluation of a freshly-submitted agent intent.

  Delegates to `Bank.Decisions.evaluate_intent/2`, which composes the
  trust engine, the policy engine, the quote/simulation provider, and
  the autonomy router and persists the resulting `TrustAssessment`,
  `SimulationReport`, and `DecisionEnvelope` rows in one
  `Ecto.Multi` together with the intent's current-pointer update.

  Execution dispatch is intentionally NOT triggered here. An
  `:auto_exec` decision is recorded but no `RunExecution` job is
  enqueued — that wiring is owned by issue #137.

  ## Retry posture

    * `:ok`                    — evaluation ran; the intent is now
      `:decided` (auto_exec / hold / approval_required) or
      `:blocked`. Deterministic and idempotent against the supersession
      chain on each child row.
    * `{:cancel, :not_found}`  — intent id doesn't resolve. Retrying
      wouldn't help.
    * `{:cancel, {:wrong_state, state}}` — the intent is already past
      the evaluation step (`:decided`, `:blocked`, `:executing`,
      `:executed`, `:cancelled`, `:expired`). Re-evaluation goes
      through `ReevaluateIntent`, not this worker.
    * `{:error, reason}` — genuine infrastructure failure (DB
      unavailable). Standard Oban retry with backoff.
  """

  use Oban.Worker,
    queue: :intents_evaluate,
    max_attempts: 5

  alias Bank.Decisions
  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  require Logger

  @valid_initial_states [:submitted, :evaluating]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"intent_id" => intent_id}}) do
    case Repo.get(AgentIntent, intent_id) do
      nil ->
        Logger.warning("EvaluateIntent: intent #{intent_id} not found")
        {:cancel, :not_found}

      %AgentIntent{state: state} = intent when state in @valid_initial_states ->
        run(intent)

      %AgentIntent{state: state} ->
        Logger.info("EvaluateIntent: #{intent_id} already in #{state}; skipping")
        {:cancel, {:wrong_state, state}}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("EvaluateIntent: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end

  defp run(%AgentIntent{} = intent) do
    case Decisions.evaluate_intent(intent) do
      {:ok, %{outcome: outcome, decision: envelope}} ->
        Logger.info("EvaluateIntent: #{intent.id} -> #{outcome} (envelope=#{envelope.id})")

        :ok

      {:error, :not_found} ->
        Logger.warning("EvaluateIntent: intent #{intent.id} disappeared mid-evaluation")
        {:cancel, :not_found}

      {:error, {:wrong_state, state}} ->
        Logger.info("EvaluateIntent: #{intent.id} raced into state #{state}; cancelling")
        {:cancel, {:wrong_state, state}}

      {:error, reason} ->
        Logger.error("EvaluateIntent: #{intent.id} evaluation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
