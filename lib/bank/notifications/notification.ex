defmodule Bank.Notifications.Notification do
  @moduledoc """
  Workspace-scoped inbox event row (#233).

  This schema is the data-only foundation for the notification
  inbox. It carries no logic for runtime emission (#234), inbox UI
  (#235), or external delivery channels (#236). Domain code calls
  `Bank.Notifications.create/1` to record a notification; the
  inbox UI / delivery jobs are separate surfaces that consume this
  table later.

  ## Field-level constraints

  Soft constraints enforced at the changeset layer, in addition to
  the migration's column-level `null: false` defaults:

    * `severity` ∈ `[:info, :warning, :critical]`
    * `status` ∈ `[:unread, :read, :archived]`
    * `role_target` (when set) ∈ `[:viewer, :operator, :admin, :owner]`
    * exactly one of `user_id` or `role_target` must be set
    * `title` ≤ 200 chars; `body` ≤ 2000 chars; `action_link` ≤ 512 chars
    * `action_link` (when set) must start with `/` (relative path
      only — no schemes, no userinfo, no tokenized RPC URLs)
    * `title`, `body`, `action_link` are scanned for
      secret-looking content (`Authorization: Bearer …`,
      `Bearer sk_(test|live)_…`, RPC URLs with userinfo, PEM
      private-key markers, `private_key=…`); any hit rejects the
      changeset with field error `:unsafe_text` rather than
      silently persisting a leak (#233 acceptance: "no secrets in
      payload")

  No update changeset for `event_type`, `severity`, `subject_*`,
  `correlation_id`, `title`, `body`, `action_link`, `dedupe_key`,
  `workspace_id`, `user_id`, `role_target`. These are immutable
  once recorded — only `status` / `read_at` / `archived_at`
  transition via the dedicated `mark_read/2` and `archive/2`
  helpers in the context.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @severities ~w(info warning critical)a
  @statuses ~w(unread read archived)a
  @role_targets ~w(viewer operator admin owner)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "notifications" do
    field :workspace_id, :binary_id
    field :user_id, :binary_id
    field :role_target, Ecto.Enum, values: @role_targets

    field :event_type, :string
    field :severity, Ecto.Enum, values: @severities, default: :info
    field :status, Ecto.Enum, values: @statuses, default: :unread

    field :subject_type, :string
    field :subject_id, :binary_id
    field :correlation_id, :binary_id

    field :title, :string
    field :body, :string
    field :action_link, :string

    field :dedupe_key, :string

    field :read_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @create_fields ~w(
    workspace_id user_id role_target
    event_type severity
    subject_type subject_id correlation_id
    title body action_link
    dedupe_key
  )a

  @required_fields ~w(workspace_id event_type title body dedupe_key)a

  @doc """
  Changeset for an inbox notification's initial creation. Status
  defaults to `:unread`; `read_at` / `archived_at` start `nil`.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @create_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:role_target, @role_targets)
    |> validate_target_addressing()
    |> validate_length(:title, max: 200)
    |> validate_length(:body, max: 2000)
    |> validate_length(:action_link, max: 512)
    |> validate_length(:dedupe_key, max: 200)
    |> validate_action_link_relative()
    |> validate_safe_text(:title)
    |> validate_safe_text(:body)
    |> validate_safe_text(:action_link)
    |> unique_constraint(
      [:workspace_id, :dedupe_key],
      name: :notifications_workspace_dedupe_key_uidx,
      message: "duplicate"
    )
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset for transitioning a row to `:read`. Sets `read_at`
  to the supplied time. Only callable when status is currently
  `:unread`; the helper in `Bank.Notifications` enforces that
  precondition under a row-locked transaction.
  """
  @spec mark_read_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def mark_read_changeset(%__MODULE__{} = n, %DateTime{} = at) do
    n
    |> change(status: :read, read_at: at)
  end

  @doc """
  Changeset for transitioning a row to `:archived`. Sets
  `archived_at` to the supplied time. Idempotent on already-
  archived rows; the helper in `Bank.Notifications` short-circuits
  before calling this changeset.
  """
  @spec archive_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def archive_changeset(%__MODULE__{} = n, %DateTime{} = at) do
    n
    |> change(status: :archived, archived_at: at)
  end

  # --- internal validators -----------------------------------------------

  # Notifications target either a specific user (`user_id`) or a
  # role within the workspace (`role_target`) — never both, never
  # neither. Mixing the two creates ambiguous fan-out semantics
  # for the future inbox UI / delivery jobs (#235/#236).
  defp validate_target_addressing(changeset) do
    user_id = get_field(changeset, :user_id)
    role_target = get_field(changeset, :role_target)

    case {user_id, role_target} do
      {nil, nil} ->
        add_error(
          changeset,
          :user_id,
          "either user_id or role_target must be set"
        )

      {uid, role} when not is_nil(uid) and not is_nil(role) ->
        add_error(
          changeset,
          :role_target,
          "user_id and role_target are mutually exclusive"
        )

      _ ->
        changeset
    end
  end

  # `action_link` is meant for the inbox UI (#235) to render as a
  # local-app deep link (e.g. `/intents/<id>`). Reject anything
  # that looks like an external URL, scheme, or tokenized URL —
  # those are the secret-leak shapes the issue body's
  # "no secrets in payload" acceptance bullet calls out.
  defp validate_action_link_relative(changeset) do
    case get_change(changeset, :action_link) do
      nil ->
        changeset

      "" ->
        # Treat empty string as nil — clear the value so the row
        # carries `null` instead of a 0-length link.
        put_change(changeset, :action_link, nil)

      value when is_binary(value) ->
        if String.starts_with?(value, "/") and not String.starts_with?(value, "//") do
          changeset
        else
          add_error(
            changeset,
            :action_link,
            "must be a relative path starting with /"
          )
        end

      _ ->
        add_error(changeset, :action_link, "must be a relative path starting with /")
    end
  end

  # Pattern-list of secret markers we reject outright. Same shape
  # family as the #248 P2 / #249 P2 / #250 P2 redaction lists in
  # `Bank.Decisions.ReportMarkdown` — keeping them aligned makes
  # the audit story consistent across read and write paths.
  @secret_markers [
    ~r/Authorization\s*:/i,
    ~r/Bearer\s+[^\s]+/i,
    ~r/sk_(test|live)_/i,
    ~r/pk_(test|live)_/i,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    ~r/private_key/i,
    # tokenized URL: scheme://userinfo@host
    ~r{[a-z][a-z0-9+\-.]*://[^/\s@]+:[^/\s@]+@}i,
    # generic scheme://user@host (no password) is also a leak shape
    ~r{[a-z][a-z0-9+\-.]*://[^/\s@]+@}i
  ]

  defp validate_safe_text(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      "" ->
        changeset

      value when is_binary(value) ->
        if Enum.any?(@secret_markers, &Regex.match?(&1, value)) do
          add_error(
            changeset,
            field,
            "contains secret-looking content (#{Atom.to_string(field)} rejected by #233 secret-hygiene gate)"
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
