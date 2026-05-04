defmodule Bank.DefiVenues.Morpho.SnapshotRecord do
  @moduledoc """
  Persisted Morpho vault snapshot row (#199).

  This is the durable shape of a `Bank.DefiVenues.Morpho.VaultSnapshot`
  — the in-memory normalized struct produced by
  `Bank.DefiVenues.Morpho.Client.fetch_vault_by_address/3`. The
  context (`Bank.DefiVenues.Morpho.Snapshots`) takes a
  `%VaultSnapshot{}` and projects it into this schema for replay
  and freshness checks.

  ## Read-only evidence contract

  Inserting a `SnapshotRecord` is a pure ledger write. It does
  NOT:

    * dispatch a chain transaction,
    * sign a payload,
    * call `Bank.AdapterClient`,
    * enqueue an Oban job,
    * mutate any decision / intent / execution-plan row.

  Future risk-aggregation / explanation surfaces (#201, #202) read
  this table; nothing on this row drives runtime execution.

  ## Idempotency

  The partial unique index
  `morpho_vault_snapshots_dedupe_idx` on
  `(workspace_id, payload_hash)` collapses a re-import of the
  same upstream payload to one row. The context's
  `create_from_snapshot/2` catches the unique-constraint
  violation and returns `{:duplicate, existing}` rather than
  raising.

  ## Workspace boundary

  `workspace_id` is nullable (the issue body's "if applicable"
  caveat). Cross-workspace queries on this table go through
  `Bank.DefiVenues.Morpho.Snapshots`, which workspace-filters
  every read.
  """

  use Bank.Schema

  import Ecto.Changeset

  alias Bank.Workspaces.Workspace

  @venues ~w(morpho)

  @type t :: %__MODULE__{}

  schema "morpho_vault_snapshots" do
    belongs_to :workspace, Workspace

    field :correlation_id, :binary_id

    field :venue, :string, default: "morpho"
    field :chain_id, :integer
    field :vault_address, :string
    field :fetched_at, :utc_datetime_usec
    field :payload_hash, :string

    # Identity
    field :name, :string
    field :symbol, :string
    field :listed, :boolean
    field :network, :string

    # Deposit asset
    field :deposit_asset_address, :string
    field :deposit_asset_symbol, :string
    field :deposit_asset_decimals, :integer

    # State
    field :apy, :string
    field :net_apy, :string
    field :total_assets, :string
    field :fee, :string
    field :timelock, :integer

    # Bulk JSONB sections — each map carries an `:items` list of
    # the projected sub-rows. Wrapped in a map (not a raw array)
    # so a schema bump can add adjacent keys without a migration.
    field :allocations, :map, default: %{"items" => []}
    field :warnings, :map, default: %{"items" => []}
    field :pending_caps, :map, default: %{"items" => []}
    field :allocators, :map, default: %{"items" => []}

    # Source
    field :source_name, :string, default: "morpho_blue_graphql"
    field :source_schema_version, :string
    field :source_warnings, :map, default: %{"items" => []}

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(
    workspace_id
    correlation_id
    venue
    chain_id
    vault_address
    fetched_at
    payload_hash
    name
    symbol
    listed
    network
    deposit_asset_address
    deposit_asset_symbol
    deposit_asset_decimals
    apy
    net_apy
    total_assets
    fee
    timelock
    allocations
    warnings
    pending_caps
    allocators
    source_name
    source_schema_version
    source_warnings
  )a

  @required_fields ~w(
    venue
    chain_id
    vault_address
    fetched_at
    payload_hash
    source_name
    source_schema_version
  )a

  @doc """
  Insert changeset. Caller (the `Bank.DefiVenues.Morpho.Snapshots`
  context) MUST pre-flatten the in-memory `VaultSnapshot` into the
  flat columns + JSONB blocks before passing attrs in — the
  schema does not derive any field.
  """
  @spec create_changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = record, attrs) do
    record
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:venue, @venues)
    |> validate_length(:vault_address, min: 1, max: 128)
    |> validate_length(:payload_hash, is: 64)
    |> validate_length(:source_schema_version, min: 1, max: 128)
    |> validate_number(:chain_id, greater_than_or_equal_to: 0)
    |> validate_format(:payload_hash, ~r/\A[0-9a-f]{64}\z/)
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :payload_hash],
      name: :morpho_vault_snapshots_workspace_dedupe_idx,
      message: "snapshot already exists for this workspace + payload"
    )
    |> unique_constraint([:payload_hash],
      name: :morpho_vault_snapshots_global_dedupe_idx,
      message: "snapshot already exists for this payload"
    )
  end

  @doc "Allowlisted venue values, exported for callers / tests."
  @spec venues() :: [String.t()]
  def venues, do: @venues
end
