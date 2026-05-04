defmodule Bank.Policies.PolicyVersion do
  @moduledoc """
  Workspace-scoped, versioned draft/publish/rollback aggregate
  bundling a set of `policy_rules` ids (#223).

  The existing `Bank.Policies.PolicyRule` schema versions
  individual rules through a `supersedes_id` chain. This schema
  adds a SET-level aggregate so an operator can reason about
  "policy v3" as a single addressable unit, support a draft
  cycle where edits don't affect runtime, and roll back to a
  prior published version atomically.

  The on-the-wire JSON shape for `rule_ids` is
  `%{"items" => [uuid1, uuid2, ...]}` — matching the
  `DecisionEnvelope.policy_snapshot_ref` convention so a future
  decision can pin against the same shape with no projection
  layer.

  ## Statuses

    * `:draft`      — editable. Rule_ids list can be updated via
      `Bank.Policies.Versions.update_draft_rule_ids/2`. Drafts
      are NOT consulted by runtime — they exist only to be
      published.
    * `:published`  — immutable. Once published, the rule_ids
      list cannot be edited. The schema's update changeset
      rejects any attempt to mutate `rule_ids`. Re-publishing a
      draft creates a new `:published` row and supersedes the
      prior one.
    * `:superseded` — historical. A prior published version that
      was replaced by either a newer publish or a rollback. The
      row stays around forever so old decisions' pinned
      `policy_snapshot_ref` stays meaningful.

  Per-workspace invariants enforced by the migration's partial
  unique index `workspace_id WHERE status = 'published'`:

    * At most ONE `:published` row per workspace at a time.
    * The `version_number` sequence is per-workspace dense
      (no holes), enforced by
      `Bank.Policies.Versions.next_version_number/1`.

  ## Workspace boundary

  Every row carries `workspace_id`. The context API filters
  every read and write by workspace; cross-workspace probes
  collapse to `:not_found`.

  ## Read-only on `:published`

  The schema offers two changesets:

    * `create_changeset/1`  — for fresh `:draft` rows.
    * `update_changeset/2`  — for editing the rule_ids list of a
      `:draft`. Refuses to change `:status` directly. Refuses to
      run on a non-draft row.

  Status transitions (`:draft → :published`, `:published →
  :superseded`) live in the context's `publish_draft/2` and
  `rollback_to_version/2` helpers, not on this schema.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Bank.Workspaces.Workspace

  @type t :: %__MODULE__{}

  @statuses [:draft, :published, :superseded]
  @actors [:agent, :user, :runtime, :operator, :system]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "policy_versions" do
    field :version_number, :integer
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :rule_ids, :map, default: %{"items" => []}

    field :created_by, Ecto.Enum, values: @actors
    field :published_by, Ecto.Enum, values: @actors

    field :published_at, :utc_datetime_usec
    field :effective_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Lists the closed status enum (`:draft | :published | :superseded`).
  Exposed for tests / runtime introspection.
  """
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  Changeset for a fresh draft row. The caller (the context)
  fills in `:rule_ids` (cloned from the current published, or
  empty), `:workspace_id`, `:version_number` (next per-workspace),
  `:created_by`, and `:supersedes_id` (the current published id,
  or nil if none). Status is locked to `:draft`.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :workspace_id,
      :version_number,
      :rule_ids,
      :created_by,
      :supersedes_id
    ])
    |> put_change(:status, :draft)
    |> validate_required([:workspace_id, :version_number, :rule_ids, :created_by])
    |> validate_inclusion(:created_by, @actors)
    |> validate_rule_ids_shape(:rule_ids)
    |> validate_number(:version_number, greater_than: 0)
    |> unique_constraint(
      [:workspace_id, :version_number],
      name: :policy_versions_workspace_version_uidx
    )
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:supersedes_id)
  end

  @doc """
  Changeset for editing a draft row's rule_ids list. Only valid
  when the in-memory struct has `status: :draft`; the context's
  `update_draft_rule_ids/2` enforces this with a row-locked
  read inside a transaction.

  Refuses to change `:status` here — status transitions go
  through `publish_changeset/3`.
  """
  @spec update_draft_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_draft_changeset(%__MODULE__{status: :draft} = version, attrs) do
    version
    |> cast(attrs, [:rule_ids])
    |> validate_rule_ids_shape(:rule_ids)
  end

  def update_draft_changeset(%__MODULE__{} = version, _attrs) do
    version
    |> change()
    |> add_error(:status, "only draft versions can be edited")
  end

  @doc """
  Changeset that flips a draft to `:published`. Sets
  `published_at`, `published_by`, `effective_at`. Does NOT touch
  `rule_ids` — the bundle is frozen at publication.
  """
  @spec publish_changeset(t(), keyword()) :: Ecto.Changeset.t()
  def publish_changeset(%__MODULE__{status: :draft} = version, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    actor = Keyword.fetch!(opts, :published_by)

    version
    |> change(
      status: :published,
      published_at: now,
      effective_at: Keyword.get(opts, :effective_at, now),
      published_by: actor
    )
    |> validate_inclusion(:published_by, @actors)
    |> validate_required([:published_by, :published_at, :effective_at])
  end

  def publish_changeset(%__MODULE__{} = version, _opts) do
    version
    |> change()
    |> add_error(:status, "only draft versions can be published")
  end

  @doc """
  Changeset that supersedes a published version (sets
  `:status` to `:superseded`). Used by both publish and
  rollback transactions when an older published row needs to
  step aside.
  """
  @spec supersede_changeset(t()) :: Ecto.Changeset.t()
  def supersede_changeset(%__MODULE__{status: :published} = version) do
    version
    |> change(status: :superseded)
  end

  def supersede_changeset(%__MODULE__{} = version) do
    version
    |> change()
    |> add_error(:status, "only published versions can be superseded")
  end

  @doc """
  Changeset that re-marks a `:superseded` row as `:published`.
  Used by `Bank.Policies.Versions.rollback_to_version/2`. Sets a
  fresh `effective_at` (the rollback time) but does NOT change
  `published_at` (the original publication time stays canonical).
  """
  @spec rollback_changeset(t(), keyword()) :: Ecto.Changeset.t()
  def rollback_changeset(%__MODULE__{status: :superseded} = version, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    version
    |> change(status: :published, effective_at: now)
  end

  def rollback_changeset(%__MODULE__{} = version, _opts) do
    version
    |> change()
    |> add_error(:status, "only superseded versions can be re-published via rollback")
  end

  # --- helpers -----------------------------------------------------------

  # The on-the-wire shape is `%{"items" => [<uuid>, ...]}` — same
  # convention as `DecisionEnvelope.policy_snapshot_ref`. Reject
  # anything else loudly so a future caller can't sneak in raw
  # provider payloads or arbitrary nested structures.
  defp validate_rule_ids_shape(changeset, field) do
    case get_field(changeset, field) do
      %{"items" => items} when is_list(items) ->
        if Enum.all?(items, &uuid?/1) do
          changeset
        else
          add_error(changeset, field, "items must be a list of UUID strings")
        end

      _ ->
        add_error(changeset, field, ~s(must be a map shaped like %{"items" => [uuid, ...]}))
    end
  end

  defp uuid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp uuid?(_), do: false

  @doc """
  Convenience reader: returns the rule UUID list out of the
  jsonb `rule_ids` shape, or `[]` if the row is malformed.
  """
  @spec rule_ids_list(t()) :: [String.t()]
  def rule_ids_list(%__MODULE__{rule_ids: %{"items" => items}}) when is_list(items), do: items
  def rule_ids_list(_), do: []
end
