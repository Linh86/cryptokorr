defmodule Bank do
  @moduledoc """
  Bank v0.1 — non-custodial AI treasury runtime.

  This application is the Phoenix control plane: it accepts agent
  intents, evaluates policy, consults trust and simulation inputs,
  writes decisions, manages approvals, and orchestrates execution
  through a separate TypeScript chain-adapter service. Postgres is the
  source of truth; Oban runs the background workflows; PubSub drives
  realtime updates to the web control tower.

  ## Bounded contexts

    * `Bank.Intents`         — `AgentIntent` lifecycle and submission path.
    * `Bank.Counterparties`  — counterparties, address labels, evidence,
      and operator-issued trust assertions.
    * `Bank.Policies`        — versioned `PolicyRule` catalog and
      evaluation snapshots.
    * `Bank.Decisions`       — `DecisionEnvelope` writing and the
      approval state machine.
    * `Bank.Audit`           — append-only `AuditEvent` stream and
      per-intent replay bundles.
    * `Bank.Runtime`         — workflow orchestration (Oban queues) and
      realtime fan-out (PubSub topics).
    * `Bank.Security`        — pause / resume and delegation revocation.

  Contexts talk to each other through narrow public functions. They do
  not reach into each other's schemas. This is the boundary that keeps
  the control plane legible as the engines (issues #6+) fill in.

  ## What lives here vs. in the adapter

  Phoenix (this app) is the decision authority. It owns policy, trust,
  simulation orchestration, decisioning, approvals, audit, pause, and
  the external `/v1/` API.

  The TypeScript adapter is the chain-execution specialist. It wraps
  simulation providers, bundlers / RPC, and wallet / smart-account
  behavior; it receives `ExecutionPlan` skeletons from Phoenix, fills
  in chain-specific step details, signs via the configured delegation,
  broadcasts, and reports outcomes back. It never decides.

  The two talk over a private internal contract that is not part of
  `/v1/`. Failure in the adapter widens caution in Phoenix — it never
  widens autonomy.
  """
end
