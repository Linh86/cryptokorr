defmodule Bank.Counterparties.TrustAssertion do
  @moduledoc """
  A trust level (trusted / sensitive / unknown / conflicted) asserted
  over a subject with an optional scope. Scope narrows the assertion
  (e.g. `%{chain: "base", asset: "USDC", amount_ceiling: "500"}`) so a
  counterparty can be broadly "sensitive" yet "trusted" for small
  payroll payouts.

  Append-only: effective assertions have `superseded_at IS NULL`. A
  newer assertion marks an overlapping prior one as superseded in the
  same transaction, and the prior row is never edited. A time-bounded
  assertion is additionally gated by `expires_at`.

  Like evidence, subjects are polymorphic — `(subject_type,
  subject_id)` — validated by a CHECK constraint.
  """

  use Bank.Schema

  alias Bank.Counterparties.EvidenceArtifact

  @subject_types ~w(counterparty address_label)
  @levels [:trusted, :sensitive, :unknown, :conflicted]
  @actors [:user, :agent, :runtime, :adapter]

  @type t :: %__MODULE__{}

  schema "trust_assertions" do
    field :subject_type, :string
    field :subject_id, Ecto.UUID
    field :level, Ecto.Enum, values: @levels
    field :scope, :map, default: %{}
    field :rationale, :string
    field :evidence_ids, {:array, Ecto.UUID}, default: []
    field :issued_at, :utc_datetime_usec
    field :issued_by, Ecto.Enum, values: @actors
    field :expires_at, :utc_datetime_usec
    field :superseded_at, :utc_datetime_usec

    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_id

    timestamps()
  end

  @doc """
  Changeset for a brand-new assertion. Use `supersede/2` to mark a
  prior assertion; use `mark_superseded/2` on the prior row in the
  same transaction.
  """
  def changeset(assertion, attrs) do
    assertion
    |> cast(attrs, [
      :subject_type,
      :subject_id,
      :level,
      :scope,
      :rationale,
      :evidence_ids,
      :issued_at,
      :issued_by,
      :expires_at,
      :superseded_at,
      :supersedes_id
    ])
    |> validate_required([
      :subject_type,
      :subject_id,
      :level,
      :issued_at,
      :issued_by
    ])
    |> validate_inclusion(:subject_type, @subject_types)
    |> foreign_key_constraint(:supersedes_id)
  end

  @doc """
  Builds a successor assertion, carrying the polymorphic subject forward
  from the prior row and linking the supersession chain.
  """
  def supersede(%__MODULE__{} = prior, attrs) do
    attrs =
      attrs
      |> Map.put(:subject_type, prior.subject_type)
      |> Map.put(:subject_id, prior.subject_id)
      |> Map.put(:supersedes_id, prior.id)

    changeset(%__MODULE__{}, attrs)
  end

  @doc """
  Stamps `superseded_at` on a prior assertion. Intended to run inside
  the same transaction that inserts the successor.
  """
  def mark_superseded(%__MODULE__{} = assertion, superseded_at \\ DateTime.utc_now()) do
    change(assertion, superseded_at: superseded_at)
  end

  @doc """
  True when the assertion is currently effective — not superseded and
  not expired. The DB partial index filters on `superseded_at IS NULL`;
  expiry is evaluated in the query at read time.
  """
  def effective?(%__MODULE__{} = assertion, now \\ DateTime.utc_now()) do
    cond do
      assertion.superseded_at != nil -> false
      assertion.expires_at == nil -> true
      DateTime.compare(assertion.expires_at, now) == :gt -> true
      true -> false
    end
  end

  @doc """
  Convenience for pipelines that want a list of associated evidence
  artifact UUIDs in a stable form.
  """
  def evidence_ids(%__MODULE__{evidence_ids: ids}), do: ids

  @doc false
  # Kept so tests can confirm that the polymorphic contract to
  # `EvidenceArtifact` stays in sync.
  def related_artifact_module, do: EvidenceArtifact
end
