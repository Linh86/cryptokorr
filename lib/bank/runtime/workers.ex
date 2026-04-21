defmodule Bank.Runtime.Workers do
  @moduledoc """
  Namespace for Oban worker modules that drive the runtime workflows.

  Queue names are declared in `config/config.exs`. Each worker below
  `use Oban.Worker, queue: ...` with one of those names, performs a
  focused job, and returns the idiomatic Oban result tuple.

  ## Worker catalogue

  | Module                                  | Queue (atom)          | Semantic name        | Status (issue #6) |
  |-----------------------------------------|-----------------------|----------------------|-------------------|
  | `Bank.Runtime.Workers.EvaluateIntent`   | `:intents_evaluate`   | `intents.evaluate`   | Safe boundary — verifies intent is evaluable, cancels with `:engines_pending`. Policy / trust / simulation engines ship in issues #7-#9. |
  | `Bank.Runtime.Workers.ReevaluateIntent` | `:intents_reevaluate` | `intents.reevaluate` | Safe boundary — same engines gate. Carries `reason` so operator sees why the re-eval was requested. |
  | `Bank.Runtime.Workers.ExpireApproval`   | `:approvals_expire`   | `approvals.expire`   | **Real transition.** Flips prior envelope `current: false`, writes block successor, updates intent state, emits audit + PubSub. Pure DB work — no engine needed. |
  | `Bank.Runtime.Workers.RunExecution`     | `:executions_run`     | `executions.run`     | **Real adapter dispatch.** Re-validates the envelope, active plan, delegation, and pause gate. Accepted dispatch advances the plan to `:signing`; rejected or unresolvable paths abort locally and stop. |
  | `Bank.Runtime.Workers.ConfirmExecution` | `:executions_confirm` | `executions.confirm` | **Safety-net reconciliation.** Adapter callbacks normally progress plan + intent atomically; this worker only finalises the intent if a terminal plan exists without the matching lifecycle write, and snoozes while the plan is mid-flight. |
  | `Bank.Runtime.Workers.RevokeDelegation` | `:security_revoke`    | `security.revoke`    | **Real adapter dispatch.** Broadcasts the revoke request, writes `security.revoke_requested`, dispatches the revoke through the adapter, and relies on callbacks for the final delegation state changes. |

  ## Retry posture

  The rule is **failure widens caution, never autonomy**: a worker
  that cannot complete because downstream capability is missing must
  not retry its way to success. So:

    * Transient infrastructure errors (DB unreachable, adapter
      unavailable, callback-side write failure) return `{:error,
      reason}` and retry with Oban's default exponential backoff.
    * Safe-boundary conditions (the policy / trust / simulation
      pipeline is not wired yet) return `{:cancel, reason}` — the
      job is marked cancelled with the reason visible in the Oban
      web UI; no retry, no state mutation.
    * Deterministic terminal outcomes (intent / envelope not found,
      wrong state, adapter rejection, already finalised) return
      `{:cancel, reason}` as well — retrying is pointless and would
      mask operator mistakes.
    * Reconciliation workers (`ConfirmExecution`) use
      `{:snooze, seconds}` to come back later without burning an
      attempt while a plan is still mid-flight.

  Each worker's moduledoc spells out its own retry decisions.
  """
end
