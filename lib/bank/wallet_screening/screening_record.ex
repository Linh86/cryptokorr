defmodule Bank.WalletScreening.ScreeningRecord do
  @moduledoc """
  A single wallet-screening hit from a source feed.

  Every record carries a `control_tier` that governs how the runtime
  should interpret the hit:

    * `:hard_block` — sanctions data (OFAC, OpenSanctions). Automatic
      block; the runtime must not execute.
    * `:challenge` — community scam/phishing signals (ScamSniffer,
      EtherScamDB, BTC abuse). Routes to manual review.
    * `:context` — public attribution labels (GraphSense). Enrichment
      only; never blocks or challenges alone.
    * `:score_only` — internal suspicious-wallet scoring. Advisory
      signal; never blocks alone.

  The `normalised_address` column stores the chain-aware normalised
  form of the address (lowercased for EVM-family chains). The runtime
  lookup joins on `(chain, normalised_address)` to guarantee
  deterministic exact matching regardless of case.

  Uniqueness is enforced on `(chain, normalised_address, source,
  source_record_id)` so a single source can carry multiple distinct
  entries for the same address (e.g. OFAC may list the same address
  under different SDN entries).
  """

  use Bank.Schema

  alias Bank.Workspaces.Workspace

  @control_tiers [:hard_block, :challenge, :context, :score_only]

  @type t :: %__MODULE__{}

  schema "screening_records" do
    field :chain, :string
    field :address, :string
    field :normalised_address, :string
    field :control_tier, Ecto.Enum, values: @control_tiers
    field :source, :string
    field :source_record_id, :string
    field :category, :string
    field :reason, :string
    field :evidence_uri, :string
    field :metadata, :map, default: %{}
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :score, :decimal
    field :score_version, :string

    # Nullable workspace scope (#158a foundation; runtime filter in
    # #158b). Wallet-screening hits inherit workspace from the
    # counterparty / address-label they back; the column lets future
    # filtered listing avoid a join.
    belongs_to :workspace, Workspace

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :chain,
      :address,
      :normalised_address,
      :control_tier,
      :source,
      :source_record_id,
      :category,
      :reason,
      :evidence_uri,
      :metadata,
      :first_seen_at,
      :last_seen_at,
      :expires_at,
      :score,
      :score_version,
      :workspace_id
    ])
    |> validate_required([
      :chain,
      :address,
      :normalised_address,
      :control_tier,
      :source,
      :source_record_id
    ])
    |> validate_inclusion(:control_tier, @control_tiers)
    |> validate_length(:chain, min: 1, max: 64)
    |> validate_length(:address, min: 1, max: 256)
    |> validate_length(:source, min: 1, max: 128)
    |> validate_score_only_constraints()
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(
      [:chain, :normalised_address, :source, :source_record_id],
      name: :screening_records_chain_addr_source_idx
    )
  end

  defp validate_score_only_constraints(changeset) do
    tier = get_field(changeset, :control_tier)
    score = get_field(changeset, :score)

    cond do
      tier == :score_only and is_nil(score) ->
        add_error(changeset, :score, "is required for score_only records")

      tier != :score_only and not is_nil(score) and tier != nil ->
        add_error(changeset, :score, "must be nil for non-score_only records")

      true ->
        changeset
    end
  end
end
