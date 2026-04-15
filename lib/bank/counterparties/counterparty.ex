defmodule Bank.Counterparties.Counterparty do
  @moduledoc """
  Business-level recipient. Addresses attach here; policy and trust
  reason at this level. Soft-archival is the lifecycle — historical
  references from intents, decisions, and audit remain intact when a
  counterparty is archived.
  """

  use Bank.Schema

  alias Bank.Counterparties.{AddressLabel, EvidenceArtifact, TrustAssertion}

  @trust_levels [:trusted, :sensitive, :unknown, :conflicted]
  @actors [:user, :agent, :runtime, :adapter]

  @type t :: %__MODULE__{}

  schema "counterparties" do
    field :name, :string
    field :ownership_context, :string
    field :notes, :string
    field :active, :boolean, default: true
    field :current_trust_level, Ecto.Enum, values: @trust_levels
    field :created_by, Ecto.Enum, values: @actors

    has_many :address_labels, AddressLabel

    has_many :evidence_artifacts, EvidenceArtifact,
      where: [subject_type: "counterparty"],
      foreign_key: :subject_id,
      references: :id

    has_many :trust_assertions, TrustAssertion,
      where: [subject_type: "counterparty"],
      foreign_key: :subject_id,
      references: :id

    timestamps()
  end

  @doc """
  Changeset for creating or updating a counterparty. Archival is
  expressed by setting `active` to false; the API caller never deletes.
  """
  def changeset(counterparty, attrs) do
    counterparty
    |> cast(attrs, [
      :name,
      :ownership_context,
      :notes,
      :active,
      :current_trust_level,
      :created_by
    ])
    |> validate_required([:name, :created_by])
    |> validate_length(:name, min: 1, max: 255)
  end
end
