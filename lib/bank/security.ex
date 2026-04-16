defmodule Bank.Security do
  @moduledoc """
  Security bounded context.

  Owns operator-facing safety controls: pause, resume, and delegation
  revocation. All three share the same failure-safe posture — when in
  doubt, we stop doing things autonomously. The runtime never auto-
  unpauses, never auto-re-delegates, and a revoke request is treated
  as authoritative the moment it's accepted even if the on-chain
  confirmation arrives later.

  Semantics (per `docs/runtime-flow-and-api.md`):

    * Pause is **soft**. A global pause halts new `executing`
      transitions but does not drop inbound intents or suppress
      decision-writing. Agents may still submit; decisions may still
      be written (typically as `:hold` via `Bank.Autonomy`); nothing
      enters `executing` while paused.
    * Resume does not auto-flush queued intents into execution — each
      still needs a decision event or a manual
      `POST /v1/decisions/{id}/execute`.
    * Revoke delegation is **one-way at the API**. Re-delegation is an
      operator flow in the web console, explicitly out of external-API
      scope.

  Pause state lives in `Bank.Security.PauseState` (in-memory GenServer
  for v0.1; see that module's docstring for the rationale and the v1.0
  follow-up plan for persistence).

  ## Public surface

      pause(scope, opts)         # apply a pause
      resume(scope, opts)        # lift a pause
      paused?(scope)             # is the scope currently paused?
      snapshot()                 # full pause state
      revoke_delegation(smart_account_id, opts)

  `scope` is either `:global` or `{:counterparty, counterparty_id}`.
  `paused?({:counterparty, id})` returns `true` if *either* that
  counterparty or the global scope is paused — callers check a single
  scope rather than OR'ing two results.

  ## Emitted side-effects

  Every state-changing call composes three things:

    1. mutate the pause registry (`Bank.Security.PauseState`) or
       enqueue an adapter job (`Bank.Runtime.enqueue_delegation_revoke`)
    2. append an audit event through `Bank.Runtime.emit_audit/1` so the
       `audit:stream` topic and `audit_events` table see the same write
    3. broadcast on `security:events` via
       `Bank.Runtime.broadcast_security_event/2` for the operator
       dashboard

  All three are best-effort from the caller's point of view in v0.1 —
  if the pause registry accepts the mutation we consider the operation
  successful even if the audit write fails, because the registry is
  what downstream routing reads. An audit-write failure is logged so
  operators see it; it does not roll the pause back.
  """

  require Logger

  alias Bank.Delegations
  alias Bank.Runtime
  alias Bank.Security.PauseState

  @type scope :: :global | {:counterparty, String.t()}
  @type reason :: atom() | String.t()
  @type actor :: :user | :agent | :runtime | :adapter
  @type pause_result :: {:ok, :paused | :already_paused} | {:error, term()}
  @type resume_result :: {:ok, :resumed | :already_running} | {:error, term()}

  @doc """
  Apply a pause.

  `opts`:
    * `:reason` — short atom or string (e.g. `:operator_requested`,
      `:liveness_check_failed`). Defaults to `:operator_requested`.
    * `:actor` — `:user` | `:agent` | `:runtime` | `:adapter`. Defaults
      to `:user`.
    * `:actor_id` — optional string; for `:user`, the operator id.

  Idempotent: pausing an already-paused scope returns
  `{:ok, :already_paused}` without emitting an audit or broadcast.
  """
  @spec pause(scope(), keyword()) :: pause_result()
  def pause(scope, opts \\ []) do
    reason = Keyword.get(opts, :reason, :operator_requested)
    actor = Keyword.get(opts, :actor, :user)
    actor_id = Keyword.get(opts, :actor_id)

    case PauseState.pause(scope, reason, actor: actor, actor_id: actor_id) do
      {:ok, :already_paused} = already ->
        already

      {:ok, :paused} = ok ->
        emit_pause_side_effects(:paused, scope, reason, actor, actor_id)
        ok

      other ->
        other
    end
  end

  @doc """
  Lift a pause.

  `opts`:
    * `:actor`, `:actor_id` — same vocabulary as `pause/2`
    * `:reason` — optional atom/string for the audit payload

  Idempotent: resuming a running scope returns
  `{:ok, :already_running}`.
  """
  @spec resume(scope(), keyword()) :: resume_result()
  def resume(scope, opts \\ []) do
    reason = Keyword.get(opts, :reason, :operator_requested)
    actor = Keyword.get(opts, :actor, :user)
    actor_id = Keyword.get(opts, :actor_id)

    case PauseState.resume(scope, actor: actor, actor_id: actor_id) do
      {:ok, :already_running} = already ->
        already

      {:ok, :resumed} = ok ->
        emit_pause_side_effects(:resumed, scope, reason, actor, actor_id)
        ok

      other ->
        other
    end
  end

  @doc """
  Is the given scope currently paused?

  Counterparty scope inherits global pause: if the global runtime is
  paused, every counterparty scope reports `true`.
  """
  @spec paused?(scope()) :: boolean()
  def paused?(scope), do: PauseState.paused?(scope)

  @doc "Return the full pause state (for operator dashboard)."
  @spec snapshot() :: map()
  def snapshot, do: PauseState.snapshot()

  @doc """
  Revoke the delegation for a smart account.

  This enqueues a `Bank.Runtime.Workers.RevokeDelegation` job on the
  `security.revoke` queue. The worker talks to the TypeScript adapter
  which performs the on-chain revoke; the confirmed state arrives
  asynchronously as a `delegation.revoked` audit event (the worker
  emits `:delegation_revoke_requested` synchronously).

  `opts`:
    * `:reason` — atom, defaults to `:operator_requested`
    * `:actor`, `:actor_id` — as above
    * `:correlation_id` — optional UUID for tying the revoke back to a
      specific intent or investigation; defaults to `nil`
      (runtime-scoped, same as `security.paused`).
  """
  @spec revoke_delegation(String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def revoke_delegation(smart_account_id, opts \\ []) when is_binary(smart_account_id) do
    reason = Keyword.get(opts, :reason, :operator_requested)
    actor = Keyword.get(opts, :actor, :user)
    actor_id = Keyword.get(opts, :actor_id)
    correlation_id = Keyword.get(opts, :correlation_id)

    case Runtime.enqueue_delegation_revoke(smart_account_id, reason) do
      {:ok, job} = ok ->
        # Update the control-plane projection immediately so any
        # further execution attempt sees revoking state before the
        # adapter confirms. `:not_found` is acceptable here: not
        # every smart account is grant-tracked in v0.1 (tests, new
        # accounts not yet granted through the projection).
        _ =
          Delegations.record_revoke_requested(smart_account_id, %{last_reason: to_string(reason)})

        emit_revoke_requested(smart_account_id, reason, actor, actor_id, correlation_id)
        _ = job
        ok

      other ->
        other
    end
  end

  # --- side-effect plumbing -----------------------------------------

  defp emit_pause_side_effects(transition, scope, reason, actor, actor_id) do
    {event_type, broadcast_event} =
      case transition do
        :paused -> {"security.paused", :paused}
        :resumed -> {"security.resumed", :resumed}
      end

    {subject_type, subject_id} = scope_subject(scope)

    audit_attrs = %{
      actor: actor,
      actor_id: actor_id,
      event_type: event_type,
      subject_type: subject_type,
      subject_id: subject_id,
      correlation_id: nil
    }

    case Runtime.emit_audit(audit_attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason_err} ->
        Logger.warning(
          "Bank.Security.#{transition} succeeded but audit emission failed: #{inspect(reason_err)}"
        )
    end

    Runtime.broadcast_security_event(broadcast_event, %{
      scope: scope_payload(scope),
      reason: reason,
      actor: actor,
      actor_id: actor_id
    })

    Bank.Runtime.Telemetry.security(broadcast_event, scope_kind(scope))

    :ok
  end

  defp emit_revoke_requested(smart_account_id, reason, actor, actor_id, correlation_id) do
    audit_attrs = %{
      actor: actor,
      actor_id: actor_id,
      event_type: "delegation.revoke_requested",
      subject_type: "smart_account",
      subject_id: smart_account_id,
      correlation_id: correlation_id
    }

    case Runtime.emit_audit(audit_attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason_err} ->
        Logger.warning(
          "Bank.Security.revoke_delegation enqueued but audit emission failed: #{inspect(reason_err)}"
        )
    end

    Runtime.broadcast_security_event(:delegation_revoke_requested, %{
      smart_account_id: smart_account_id,
      reason: reason,
      actor: actor,
      actor_id: actor_id
    })

    Bank.Runtime.Telemetry.security(:delegation_revoke_requested, :smart_account)

    :ok
  end

  defp scope_subject(:global), do: {"runtime", "global"}
  defp scope_subject({:counterparty, id}) when is_binary(id), do: {"counterparty", id}

  defp scope_payload(:global), do: %{kind: :global}
  defp scope_payload({:counterparty, id}), do: %{kind: :counterparty, counterparty_id: id}

  defp scope_kind(:global), do: :global
  defp scope_kind({:counterparty, _}), do: :counterparty
end
