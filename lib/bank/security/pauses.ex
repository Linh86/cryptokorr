defmodule Bank.Security.Pauses do
  @moduledoc """
  Context for DB-backed scope pauses (#228 Phase 1).

  Phase 1 ships per-chain pause only:

      Bank.Security.Pauses.create_pause(workspace_id, :chain, "base", actor: user, reason: "rpc outage")
      Bank.Security.Pauses.resume(workspace_id, :chain, "base", actor: user)
      Bank.Security.Pauses.paused?(workspace_id, :chain, "base")
      Bank.Security.Pauses.get_active_pause(workspace_id, :chain, "base")
      Bank.Security.Pauses.list_active(workspace_id)

  ## Workspace boundary

  Every read/write is scoped by `workspace_id`. Cross-workspace
  isolation is structural: `paused?/3`, `get_active_pause/3`, and
  `list_active/1` filter on `workspace_id == ^workspace_id` and
  refuse a `nil` workspace from calling code (see `paused?/3`).

  ## Idempotency

  `create_pause/4` and `resume/4` run inside a single
  `Repo.transaction/1` against a `FOR UPDATE`-locked active row, so
  two concurrent calls converge: the first transition wins, the
  second observes the winning row and returns the idempotent shape
  without writing or auditing. The partial unique index
  `:pauses_active_uniq` is the second-line backstop in case the
  lock-then-check pattern is bypassed (it cannot be from this
  module, but the DB constraint preserves the invariant for any
  future caller).

  ## Audit emission

  Audit events are emitted only on real transitions. Idempotent
  re-pause and re-resume return the existing row and do not write
  a second audit row. The audit shape is owned by
  `Bank.Audit.Events.security_scope_paused/2` and
  `security_scope_resumed/3`.
  """

  import Ecto.Query

  alias Bank.Accounts.User
  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Repo
  alias Bank.Runtime.Notifier
  alias Bank.Runtime.Telemetry, as: RuntimeTelemetry
  alias Bank.Security.Pause

  @typedoc """
  Phase 1 scope discriminator. Keeps the API consistent with the
  `Ecto.Enum` in `Bank.Security.Pause`. Future phases extend.
  """
  @type scope_type :: :chain

  @typedoc "User UUID, agent atom, or runtime atom."
  @type actor :: User.t() | :user | :agent | :runtime | :adapter | nil

  @type pause_result ::
          {:ok, :paused, Pause.t()}
          | {:ok, :already_paused, Pause.t()}
          | {:error, term()}

  @type resume_result ::
          {:ok, :resumed, Pause.t()}
          | {:ok, :already_running}
          | {:error, term()}

  @doc """
  Apply a pause for `(workspace_id, scope_type, scope_value)`.

  Idempotent: if an active pause already exists for the tuple,
  returns `{:ok, :already_paused, existing_pause}` without writing
  or auditing.

  Concurrent writes are serialized by `FOR UPDATE` on the active
  row. If the lock-then-check pattern is somehow bypassed, the
  partial unique index `:pauses_active_uniq` rejects the duplicate
  insert and the context translates that into the same idempotent
  return shape.

  ## Options

    * `:reason` — operator note (capped at 256 chars by the
      changeset).
    * `:actor` — `:user` | `:agent` | `:runtime` | `:adapter` |
      `%Bank.Accounts.User{}`. Resolved into `actor_id` for the
      audit envelope.
    * `:actor_id` — explicit user UUID; overrides the actor's id
      when both are supplied.
    * `:expires_at` — optional `%DateTime{}` after which
      `Bank.Runtime.Workers.SweepExpiredPauses` will auto-resume
      the pause. MUST be strictly in the future relative to the
      `:paused_at` set inside this call. Idempotent re-pause does
      NOT mutate an existing active pause's `expires_at` — the
      first writer's expiry wins for the lifetime of that pause.

  ## Errors

  Returns `{:error, :invalid_workspace}` for nil/non-binary
  `workspace_id`. Returns `{:error, :invalid_scope_type}` for
  scope_types not yet supported (Phase 1 accepts `:chain` only).
  Returns `{:error, %Ecto.Changeset{}}` for changeset failures
  (reason length, expires_at not after paused_at, etc.).
  """
  @spec create_pause(String.t() | nil, scope_type(), String.t(), keyword()) :: pause_result()
  def create_pause(workspace_id, scope_type, scope_value, opts \\ [])

  def create_pause(workspace_id, _scope_type, _scope_value, _opts)
      when not is_binary(workspace_id),
      do: {:error, :invalid_workspace}

  def create_pause(_workspace_id, scope_type, _scope_value, _opts)
      when scope_type not in [:chain],
      do: {:error, :invalid_scope_type}

  def create_pause(_workspace_id, _scope_type, scope_value, _opts)
      when not is_binary(scope_value) or scope_value == "",
      do: {:error, :invalid_scope_value}

  def create_pause(workspace_id, scope_type, scope_value, opts)
      when is_binary(workspace_id) and is_atom(scope_type) and is_binary(scope_value) do
    actor = Keyword.get(opts, :actor, :user)
    actor_id = resolve_actor_id(actor, Keyword.get(opts, :actor_id))
    reason = Keyword.get(opts, :reason)
    expires_at = Keyword.get(opts, :expires_at)

    txn_result =
      Repo.transaction(fn ->
        case lock_active(workspace_id, scope_type, scope_value) do
          %Pause{} = existing ->
            # Idempotent: row already active. No insert, no audit, no
            # broadcast. The caller observes the existing record —
            # including the FIRST writer's `expires_at`, never a
            # caller's later override.
            {:already_paused, existing, nil}

          nil ->
            attrs = %{
              workspace_id: workspace_id,
              scope_type: scope_type,
              scope_value: scope_value,
              reason: reason,
              created_by_user_id: actor_id_or_nil(actor_id),
              paused_at: DateTime.utc_now(),
              expires_at: expires_at
            }

            changeset = Pause.create_changeset(%Pause{}, attrs)

            case Repo.insert(changeset) do
              {:ok, %Pause{} = pause} ->
                event_attrs =
                  Events.security_scope_paused(pause, actor: actor, actor_id: actor_id)

                case Audit.append_event(event_attrs) do
                  {:ok, audit_event} -> {:paused, pause, audit_event}
                  {:error, audit_error} -> Repo.rollback(audit_error)
                end

              {:error, %Ecto.Changeset{} = cs} ->
                if unique_active_violation?(cs) do
                  # Lost the race: another transaction inserted between
                  # our `lock_active` call and the insert. Re-fetch the
                  # winning row inside the same transaction so the caller
                  # observes a stable already_paused shape with no second
                  # audit row.
                  case lock_active(workspace_id, scope_type, scope_value) do
                    %Pause{} = winner -> {:already_paused, winner, nil}
                    nil -> Repo.rollback(cs)
                  end
                else
                  Repo.rollback(cs)
                end
            end
        end
      end)

    # Broadcast happens AFTER commit so subscribers never observe a
    # `:scope_paused` event for a row that ended up rolled back. Also
    # fires only on a real `:paused` transition, never for the
    # idempotent re-pause / unique-race path.
    case txn_result do
      {:ok, {:paused, pause, audit_event}} ->
        broadcast_scope_paused(pause, audit_event, actor, actor_id)
        # Operator inbox notification (#234). Best-effort: any
        # error here is logged and swallowed by the emitter — a
        # notification-side failure must NEVER roll back the pause.
        emit_pause_paused_notification(pause)
        {:ok, :paused, pause}

      {:ok, {:already_paused, pause, _nil_audit}} ->
        {:ok, :already_paused, pause}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resume the active pause for `(workspace_id, scope_type,
  scope_value)`.

  Idempotent: if no active pause exists, returns
  `{:ok, :already_running}` without writing or auditing.

  Options mirror `create_pause/4` (`:actor`, `:actor_id`).
  """
  @spec resume(String.t() | nil, scope_type(), String.t(), keyword()) :: resume_result()
  def resume(workspace_id, scope_type, scope_value, opts \\ [])

  def resume(workspace_id, _scope_type, _scope_value, _opts)
      when not is_binary(workspace_id),
      do: {:error, :invalid_workspace}

  def resume(_workspace_id, scope_type, _scope_value, _opts)
      when scope_type not in [:chain],
      do: {:error, :invalid_scope_type}

  def resume(_workspace_id, _scope_type, scope_value, _opts)
      when not is_binary(scope_value) or scope_value == "",
      do: {:error, :invalid_scope_value}

  def resume(workspace_id, scope_type, scope_value, opts)
      when is_binary(workspace_id) and is_atom(scope_type) and is_binary(scope_value) do
    actor = Keyword.get(opts, :actor, :user)
    actor_id = resolve_actor_id(actor, Keyword.get(opts, :actor_id))

    txn_result =
      Repo.transaction(fn ->
        case lock_active(workspace_id, scope_type, scope_value) do
          nil ->
            # Idempotent: nothing to resume. No write, no audit, no
            # broadcast.
            {:already_running, nil, nil}

          %Pause{} = active ->
            prior = %{
              paused_at: active.paused_at,
              reason: active.reason,
              created_by_user_id: active.created_by_user_id
            }

            attrs = %{
              resumed_at: DateTime.utc_now(),
              resumed_by_user_id: actor_id_or_nil(actor_id)
            }

            changeset = Pause.resume_changeset(active, attrs)

            case Repo.update(changeset) do
              {:ok, %Pause{} = resumed} ->
                event_attrs =
                  Events.security_scope_resumed(resumed, prior, actor: actor, actor_id: actor_id)

                case Audit.append_event(event_attrs) do
                  {:ok, audit_event} -> {:resumed, resumed, audit_event}
                  {:error, audit_error} -> Repo.rollback(audit_error)
                end

              {:error, cs} ->
                Repo.rollback(cs)
            end
        end
      end)

    # Broadcast happens AFTER commit so subscribers never observe a
    # `:scope_resumed` event for a transaction that rolled back.
    case txn_result do
      {:ok, {:resumed, resumed, audit_event}} ->
        broadcast_scope_resumed(resumed, audit_event, actor, actor_id)
        # Operator inbox notification (#234). Best-effort.
        emit_pause_resumed_notification(resumed)
        {:ok, :resumed, resumed}

      {:ok, {:already_running, _nil_pause, _nil_audit}} ->
        {:ok, :already_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Is the given `(workspace_id, scope_type, scope_value)` currently
  paused at the DB level?

  This call answers DB state only; global pause precedence is
  layered on at `Bank.Security.paused?/2` and at the dispatch
  gates (`Bank.Decisions.validate_not_paused/2`,
  `Bank.Runtime.Workers.RunExecution.verify_not_paused/1`).

  Returns `false` for nil/non-binary `workspace_id` so legacy
  unscoped intents (#158 tail) cannot crash the dispatch path.
  """
  @spec paused?(String.t() | nil, scope_type(), String.t()) :: boolean()
  def paused?(nil, _scope_type, _scope_value), do: false

  def paused?(workspace_id, _scope_type, _scope_value)
      when not is_binary(workspace_id),
      do: false

  def paused?(_workspace_id, scope_type, _scope_value)
      when scope_type not in [:chain],
      do: false

  def paused?(_workspace_id, _scope_type, scope_value)
      when not is_binary(scope_value),
      do: false

  def paused?(workspace_id, scope_type, scope_value)
      when is_binary(workspace_id) and is_atom(scope_type) and is_binary(scope_value) do
    Repo.exists?(active_query(workspace_id, scope_type, scope_value))
  end

  @doc """
  Fetch the currently-active pause row for the given tuple, or
  `nil`. Workspace-scoped.
  """
  @spec get_active_pause(String.t() | nil, scope_type(), String.t()) :: Pause.t() | nil
  def get_active_pause(nil, _scope_type, _scope_value), do: nil

  def get_active_pause(workspace_id, _scope_type, _scope_value)
      when not is_binary(workspace_id),
      do: nil

  def get_active_pause(_workspace_id, scope_type, _scope_value)
      when scope_type not in [:chain],
      do: nil

  def get_active_pause(workspace_id, scope_type, scope_value)
      when is_binary(workspace_id) and is_atom(scope_type) and is_binary(scope_value) do
    Repo.one(active_query(workspace_id, scope_type, scope_value))
  end

  @doc """
  List every active pause for a workspace (newest first).

  Workspace-scoped: refuses to surface sibling-workspace rows even
  when the caller passes `nil`.
  """
  @spec list_active(String.t() | nil) :: [Pause.t()]
  def list_active(nil), do: []
  def list_active(workspace_id) when not is_binary(workspace_id), do: []

  def list_active(workspace_id) when is_binary(workspace_id) do
    from(p in Pause,
      where: p.workspace_id == ^workspace_id and is_nil(p.resumed_at),
      order_by: [desc: p.paused_at]
    )
    |> Repo.all()
  end

  @doc """
  System-wide list of active pauses whose `expires_at <= now`.

  Used by `Bank.Runtime.Workers.SweepExpiredPauses`. Returns at
  most `:limit` rows (default 100) ordered by `expires_at` ASC so
  the sweeper drains the oldest expirations first. Crosses
  workspaces — the sweeper is system-wide.
  """
  @spec list_active_expired(DateTime.t(), keyword()) :: [Pause.t()]
  def list_active_expired(%DateTime{} = now, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(p in Pause,
      where:
        is_nil(p.resumed_at) and not is_nil(p.expires_at) and
          p.expires_at <= ^now,
      order_by: [asc: p.expires_at, asc: p.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @typedoc "Result shape from `expire/2`."
  @type expire_result ::
          {:ok, :expired, Pause.t()}
          | {:ok, :already_resumed}
          | {:ok, :not_yet_expired}
          | {:error, term()}

  @doc """
  Auto-resume a pause whose `expires_at <= now` because the expiry
  fired. Called by `Bank.Runtime.Workers.SweepExpiredPauses`.

  Re-locks the row inside a transaction and re-checks both invariants:
  the row is still active (`resumed_at IS NULL`) and `expires_at`
  has indeed passed. Either condition can flip between the
  sweeper's `list_active_expired/2` snapshot and the call (operator
  resume in the meantime, or the sweeper running with a stale `now`)
  — both are reported back as `{:ok, :already_resumed}` /
  `{:ok, :not_yet_expired}` and emit no audit / no broadcast.

  On a real expiry transition, sets `resumed_at = expires_at`
  (anchored to the recorded expiry, not the sweeper's wall clock,
  so re-runs always agree on the resumption instant) and emits a
  `security.scope_expired` audit event with `actor: :runtime`.
  Idempotent in the small: a second call against the same row sees
  `resumed_at` set and returns `{:ok, :already_resumed}`.
  """
  @spec expire(Pause.t(), DateTime.t()) :: expire_result()
  def expire(%Pause{id: id}, %DateTime{} = now) do
    txn_result =
      Repo.transaction(fn ->
        case Repo.one(from p in Pause, where: p.id == ^id, lock: "FOR UPDATE") do
          nil ->
            {:already_resumed, nil, nil}

          %Pause{resumed_at: %DateTime{}} ->
            {:already_resumed, nil, nil}

          %Pause{expires_at: nil} ->
            {:not_yet_expired, nil, nil}

          %Pause{expires_at: %DateTime{} = expires_at} = locked ->
            if DateTime.compare(expires_at, now) == :gt do
              {:not_yet_expired, nil, nil}
            else
              prior = %{
                paused_at: locked.paused_at,
                reason: locked.reason,
                created_by_user_id: locked.created_by_user_id,
                expires_at: locked.expires_at
              }

              # Anchor `resumed_at` to the recorded expiry instant so a
              # re-run of the sweeper at a different `now` cannot shift
              # it. `resumed_by_user_id` stays nil (no human acted).
              changeset = Pause.resume_changeset(locked, %{resumed_at: expires_at})

              case Repo.update(changeset) do
                {:ok, %Pause{} = expired} ->
                  event_attrs =
                    Events.security_scope_expired(expired, prior,
                      actor: :runtime,
                      actor_id: nil
                    )

                  case Audit.append_event(event_attrs) do
                    {:ok, audit_event} -> {:expired, expired, audit_event}
                    {:error, audit_error} -> Repo.rollback(audit_error)
                  end

                {:error, cs} ->
                  Repo.rollback(cs)
              end
            end
        end
      end)

    case txn_result do
      {:ok, {:expired, pause, audit_event}} ->
        broadcast_scope_expired(pause, audit_event)
        {:ok, :expired, pause}

      {:ok, {:already_resumed, _, _}} ->
        {:ok, :already_resumed}

      {:ok, {:not_yet_expired, _, _}} ->
        {:ok, :not_yet_expired}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- internals ---------------------------------------------------------

  defp lock_active(workspace_id, scope_type, scope_value) do
    workspace_id
    |> active_query(scope_type, scope_value, lazy_expiry: false)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  # `active_query/4` is the single SQL boundary for "is this scope
  # currently paused". The `:lazy_expiry` mode (default `true`) layers
  # on `(expires_at IS NULL OR expires_at > now())` so a pause whose
  # `expires_at` has passed but whose row has not yet been swept by
  # `Bank.Runtime.Workers.SweepExpiredPauses` is treated as inactive
  # at the read boundary — `paused?/3` and `get_active_pause/3` see
  # it disappear immediately, not on the next sweeper tick (#audit
  # M9).
  #
  # The `lock_active/3` write path uses `lazy_expiry: false` so the
  # `FOR UPDATE` selector still finds the unresumed row (matching the
  # partial unique index `pauses_active_uniq`, which is `WHERE
  # resumed_at IS NULL` — it does not care about expiry). The sweeper
  # remains the canonical resumer for expired rows.
  defp active_query(workspace_id, scope_type, scope_value, opts \\ []) do
    lazy_expiry? = Keyword.get(opts, :lazy_expiry, true)

    base =
      from p in Pause,
        where:
          p.workspace_id == ^workspace_id and
            p.scope_type == ^scope_type and
            p.scope_value == ^scope_value and
            is_nil(p.resumed_at)

    if lazy_expiry? do
      now = DateTime.utc_now()
      from p in base, where: is_nil(p.expires_at) or p.expires_at > ^now
    else
      base
    end
  end

  defp unique_active_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          Keyword.get(opts, :constraint_name) == "pauses_active_uniq"
    end)
  end

  defp resolve_actor_id(_actor, explicit) when is_binary(explicit), do: explicit
  defp resolve_actor_id(%User{id: id}, _explicit), do: id
  defp resolve_actor_id(_actor, _explicit), do: nil

  defp actor_id_or_nil(id) when is_binary(id), do: id
  defp actor_id_or_nil(_), do: nil

  # --- post-commit broadcasts -------------------------------------------
  #
  # `Bank.Audit.append_event/1` is called inside the transaction (so the
  # pause row + audit row land atomically), but the realtime fan-out to
  # `audit:stream` and `security:events` happens AFTER `Repo.transaction`
  # commits. If the transaction rolled back, no broadcast fires.
  # Idempotent re-pause / re-resume return `nil` for the audit-event slot
  # and skip broadcasts entirely so subscribers never see duplicate
  # notifications.

  defp broadcast_scope_paused(%Pause{} = pause, audit_event, actor, actor_id) do
    Notifier.audit_stream(audit_event)

    Notifier.security_event(:scope_paused, %{
      scope: scope_payload(pause),
      reason: pause.reason,
      actor: actor,
      actor_id: actor_id
    })

    RuntimeTelemetry.security(:scope_paused, pause.scope_type)
    :ok
  end

  defp broadcast_scope_resumed(%Pause{} = pause, audit_event, actor, actor_id) do
    Notifier.audit_stream(audit_event)

    Notifier.security_event(:scope_resumed, %{
      scope: scope_payload(pause),
      actor: actor,
      actor_id: actor_id
    })

    RuntimeTelemetry.security(:scope_resumed, pause.scope_type)
    :ok
  end

  defp broadcast_scope_expired(%Pause{} = pause, audit_event) do
    Notifier.audit_stream(audit_event)

    Notifier.security_event(:scope_expired, %{
      scope: scope_payload(pause),
      expires_at: pause.expires_at,
      actor: :runtime,
      actor_id: nil
    })

    RuntimeTelemetry.security(:scope_expired, pause.scope_type)
    :ok
  end

  defp scope_payload(%Pause{
         scope_type: scope_type,
         scope_value: scope_value,
         workspace_id: ws_id
       }) do
    %{kind: scope_type, value: scope_value, workspace_id: ws_id}
  end

  # Operator inbox notifications (#234). Wrapped in a try/rescue
  # so a notification-side failure (DB blip, schema-level
  # `:unsafe_text` rejection, etc.) cannot roll back the safe
  # pause/resume transition that already committed.
  defp emit_pause_paused_notification(%Pause{} = pause) do
    try do
      Bank.Notifications.Emitter.emit_pause_scope_paused(pause)
    rescue
      err ->
        require Logger

        Logger.warning(
          "Bank.Security.Pauses: pause-paused notification raised #{inspect(err.__struct__)}; " <>
            "pause stands (id=#{pause.id})"
        )

        :ok
    end
  end

  defp emit_pause_resumed_notification(%Pause{} = pause) do
    try do
      Bank.Notifications.Emitter.emit_pause_scope_resumed(pause)
    rescue
      err ->
        require Logger

        Logger.warning(
          "Bank.Security.Pauses: pause-resumed notification raised #{inspect(err.__struct__)}; " <>
            "resume stands (id=#{pause.id})"
        )

        :ok
    end
  end
end
