defmodule Bank.Security do
  @moduledoc """
  Security bounded context.

  Owns operator-facing safety controls: pause, resume, and delegation
  revocation.

  Semantics (per runtime-flow doc):

    * Pause is soft. A global pause halts new `executing` transitions
      but does not drop inbound intents or suppress decision-writing.
      Agents may still submit; decisions may still be written; nothing
      enters `executing` while paused.
    * Resume does not auto-flush queued intents into execution — each
      still needs a decision event or a manual
      `POST /v1/decisions/{id}/execute`.
    * Revoke delegation is one-way at the API. Re-delegation is an
      operator flow in the web console, out of external-API scope.

  Public surface scope in v0.1:

    * current pause state (global and per-counterparty)
    * apply / lift pause
    * dispatch a delegation revoke to the chain adapter via the
      `security.revoke` queue; final state change arrives async and is
      delivered through the `security:events` PubSub topic and audit

  This module talks to `Bank.Runtime` for queue handoff and to
  `Bank.Audit` for event emission. Chain-side revocation mechanics
  live in the TypeScript adapter, not here.
  """
end
