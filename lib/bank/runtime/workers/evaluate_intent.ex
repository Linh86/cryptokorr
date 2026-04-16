defmodule Bank.Runtime.Workers.EvaluateIntent do
  @moduledoc """
  Initial evaluation of a freshly-submitted agent intent.

  In the eventual runtime this worker stages policy evaluation,
  trust derivation, and simulation, then writes the first
  `DecisionEnvelope`. Those engines (issues #7-#9) do not exist yet,
  so today the worker stops at a safe boundary: it verifies the
  intent is in a state that can be evaluated and cancels with
  `:engines_pending`, without mutating state.

  The alternative (advance the intent into `:evaluating`) would lie
  — no one is in fact evaluating it — and would leave intents
  stranded if issue #7 reshapes the stage semantics.

  ## Retry posture

    * `{:cancel, :engines_pending}` — expected every run until the
      engines land. Deterministic, visible in the Oban dashboard, no
      retry.
    * `{:cancel, :not_found}` — intent id doesn't resolve. Retrying
      wouldn't help.
    * `{:cancel, {:wrong_state, state}}` — the intent has already
      moved past `:submitted`; something else already ran an
      evaluation or the intent was cancelled. Retrying would be
      wrong.
    * `{:error, reason}` — genuine infrastructure failure (DB
      unavailable). Standard Oban retry with backoff.
  """

  use Oban.Worker,
    queue: :intents_evaluate,
    max_attempts: 5

  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"intent_id" => intent_id}}) do
    case Repo.get(AgentIntent, intent_id) do
      nil ->
        Logger.warning("EvaluateIntent: intent #{intent_id} not found")
        {:cancel, :not_found}

      %AgentIntent{state: :submitted} ->
        Logger.info("EvaluateIntent: #{intent_id} queued; engines not built yet")
        {:cancel, :engines_pending}

      %AgentIntent{state: state} ->
        Logger.info("EvaluateIntent: #{intent_id} already in #{state}; skipping")
        {:cancel, {:wrong_state, state}}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("EvaluateIntent: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end
end
