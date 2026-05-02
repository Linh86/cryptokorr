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

  ## Errors

  Returns `{:error, :invalid_workspace}` for nil/non-binary
  `workspace_id`. Returns `{:error, :invalid_scope_type}` for
  scope_types not yet supported (Phase 1 accepts `:chain` only).
  Returns `{:error, %Ecto.Changeset{}}` for changeset failures
  (reason length, etc.).
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

    Repo.transaction(fn ->
      case lock_active(workspace_id, scope_type, scope_value) do
        %Pause{} = existing ->
          {:already_paused, existing}

        nil ->
          attrs = %{
            workspace_id: workspace_id,
            scope_type: scope_type,
            scope_value: scope_value,
            reason: reason,
            created_by_user_id: actor_id_or_nil(actor_id),
            paused_at: DateTime.utc_now()
          }

          changeset = Pause.create_changeset(%Pause{}, attrs)

          case Repo.insert(changeset) do
            {:ok, %Pause{} = pause} ->
              event_attrs = Events.security_scope_paused(pause, actor: actor, actor_id: actor_id)

              case Audit.append_event(event_attrs) do
                {:ok, _event} -> {:paused, pause}
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
                  %Pause{} = winner -> {:already_paused, winner}
                  nil -> Repo.rollback(cs)
                end
              else
                Repo.rollback(cs)
              end
          end
      end
    end)
    |> normalize_pause_result()
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

    Repo.transaction(fn ->
      case lock_active(workspace_id, scope_type, scope_value) do
        nil ->
          :already_running

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
                {:ok, _event} -> {:resumed, resumed}
                {:error, audit_error} -> Repo.rollback(audit_error)
              end

            {:error, cs} ->
              Repo.rollback(cs)
          end
      end
    end)
    |> normalize_resume_result()
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

  # --- internals ---------------------------------------------------------

  defp lock_active(workspace_id, scope_type, scope_value) do
    workspace_id
    |> active_query(scope_type, scope_value)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp active_query(workspace_id, scope_type, scope_value) do
    from p in Pause,
      where:
        p.workspace_id == ^workspace_id and
          p.scope_type == ^scope_type and
          p.scope_value == ^scope_value and
          is_nil(p.resumed_at)
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

  defp normalize_pause_result({:ok, {:paused, pause}}), do: {:ok, :paused, pause}
  defp normalize_pause_result({:ok, {:already_paused, pause}}), do: {:ok, :already_paused, pause}
  defp normalize_pause_result({:error, reason}), do: {:error, reason}

  defp normalize_resume_result({:ok, {:resumed, pause}}), do: {:ok, :resumed, pause}
  defp normalize_resume_result({:ok, :already_running}), do: {:ok, :already_running}
  defp normalize_resume_result({:error, reason}), do: {:error, reason}
end
