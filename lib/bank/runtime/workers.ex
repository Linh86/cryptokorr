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
  | `Bank.Runtime.Workers.RunExecution`     | `:executions_run`     | `executions.run`     | Safe boundary — adapter hand-off is the work, and the adapter lives in a separate service that is not wired yet. Cancels with `:adapter_pending`. |
  | `Bank.Runtime.Workers.ConfirmExecution` | `:executions_confirm` | `executions.confirm` | **Real transition** when the adapter has already reported a terminal plan state (plan test hook); otherwise snoozes. Without the adapter, production runs never reach terminal — that's the correct behaviour. |
  | `Bank.Runtime.Workers.RevokeDelegation` | `:security_revoke`    | `security.revoke`    | Partial — broadcasts `security:events` so operators see the request, cancels with `:adapter_pending` because the revoke tx itself lives behind the adapter. |

  ## Retry posture

  The rule is **failure widens caution, never autonomy**: a worker
  that cannot complete because downstream capability is missing must
  not retry its way to success. So:

    * Transient infrastructure errors (DB unreachable, PubSub
      momentarily down) return `{:error, reason}` and retry with
      Oban's default exponential backoff.
    * Safe-boundary conditions (engine not built, adapter not wired)
      return `{:cancel, reason}` — the job is marked cancelled with
      the reason visible in the Oban web UI; no retry, no state
      mutation.
    * Permanent input errors (intent / envelope not found, wrong
      state) return `{:cancel, reason}` as well — retrying is
      pointless and would mask operator mistakes.
    * Polling workers (`ConfirmExecution`) use `{:snooze, seconds}`
      to come back later without burning an attempt.

  Each worker's moduledoc spells out its own retry decisions.
  """
end
