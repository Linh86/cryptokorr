defmodule Bank.Counterparties.AddressLabel do
  @moduledoc """
  A (chain, address) pair owned by a counterparty. One counterparty may
  have many labels — e.g. a hot wallet, a cold wallet, and a contract
  allow-listed for approvals.

  Retirement, not deletion: a label leaves circulation by stamping
  `retired_at`. Historical references from intents and audit keep
  pointing at the retired row. Uniqueness of `(chain, lower(address))`
  is enforced only over non-retired rows by a partial unique index
  created in the migration.
  """

  use Bank.Schema

  alias Bank.Counterparties.{Counterparty, EvidenceArtifact, TrustAssertion}

  @roles [:payout, :funding, :contract, :other]

  # Allowlist mirrors `Bank.Chains.mainnet_chains/0` and
  # `Bank.Chains.testnet_chains/0` for the chain identifiers the
  # AddressLabel surface actually uses (base, base-sepolia, ethereum).
  # Counterparties may carry an `ethereum` label even though v0.1
  # intents only execute on `base` — see
  # test/bank/wallet_screening/evidence_test.exs and
  # test/bank/autonomy_screening_test.exs for the cross-chain
  # screening flows that depend on this. Must match the DB CHECK
  # constraint added in
  # 20260507000000_constrain_address_label_chain.exs.
  @allowed_chains ~w(base base-sepolia ethereum)

  @type t :: %__MODULE__{}

  schema "address_labels" do
    field :chain, :string
    field :address, :string
    field :alias, :string
    field :role, Ecto.Enum, values: @roles, default: :other
    field :verified, :boolean, default: false
    field :retired_at, :utc_datetime_usec

    belongs_to :counterparty, Counterparty

    has_many :evidence_artifacts, EvidenceArtifact,
      where: [subject_type: "address_label"],
      foreign_key: :subject_id,
      references: :id

    has_many :trust_assertions, TrustAssertion,
      where: [subject_type: "address_label"],
      foreign_key: :subject_id,
      references: :id

    timestamps()
  end

  @doc """
  Changeset for creating or updating an address label. Retirement is a
  dedicated path (see `retire/1`) so a routine update cannot silently
  disable a label.
  """
  def changeset(address_label, attrs) do
    address_label
    |> cast(attrs, [
      :counterparty_id,
      :chain,
      :address,
      :alias,
      :role,
      :verified,
      :retired_at
    ])
    |> validate_required([:counterparty_id, :chain, :address, :role])
    |> validate_length(:chain, min: 1, max: 64)
    |> validate_inclusion(:chain, @allowed_chains)
    |> validate_length(:address, min: 1, max: 128)
    |> validate_format(:address, ~r/^0x[0-9a-fA-F]{40}$/,
      message: "must be a 0x-prefixed 20-byte hex address"
    )
    |> foreign_key_constraint(:counterparty_id)
    |> unique_constraint([:chain, :address],
      name: :address_labels_chain_address_active_idx,
      message: "is already in use for this chain"
    )
  end

  @doc """
  Marks a label as retired. Historical rows keep pointing at the label
  unchanged; only the `retired_at` stamp changes.
  """
  def retire(address_label, retired_at \\ DateTime.utc_now()) do
    address_label
    |> change(retired_at: retired_at)
  end
end
