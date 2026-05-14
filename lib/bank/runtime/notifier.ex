defmodule Bank.Runtime.Notifier do
  @moduledoc """
  Typed broadcast helpers for the runtime realtime contract.

  `Bank.Runtime.PubSub` owns the topic strings; this module owns the
  *message shapes*. Every broadcast message is a map with a fixed
  skeleton so LiveViews, channels, and future subscribers can
  pattern-match without re-deriving the envelope per caller:

      %{
        topic: <atom>,          # which contract this message belongs to
        event: <atom>,          # specific transition (e.g. :expired)
        at: %DateTime{},        # runtime wall clock for the broadcast
        ...                     # topic-specific payload fields
      }

  This module never reads the DB or writes audit; its single
  responsibility is pushing a pre-shaped message onto a topic. The
  caller (usually a worker or the `Bank.Runtime` public API) has
  already done the persistence.

  ## Topic contract

    * `intent:{id}`             — `intent_lifecycle/3`
    * `approval:queue`          — `approval_queue/3`
    * `dashboard:runtime_status` — `dashboard_status/2`
    * `security:events`         — `security_event/2`
    * `audit:stream`            — `audit_stream/1`

  """

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.PubSub

  @type event :: atom()
  @type payload :: map()
  @type message :: %{
          required(:topic) => atom(),
          required(:event) => atom(),
          required(:at) => DateTime.t(),
          optional(atom()) => any()
        }

  # --- intent:{id} -------------------------------------------------------

  @doc """
  Broadcast a lifecycle transition for a specific intent.

  Typical `event` values:

    * `:state_changed` — intent-level state changed
    * `:decision_updated` — a new decision envelope is current
    * `:execution_updated` — execution plan progressed / finalised
    * `:evaluation_deferred` — a stage could not progress (engine pending)
  """
  @spec intent_lifecycle(AgentIntent.t() | String.t(), event(), payload()) ::
          :ok | {:error, term()}
  def intent_lifecycle(intent_or_id, event, payload \\ %{})

  def intent_lifecycle(%AgentIntent{id: id, state: state}, event, payload) when is_atom(event) do
    do_broadcast_intent(id, event, Map.put_new(payload, :state, state))
  end

  def intent_lifecycle(intent_id, event, payload) when is_binary(intent_id) and is_atom(event) do
    do_broadcast_intent(intent_id, event, payload)
  end

  defp do_broadcast_intent(intent_id, event, payload) do
    PubSub.broadcast(
      PubSub.intent(intent_id),
      %{
        topic: :intent_lifecycle,
        event: event,
        intent_id: intent_id,
        at: DateTime.utc_now(),
        payload: payload
      }
    )
  end

  # --- approval:queue ----------------------------------------------------

  @doc """
  Broadcast an approval queue transition. `event` is one of:

    * `:enqueued` — a new `:approval_required` envelope entered the queue
    * `:expired` — approval TTL fired; the envelope has been superseded
      by a `:block` successor
    * `:granted` — operator approved; successor `:auto_exec` envelope
      written
    * `:rejected` — operator rejected; successor `:block` envelope written

  The message always carries the current `decision_envelope_id` (the
  envelope that just transitioned) and, when applicable, the successor
  envelope id so subscribers can join both halves.
  """
  @spec approval_queue(event(), DecisionEnvelope.t(), payload()) ::
          :ok | {:error, term()}
  def approval_queue(event, %DecisionEnvelope{} = envelope, extra \\ %{})
      when is_atom(event) do
    PubSub.broadcast(
      PubSub.approval_queue(),
      %{
        topic: :approval_queue,
        event: event,
        decision_envelope_id: envelope.id,
        intent_id: envelope.intent_id,
        at: DateTime.utc_now(),
        payload:
          Map.merge(
            %{
              outcome: envelope.outcome,
              risk_tier: envelope.risk_tier,
              approval_expires_at: envelope.approval_expires_at
            },
            extra
          )
      }
    )
  end

  # --- dashboard:runtime_status -----------------------------------------

  @doc """
  Broadcast a runtime health / pause transition for the operator
  dashboard. Typical events: `:paused`, `:resumed`, `:health_changed`.
  """
  @spec dashboard_status(event(), payload()) :: :ok | {:error, term()}
  def dashboard_status(event, payload \\ %{}) when is_atom(event) do
    PubSub.broadcast(
      PubSub.dashboard_runtime_status(),
      %{
        topic: :dashboard_runtime_status,
        event: event,
        at: DateTime.utc_now(),
        payload: payload
      }
    )
  end

  # --- security:events ---------------------------------------------------

  @doc """
  Broadcast a security event. Typical events:

    * `:paused`, `:resumed` — global runtime pause
    * `:delegation_revoke_requested` — revoke initiated; adapter
      dispatch still pending
    * `:delegation_revoked` — revoke confirmed on-chain
  """
  @spec security_event(event(), payload()) :: :ok | {:error, term()}
  def security_event(event, payload \\ %{}) when is_atom(event) do
    PubSub.broadcast(
      PubSub.security_events(),
      %{
        topic: :security_events,
        event: event,
        at: DateTime.utc_now(),
        payload: payload
      }
    )
  end

  # --- audit:stream ------------------------------------------------------

  @doc """
  Broadcast an audit event summary. Kept intentionally small — the
  full row is persisted in `audit_events` and subscribers that need
  more can query by `id`.
  """
  @spec audit_stream(AuditEvent.t()) :: :ok | {:error, term()}
  def audit_stream(%AuditEvent{} = event) do
    PubSub.broadcast(
      PubSub.audit_stream(),
      %{
        topic: :audit_stream,
        event: :appended,
        at: DateTime.utc_now(),
        payload: %{
          id: event.id,
          event_type: event.event_type,
          subject_type: event.subject_type,
          subject_id: event.subject_id,
          correlation_id: event.correlation_id,
          ts: event.ts
        }
      }
    )
  end

  # --- convenience helpers for workers ----------------------------------

  @doc """
  Convenience: broadcast an execution-plan transition on `intent:{id}`.
  Workers call this alongside the corresponding audit event so LiveView
  tiles don't have to reconstruct the plan from the audit stream.
  """
  @spec execution_progressed(ExecutionPlan.t(), atom() | nil) ::
          :ok | {:error, term()}
  def execution_progressed(%ExecutionPlan{} = plan, prior_status) do
    intent_lifecycle(plan.intent_id, :execution_updated, %{
      execution_plan_id: plan.id,
      prior_status: prior_status,
      execution_status: plan.execution_status,
      final_outcome: plan.final_outcome,
      # Carry the row's `final_reason` so the LiveView can surface
      # an actionable failure copy ("Adapter unavailable after
      # retries — start chain_adapter on localhost:4100") rather
      # than the generic "Execution aborted." It's a small,
      # operator-facing string (e.g. `"adapter_exhausted:adapter_unavailable"`)
      # — not a payload, not secret material.
      final_reason: plan.final_reason,
      tx_refs: plan.tx_refs || []
    })
  end
end
