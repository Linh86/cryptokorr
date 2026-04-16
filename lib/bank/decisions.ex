defmodule Bank.Decisions do
  @moduledoc """
  Decisions bounded context.

  Owns the `DecisionEnvelope` lifecycle and the approval state machine
  that produces successor envelopes rather than editing them.

  The fixed v1 outcome vocabulary is `auto_exec`, `hold`,
  `approval_required`, `block`. The fixed v1 risk vocabulary is `low`,
  `moderate`, `elevated`, `severe`. Both are owned here to keep the
  decision surface small and explicit.

  Public surface scope in v0.1:

    * write an envelope (called by the evaluation pipeline in
      `Bank.Runtime` once policy / trust / simulation inputs are
      ready)
    * read an envelope with its supersession chain
    * approve / reject a pending `approval_required` envelope — both
      write a successor envelope rather than mutating the original
    * arm the approval TTL timer (enqueued on `approvals.expire`) and
      the hold TTL timer (enqueued on `intents.reevaluate`)

  Trust assessments and simulation reports are inputs the decision engine
  consumes; they live under `Bank.Runtime` with the workflow code that
  produces them.
  """
end
