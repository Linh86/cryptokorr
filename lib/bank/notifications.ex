defmodule Bank.Notifications do
  @moduledoc """
  Workspace-scoped notification inbox context (#233).

  Domain code records inbox events here. This module is the public
  surface for #233 — the data model and dedupe contract — without
  any of the surfaces that compose on top of it later:

    * #234 — runtime emitters (intent.held / decision.approval_required
      / execution.aborted, etc.) that call `create/1` from the
      worker / state-transition paths
    * #235 — operator inbox LiveView
    * #236 — external delivery channels (email / Telegram / webhook)
      and per-user preferences
    * #237 — runbook / smoke updates

  ## Public surface

      create(attrs)                # write one notification (deduped)
      list_for_workspace(ws_id, opts)
      list_for_user(ws_id, user_id, opts)
      mark_read(notification, opts)
      archive(notification, opts)

  ## Dedupe contract

  `create/1` is **deduped per workspace by `dedupe_key`**. Repeated
  calls with the same `(workspace_id, dedupe_key)` return
  `{:duplicate, existing}` without inserting a second row. The
  unique index `notifications_workspace_dedupe_key_uidx` enforces
  this at the DB layer; the context catches the unique-constraint
  violation and re-fetches the existing row, so a concurrent
  duplicate insert race resolves the same way as a serial one. The
  caller can therefore treat repeat calls as idempotent without
  taking a lock.

  This is the "dedupe prevents spam for repeated same event"
  acceptance bullet from #233. Two workspaces can use the same
  `dedupe_key` independently — the unique index keys on
  `(workspace_id, dedupe_key)`, not on `dedupe_key` alone.

  ## No external delivery

  This module never calls an external channel, never enqueues an
  Oban job, and never broadcasts on PubSub. Domain code can
  therefore record a notification from inside any transaction
  without worrying about a delivery side effect leaking out of an
  in-flight rollback. The delivery surfaces (#236) compose on top
  of this table later, and they will own their own rollback /
  PubSub story.

  ## Workspace boundary

  Every read and write helper takes a `workspace_id`. There is no
  global `get/1` or `list/0` on the context — siblings cannot
  observe each other's inbox even by id. `mark_read/2` and
  `archive/2` take a notification struct that the caller already
  loaded inside their workspace; callers that load by raw id MUST
  go through `get_in_workspace/2`.

  ## Secret hygiene

  `create/1` rejects `title` / `body` / `action_link` containing
  secret-looking content (Authorization headers, Bearer tokens,
  `sk_(test|live)_…`, PEM markers, `private_key`, tokenized RPC
  URLs). The reject path returns `{:error, %Ecto.Changeset{}}`
  with a `:unsafe_text` field error. See
  `Bank.Notifications.Notification` for the full marker list.
  """

  import Ecto.Query

  alias Bank.Notifications.Notification
  alias Bank.Repo

  @typedoc """
  `create/1` outcomes:

    * `{:ok, notification}`     — a fresh row was inserted
    * `{:duplicate, existing}`  — `(workspace_id, dedupe_key)`
      already existed; no row inserted, the existing one is
      returned for caller convenience
    * `{:error, changeset}`     — validation rejected (missing
      fields, unsafe text, malformed action_link, etc.)
  """
  @type create_result ::
          {:ok, Notification.t()}
          | {:duplicate, Notification.t()}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Create a notification, deduped per `(workspace_id, dedupe_key)`.

  Returns `{:ok, n}` for a fresh insert, `{:duplicate, existing}`
  if the `(workspace_id, dedupe_key)` pair already exists, or
  `{:error, changeset}` for any other validation failure
  (including the secret-hygiene gate).

  This function does NOT call any external delivery channel,
  enqueue any Oban job, or broadcast on PubSub. It is safe to
  call from inside any `Repo.transaction/1`.
  """
  @spec create(map()) :: create_result()
  def create(attrs) when is_map(attrs) do
    changeset = Notification.create_changeset(attrs)

    case Repo.insert(changeset) do
      {:ok, notification} ->
        # Best-effort external-channel enqueue (#236). Reads
        # the workspace's `notification_delivery_preferences`
        # rows and writes one `notification_deliveries` row
        # per enabled channel. Returns `:ok` even on a
        # preference-side failure so a delivery problem
        # cannot break the inbox-row insert.
        :ok = Bank.Notifications.Deliveries.dispatch_after_create(notification)

        {:ok, notification}

      {:error, %Ecto.Changeset{} = cs} ->
        if dedupe_violation?(cs) do
          existing = fetch_dedupe_existing(attrs)
          {:duplicate, existing}
        else
          {:error, cs}
        end
    end
  end

  defp dedupe_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:workspace_id, {"duplicate", [{:constraint, :unique} | _]}} -> true
      {:dedupe_key, {"duplicate", [{:constraint, :unique} | _]}} -> true
      _ -> false
    end)
  end

  defp fetch_dedupe_existing(attrs) do
    workspace_id = Map.get(attrs, :workspace_id) || Map.get(attrs, "workspace_id")
    dedupe_key = Map.get(attrs, :dedupe_key) || Map.get(attrs, "dedupe_key")

    Repo.one(
      from(n in Notification,
        where: n.workspace_id == ^workspace_id and n.dedupe_key == ^dedupe_key
      )
    )
  end

  @doc """
  List the inbox for a workspace.

  Options:

    * `:status` — filter by `:unread | :read | :archived` (or list
      of statuses). Defaults to `:all` (include archived).
    * `:limit` — page size cap. Default 100.
    * `:role_target` — filter to notifications addressed to a role.
    * `:user_id` — filter to notifications addressed to a user.
    * `:event_type` — filter by event type string.

  Order: most recently inserted first.
  """
  @spec list_for_workspace(binary(), keyword()) :: [Notification.t()]
  def list_for_workspace(workspace_id, opts \\ []) when is_binary(workspace_id) do
    Notification
    |> where([n], n.workspace_id == ^workspace_id)
    |> apply_filters(opts)
    |> order_by([n], desc: n.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc """
  List the inbox for a specific user inside a workspace. Returns
  notifications either explicitly addressed to that user or
  addressed to one of the supplied `:role_targets` they hold (no
  membership lookup is done here — callers pass the role list).

  Options accepted by `list_for_workspace/2` are also accepted
  here (status, limit, event_type).
  """
  @spec list_for_user(binary(), binary(), keyword()) :: [Notification.t()]
  def list_for_user(workspace_id, user_id, opts \\ [])
      when is_binary(workspace_id) and is_binary(user_id) do
    role_targets = Keyword.get(opts, :role_targets, [])

    Notification
    |> where([n], n.workspace_id == ^workspace_id)
    |> where(
      [n],
      n.user_id == ^user_id or n.role_target in ^role_targets
    )
    |> apply_filters(Keyword.delete(opts, :role_targets))
    |> order_by([n], desc: n.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc """
  Look up a notification by id, scoped to a workspace. Returns
  `nil` for a row in a sibling workspace — collapses to the same
  outcome as a missing row so the caller cannot distinguish a
  cross-workspace probe from a not-found.
  """
  @spec get_in_workspace(binary(), binary()) :: Notification.t() | nil
  def get_in_workspace(id, workspace_id) when is_binary(id) and is_binary(workspace_id) do
    Repo.one(
      from(n in Notification,
        where: n.id == ^id and n.workspace_id == ^workspace_id
      )
    )
  end

  @doc """
  Mark a notification as read. Idempotent: re-marking an
  already-read notification returns `{:ok, n}` without bumping
  `read_at`. Archived notifications return `{:error, :archived}`
  — once archived, status does not regress.

  ## Stale-struct safety (#233 P2-2)

  The transition is gated by a conditional `update_all` that
  only flips the row when its DB-side status is currently
  `:unread`. A stale in-memory struct that was loaded before a
  concurrent `archive/2` therefore cannot regress an archived
  row back to `:read`. When the conditional update affects 0
  rows (i.e. the DB row was archived or already read between the
  caller's load and this call), the function reloads the row
  and returns the appropriate outcome:

    * DB row is `:read` → `{:ok, current_db_row}` (idempotent)
    * DB row is `:archived` → `{:error, :archived}` (refuse)
  """
  @spec mark_read(Notification.t(), keyword()) ::
          {:ok, Notification.t()} | {:error, :archived | Ecto.Changeset.t()}
  def mark_read(%Notification{} = n, opts \\ []) do
    at = Keyword.get(opts, :now, DateTime.utc_now())
    now = DateTime.utc_now()

    # `select: x` is the only way to read updated rows back out of
    # `Repo.update_all/3` in Ecto — `returning: true` is an
    # `insert_all` option, not an `update_all` option.
    query =
      from(x in Notification,
        where: x.id == ^n.id and x.status == ^:unread,
        select: x
      )

    case Repo.update_all(query, set: [status: :read, read_at: at, updated_at: now]) do
      {1, [updated]} ->
        {:ok, updated}

      {0, _} ->
        case Repo.get(Notification, n.id) do
          %Notification{status: :read} = current ->
            {:ok, current}

          # Defensive: a row deleted between the caller's load and
          # this call (no public delete path today, but #234+ may
          # add one) collapses to `:archived` so callers see a
          # terminal-refused outcome rather than a misleading
          # `{:ok, stale_struct}`.
          _ ->
            {:error, :archived}
        end
    end
  end

  @doc """
  Archive a notification. Idempotent: re-archiving returns
  `{:ok, n}` without bumping `archived_at`.
  """
  @spec archive(Notification.t(), keyword()) ::
          {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Notification{} = n, opts \\ []) do
    case n.status do
      :archived ->
        {:ok, n}

      _ ->
        at = Keyword.get(opts, :now, DateTime.utc_now())

        n
        |> Notification.archive_changeset(at)
        |> Repo.update()
    end
  end

  # --- internal ----------------------------------------------------------

  defp apply_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:status, :all}, q ->
        q

      {:status, statuses}, q when is_list(statuses) ->
        from(n in q, where: n.status in ^statuses)

      {:status, status}, q when is_atom(status) ->
        from(n in q, where: n.status == ^status)

      {:role_target, role}, q when is_atom(role) ->
        from(n in q, where: n.role_target == ^role)

      {:user_id, user_id}, q when is_binary(user_id) ->
        from(n in q, where: n.user_id == ^user_id)

      {:event_type, event_type}, q when is_binary(event_type) ->
        from(n in q, where: n.event_type == ^event_type)

      {:severity, severity}, q when is_atom(severity) ->
        from(n in q, where: n.severity == ^severity)

      _, q ->
        q
    end)
  end
end
