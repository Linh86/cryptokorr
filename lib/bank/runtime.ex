defmodule Bank.Runtime do
  @moduledoc """
  Runtime orchestration bounded context.

  The connective tissue between the other contexts: it enqueues async
  work through Oban, fans out realtime updates through PubSub, and
  composes `Bank.Audit` writes with the realtime audit stream so
  listeners see the same event the DB saw.

  This module is intentionally a thin, explicit API — no generic
  "dispatch anything" abstraction. Each public function maps onto a
  concrete runtime stage. Future engine issues (decision, approval,
  execution) call these primitives rather than reaching into Oban or
  PubSub directly.

  ## Workflow orchestration (Oban)

  One enqueue function per queue. Args are always a flat map with
  string-typed atoms so Oban can serialise them, plus stable ids the
  worker can look up (`intent_id`, `decision_id`,
  `execution_plan_id`, `smart_account_id`). All enqueue functions
  return `{:ok, %Oban.Job{}}` or `{:error, reason}` so the caller
  (HTTP controller, sibling context) can decide whether to surface a
  failure to the user.

    * `enqueue_evaluation/2` — initial intent evaluation
    * `enqueue_reevaluation/3` — trigger-driven re-evaluation
    * `enqueue_approval_expiry/2` — scheduled TTL firing
    * `enqueue_execution/2` — hand a decided envelope to execution
    * `enqueue_confirmation/2` — poll chain confirmation state
    * `enqueue_delegation_revoke/3` — security revoke dispatch

  ## Realtime fan-out (PubSub)

  Topic strings and subscription live in `Bank.Runtime.PubSub`;
  message shapes live in `Bank.Runtime.Notifier`. This module exposes
  a small number of top-level helpers (`broadcast_*`) that forward
  into the notifier — callers that are already holding the domain
  object can go straight to the notifier if they prefer.

  ## Audit fan-out

  `emit_audit/1` is the composition seam between `Bank.Audit` and the
  realtime stream. It writes via `Bank.Audit.append_event/1` and, on
  successful insert, broadcasts a compact summary to
  `audit:stream`. `Bank.Audit` itself stays pure — direct callers that
  don't want the broadcast (tests, backfill scripts) can still use
  `Bank.Audit.append_event/1` on its own.

  ## Not owned here

    * Schema / changeset definitions live in each domain context.
    * Operator write paths (CRUD for counterparties, policies, trust)
      live in the owning context.
    * Chain-specific execution lives in the TypeScript adapter, which
      is a separate service — this module exchanges plans and
      outcomes with it over a private internal contract, not over
      `/v1/`.
  """

  alias Bank.Audit
  alias Bank.Audit.AuditEvent
  alias Bank.Runtime.Notifier

  alias Bank.Runtime.Workers.{
    ConfirmExecution,
    EvaluateIntent,
    ExpireApproval,
    ReevaluateIntent,
    RevokeDelegation,
    RunExecution
  }

  @type uuid :: String.t()
  @type job_result :: {:ok, Oban.Job.t()} | {:error, term()}

  # --- Enqueue API ------------------------------------------------------

  @doc """
  Enqueue the initial evaluation of a freshly-submitted intent.

  Accepts extra `opts` that forward to `Oban.Job.new/2`; most callers
  only need the intent id. Returns `{:ok, %Oban.Job{}}`.
  """
  @spec enqueue_evaluation(uuid(), keyword()) :: job_result()
  def enqueue_evaluation(intent_id, opts \\ []) when is_binary(intent_id) do
    %{intent_id: intent_id}
    |> EvaluateIntent.new(opts)
    |> Oban.insert()
  end

  @doc """
  Enqueue a re-evaluation of an existing intent. `reason` is a short
  atom that describes the trigger (`:hold_expired`, `:policy_changed`,
  `:trust_changed`, `:simulation_stale`); it's carried in the job args
  for operator visibility.
  """
  @spec enqueue_reevaluation(uuid(), atom(), keyword()) :: job_result()
  def enqueue_reevaluation(intent_id, reason, opts \\ [])
      when is_binary(intent_id) and is_atom(reason) do
    %{intent_id: intent_id, reason: Atom.to_string(reason)}
    |> ReevaluateIntent.new(opts)
    |> Oban.insert()
  end

  @doc """
  Schedule the approval-TTL job for a `:approval_required` decision
  envelope. `expires_at` is the absolute wall-clock instant the
  approval window closes — the job is scheduled to run at that time
  so a crashed worker doesn't let the deadline slip silently.
  """
  @spec enqueue_approval_expiry(uuid(), DateTime.t(), keyword()) :: job_result()
  def enqueue_approval_expiry(decision_envelope_id, %DateTime{} = expires_at, opts \\ [])
      when is_binary(decision_envelope_id) do
    opts = Keyword.put_new(opts, :scheduled_at, expires_at)

    %{decision_envelope_id: decision_envelope_id}
    |> ExpireApproval.new(opts)
    |> Oban.insert()
  end

  @doc """
  Enqueue an execution run for a decided, auto-executable envelope.
  """
  @spec enqueue_execution(uuid(), keyword()) :: job_result()
  def enqueue_execution(decision_id, opts \\ []) when is_binary(decision_id) do
    %{decision_id: decision_id}
    |> RunExecution.new(opts)
    |> Oban.insert()
  end

  @doc """
  Enqueue a confirmation poll for an execution plan. `opts` can
  include `:scheduled_at` or `:schedule_in` to control when the first
  poll fires; the worker snoozes itself on subsequent polls until the
  plan reaches a terminal state.
  """
  @spec enqueue_confirmation(uuid(), keyword()) :: job_result()
  def enqueue_confirmation(execution_plan_id, opts \\ []) when is_binary(execution_plan_id) do
    %{execution_plan_id: execution_plan_id}
    |> ConfirmExecution.new(opts)
    |> Oban.insert()
  end

  @doc """
  Enqueue a delegation-revoke dispatch for a smart account. `reason`
  is operator-facing (e.g. `:operator_requested`, `:agent_offboarded`,
  `:pause_policy`).
  """
  @spec enqueue_delegation_revoke(String.t(), atom(), keyword()) :: job_result()
  def enqueue_delegation_revoke(smart_account_id, reason, opts \\ [])
      when is_binary(smart_account_id) and is_atom(reason) do
    %{smart_account_id: smart_account_id, reason: Atom.to_string(reason)}
    |> RevokeDelegation.new(opts)
    |> Oban.insert()
  end

  # --- Audit composition ------------------------------------------------

  @doc """
  Persist an audit event *and* fan it out to `audit:stream`. Returns
  the same shape as `Bank.Audit.append_event/1`.

  Direct callers that don't want the broadcast (backfills, tests
  exercising persistence alone) can still use `Bank.Audit.append_event/1`
  straight.
  """
  @spec emit_audit(map() | keyword()) ::
          {:ok, AuditEvent.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:missing_fields, [atom()]}}
  def emit_audit(attrs) do
    with {:ok, event} <- Audit.append_event(attrs) do
      Notifier.audit_stream(event)
      {:ok, event}
    end
  end

  # --- Broadcast helpers ------------------------------------------------

  @doc "Forward to `Bank.Runtime.Notifier.intent_lifecycle/3`."
  defdelegate broadcast_intent_lifecycle(intent_or_id, event, payload \\ %{}),
    to: Notifier,
    as: :intent_lifecycle

  @doc "Forward to `Bank.Runtime.Notifier.approval_queue/3`."
  defdelegate broadcast_approval_queue(event, envelope, payload \\ %{}),
    to: Notifier,
    as: :approval_queue

  @doc "Forward to `Bank.Runtime.Notifier.dashboard_status/2`."
  defdelegate broadcast_dashboard_status(event, payload \\ %{}),
    to: Notifier,
    as: :dashboard_status

  @doc "Forward to `Bank.Runtime.Notifier.security_event/2`."
  defdelegate broadcast_security_event(event, payload \\ %{}),
    to: Notifier,
    as: :security_event
end
