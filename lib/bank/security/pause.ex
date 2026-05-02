defmodule Bank.Security.Pause do
  @moduledoc """
  DB-backed pause row for #228 — workspace-scoped, durable across
  control-plane restart.

  Phase 1 ships `:chain` only; Phase 2/3 will extend the
  `scope_type` enum to add `:smart_account` and `:api_key`. The
  in-memory `:global` and `{:counterparty, _}` scopes stay in
  `Bank.Security.PauseState` and are NOT migrated to this table in
  v0.1.

  ## Active-pause invariant

  An active pause is a row where `resumed_at IS NULL`. The partial
  unique index `:pauses_active_uniq` enforces single-active per
  `(workspace_id, scope_type, scope_value)`. The schema-level
  `active?/1` mirrors the same predicate.

  ## Workspace boundary

  `workspace_id` is `null: false` at the DB level. Phase 1 has no
  workspace-less pause; cross-workspace queries are prevented at
  the context layer (see `Bank.Security.Pauses`).

  ## `created_by_user_id` / `resumed_by_user_id`

  Audit-metadata pointers, not load-bearing. Both have
  `on_delete: :nilify_all` and stay nullable. The actor identity is
  durably preserved on the corresponding `security.scope_paused` /
  `security.scope_resumed` audit row.
  """

  use Bank.Schema

  import Ecto.Changeset

  alias Bank.Accounts.User
  alias Bank.Workspaces.Workspace

  @scope_types [:chain]

  @type scope_type :: :chain
  @type t :: %__MODULE__{}

  @reason_max_length 256

  schema "pauses" do
    field :scope_type, Ecto.Enum, values: @scope_types
    field :scope_value, :string
    field :reason, :string
    field :paused_at, :utc_datetime_usec
    field :resumed_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :created_by_user, User, foreign_key: :created_by_user_id
    belongs_to :resumed_by_user, User, foreign_key: :resumed_by_user_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for inserting a brand-new pause row.

  Required: `:workspace_id`, `:scope_type`, `:scope_value`,
  `:paused_at`. Optional: `:reason`, `:created_by_user_id`.

  `:resumed_at` and `:resumed_by_user_id` are NOT castable here —
  resume goes through `resume_changeset/2` against an existing row.
  """
  @spec create_changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = pause, attrs) do
    pause
    |> cast(attrs, [
      :workspace_id,
      :scope_type,
      :scope_value,
      :reason,
      :created_by_user_id,
      :paused_at
    ])
    |> validate_required([:workspace_id, :scope_type, :scope_value, :paused_at])
    |> validate_length(:scope_value, min: 1, max: 64)
    |> validate_length(:reason, max: @reason_max_length)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:created_by_user)
    |> unique_constraint([:workspace_id, :scope_type, :scope_value],
      name: :pauses_active_uniq,
      message: "is already paused"
    )
  end

  @doc """
  Changeset for marking an existing active row as resumed.

  Sets `:resumed_at` (required) and the optional
  `:resumed_by_user_id`. Refuses to operate on a row that is
  already resumed.
  """
  @spec resume_changeset(t(), map()) :: Ecto.Changeset.t()
  def resume_changeset(%__MODULE__{} = pause, attrs) do
    pause
    |> cast(attrs, [:resumed_at, :resumed_by_user_id])
    |> validate_required([:resumed_at])
    |> assoc_constraint(:resumed_by_user)
    |> validate_change(:resumed_at, fn :resumed_at, _value ->
      if is_nil(pause.resumed_at), do: [], else: [resumed_at: "pause already resumed"]
    end)
  end

  @doc """
  Active iff `resumed_at` is `nil`. The partial unique index
  enforces "at most one active row per (workspace, scope_type,
  scope_value)" using the same predicate.
  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{resumed_at: nil}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "List of supported `scope_type` enum values."
  @spec scope_types() :: [scope_type()]
  def scope_types, do: @scope_types
end
