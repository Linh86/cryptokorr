defmodule Bank.Counterparties.EvidenceArtifact do
  @moduledoc """
  An immutable piece of evidence attached polymorphically to either a
  counterparty or an address label. Correction is a new row that
  references the prior one through `supersedes_id`; the original is
  never edited.

  The subject is modeled as `(subject_type, subject_id)` because
  Postgres cannot express polymorphic foreign keys. A CHECK constraint
  on `subject_type` pins the allowed values at the DB layer; the app is
  responsible for ensuring `subject_id` resolves against the matching
  table.
  """

  use Bank.Schema

  @subject_types ~w(counterparty address_label)
  @kinds [
    :user_note,
    :signed_message,
    :external_lookup,
    :transaction_history,
    :contract_classification,
    :prior_successful_transfer
  ]
  @weights [:low, :medium, :high]
  @actors [:user, :agent, :runtime, :adapter]

  @type t :: %__MODULE__{}

  schema "evidence_artifacts" do
    field :subject_type, :string
    field :subject_id, Ecto.UUID
    field :kind, Ecto.Enum, values: @kinds
    field :source, :string
    field :content_uri, :string
    field :payload_hash, :string
    field :captured_at, :utc_datetime_usec
    field :captured_by, Ecto.Enum, values: @actors
    field :weight, Ecto.Enum, values: @weights

    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_id

    timestamps()
  end

  @doc """
  Changeset for creating a new evidence artifact. There is intentionally
  no general "update" changeset: corrections go through `supersede/2`,
  which writes a new row.
  """
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :subject_type,
      :subject_id,
      :kind,
      :source,
      :content_uri,
      :payload_hash,
      :captured_at,
      :captured_by,
      :weight,
      :supersedes_id
    ])
    |> validate_required([
      :subject_type,
      :subject_id,
      :kind,
      :content_uri,
      :payload_hash,
      :captured_at,
      :captured_by
    ])
    |> validate_inclusion(:subject_type, @subject_types)
    |> foreign_key_constraint(:supersedes_id)
  end

  @doc """
  Builds the changeset for a row that supersedes `prior`. Copies the
  polymorphic subject from the prior row so a correction cannot silently
  be re-parented.
  """
  def supersede(%__MODULE__{} = prior, attrs) do
    attrs =
      attrs
      |> Map.put(:subject_type, prior.subject_type)
      |> Map.put(:subject_id, prior.subject_id)
      |> Map.put(:supersedes_id, prior.id)

    changeset(%__MODULE__{}, attrs)
  end
end
