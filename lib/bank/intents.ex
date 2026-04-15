defmodule Bank.Intents do
  @moduledoc """
  Intents bounded context.

  Owns the `AgentIntent` lifecycle: `submitted → evaluating → decided →
  (executing → executed) | blocked | cancelled | expired`. Accepts agent
  submissions, applies idempotency-key dedupe, and coordinates the
  evaluation pipeline by enqueueing work on the `intents.evaluate` queue
  (see `Bank.Runtime`).

  Public surface scope in v0.1:

    * accept an intent (create + persist + enqueue evaluation)
    * look up an intent and its linked decision / simulation / plan
    * operator cancellation (pre-execution)
    * replay bundle assembly (delegates to `Bank.Audit`)

  This module is the facade. Schemas, changesets, and query logic arrive
  with issue #4. Evaluation, simulation, and decisioning belong to
  `Bank.Policies`, `Bank.Decisions`, and `Bank.Runtime` — not here.
  """
end
