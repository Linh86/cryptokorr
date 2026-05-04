defmodule Bank.Activity.ChainSyncCursor do
  @moduledoc """
  Per-(workspace, chain, source_type, address) cursor for the
  read-only chain activity sync (#245).

  Stores the last successfully-synced block plus a small sanitized
  last-error envelope. The cursor row is workspace-scoped and is
  authoritative for "have we already pulled events through block N
  for this watched address?" — re-running sync picks up at
  `last_block_number + 1` (minus a configurable confirmations
  buffer; see `Bank.Activity.ChainSync`).

  No external chain credentials live on this row. The `last_error`
  column carries a fixed-shape label only — never raw `inspect/1`
  of an RPC error, never a URL, never a token.
  """

  use Bank.Schema

  import Ecto.Changeset

  alias Bank.Workspaces.Workspace

  @source_types [:wallet_chain, :smart_account_chain]

  @type source_type :: :wallet_chain | :smart_account_chain
  @type t :: %__MODULE__{}

  schema "chain_sync_cursors" do
    field :chain, :string
    field :source_type, Ecto.Enum, values: @source_types
    field :address, :string

    field :last_block_number, :integer, default: 0
    field :last_synced_at, :utc_datetime_usec
    field :last_error, :string
    field :last_error_at, :utc_datetime_usec

    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for inserting a brand-new cursor row.

  All four discriminator fields are required. `:last_block_number`
  defaults to 0 (genesis-equivalent: a fresh cursor will pull from
  block 0 onwards, capped by the RPC source's `from_block` floor
  which the caller controls).
  """
  @spec create_changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = cursor, attrs) do
    cursor
    |> cast(attrs, [
      :workspace_id,
      :chain,
      :source_type,
      :address,
      :last_block_number,
      :last_synced_at,
      :last_error,
      :last_error_at
    ])
    |> validate_required([:workspace_id, :chain, :source_type, :address])
    |> validate_length(:chain, min: 1, max: 64)
    |> validate_length(:address, min: 1, max: 128)
    |> validate_length(:last_error, max: 64)
    |> validate_number(:last_block_number, greater_than_or_equal_to: 0)
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :chain, :source_type, :address],
      name: :chain_sync_cursors_uniq,
      message: "cursor already exists"
    )
  end

  @doc """
  Changeset for advancing the cursor on a successful sync. Clears
  any prior `:last_error` / `:last_error_at` envelope.
  """
  @spec advance_changeset(t(), map()) :: Ecto.Changeset.t()
  def advance_changeset(%__MODULE__{} = cursor, attrs) do
    cursor
    |> cast(attrs, [:last_block_number, :last_synced_at])
    |> validate_required([:last_block_number, :last_synced_at])
    |> validate_number(:last_block_number, greater_than_or_equal_to: 0)
    |> put_change(:last_error, nil)
    |> put_change(:last_error_at, nil)
  end

  @doc """
  Changeset for recording a sanitized source failure. Does NOT
  advance `:last_block_number` — the next sync attempt will retry
  from the same point.
  """
  @spec record_error_changeset(t(), map()) :: Ecto.Changeset.t()
  def record_error_changeset(%__MODULE__{} = cursor, attrs) do
    cursor
    |> cast(attrs, [:last_error, :last_error_at])
    |> validate_required([:last_error, :last_error_at])
    |> validate_length(:last_error, max: 64)
  end

  @doc "Allowlisted source-type enum values."
  @spec source_types() :: [source_type()]
  def source_types, do: @source_types
end
