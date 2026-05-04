defmodule Bank.DefiVenues.Morpho.PersistedVaultSnapshot do
  @moduledoc """
  Ecto schema for a Morpho vault snapshot row (#199).

  Persisted shape mirrors the in-memory `Bank.DefiVenues.Morpho.VaultSnapshot`
  struct projected into the `morpho_vault_snapshots` table. The
  raw upstream GraphQL body is *not* stored — only the normalized
  fields and a `payload_hash` sentinel — per the issue's
  "snapshot persistence does not store unnecessary large raw API
  bodies unless explicitly justified" acceptance bullet.

  ## Supersession chain

  Each `(chain_id, vault_address)` has at most one row with
  `current: true`. Successor inserts demote the prior row
  (`current: false`) and reference it via `supersedes_id`, so a
  decision-time replay can walk the chain back deterministically.

  ## Freshness

  Per-field TTL columns let downstream pipelines decide
  separately whether the cached identity, allocation, warnings,
  and APY slices are still usable. The struct stores defaults
  that match the design doc; `Bank.DefiVenues.Morpho.Snapshots`
  exposes a three-state `:fresh | :stale | :expired` API.
  """

  use Bank.Schema

  alias Bank.DefiVenues.Morpho.PersistedVaultSnapshot

  @type t :: %__MODULE__{}

  @cast_fields ~w(
    chain_id vault_address network name symbol listed
    deposit_asset state allocations warnings pending_caps allocators
    source fetched_at payload_hash
    freshness_seconds_identity
    freshness_seconds_allocation
    freshness_seconds_warnings
    freshness_seconds_apy
    current supersedes_id
  )a

  @required_fields ~w(
    chain_id vault_address fetched_at payload_hash source
  )a

  schema "morpho_vault_snapshots" do
    field :chain_id, :integer
    field :vault_address, :string
    field :network, :string

    field :name, :string
    field :symbol, :string
    field :listed, :boolean

    field :deposit_asset, :map, default: %{}
    field :state, :map, default: %{}
    field :allocations, {:array, :map}, default: []
    field :warnings, {:array, :map}, default: []
    field :pending_caps, {:array, :map}, default: []
    field :allocators, {:array, :map}, default: []

    field :source, :map, default: %{}

    field :fetched_at, :utc_datetime_usec
    field :payload_hash, :string

    field :freshness_seconds_identity, :integer, default: 86_400
    field :freshness_seconds_allocation, :integer, default: 300
    field :freshness_seconds_warnings, :integer, default: 300
    field :freshness_seconds_apy, :integer, default: 3600

    field :current, :boolean, default: false
    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for inserting a fresh row from a normalized
  `%VaultSnapshot{}` struct (or an equivalent map).
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %PersistedVaultSnapshot{}
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_length(:vault_address, min: 1, max: 100)
    |> validate_number(:freshness_seconds_identity, greater_than: 0)
    |> validate_number(:freshness_seconds_allocation, greater_than: 0)
    |> validate_number(:freshness_seconds_warnings, greater_than: 0)
    |> validate_number(:freshness_seconds_apy, greater_than: 0)
    |> unique_constraint(
      [:chain_id, :vault_address],
      name: :morpho_vault_snapshots_current_uidx,
      message: "another current snapshot exists for this vault"
    )
    |> foreign_key_constraint(:supersedes_id)
  end

  @doc "Flips a row's `current` flag off. Used by supersession."
  @spec mark_not_current(t()) :: Ecto.Changeset.t()
  def mark_not_current(%PersistedVaultSnapshot{} = row) do
    change(row, current: false)
  end
end
