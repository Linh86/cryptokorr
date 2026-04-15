defmodule Bank.Decisions.EpistemicClaim do
  @moduledoc """
  The runtime's knowledge snapshot about an intent: derived trust,
  confidence, contradictions, and the supporting assertion / evidence
  ids that led to it.

  One claim per intent is "current" at a time. Refresh writes a new
  row, flips the prior row's `current` flag to false, and moves the
  intent's cached `current_epistemic_claim_id` pointer forward — all in
  one transaction. A partial unique index on `(intent_id) WHERE
  current` enforces the single-live invariant at the DB.
  """

  use Bank.Schema

  alias Bank.Intents.AgentIntent

  @trust_levels [:trusted, :sensitive, :unknown, :conflicted]
  @confidences [:low, :medium, :high]
  @generators [:runtime, :agent, :adapter]

  @type t :: %__MODULE__{}

  schema "epistemic_claims" do
    field :derived_trust, Ecto.Enum, values: @trust_levels
    field :confidence, Ecto.Enum, values: @confidences
    field :contradictions, :map, default: %{"items" => []}
    field :supporting_assertion_ids, {:array, Ecto.UUID}, default: []
    field :supporting_evidence_ids, {:array, Ecto.UUID}, default: []
    field :rationale, :map, default: %{}
    field :generated_at, :utc_datetime_usec
    field :generated_by, Ecto.Enum, values: @generators
    field :current, :boolean, default: false

    belongs_to :intent, AgentIntent
    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_id

    timestamps()
  end

  @doc """
  Changeset for creating a claim. The writer is expected to pair this
  with `mark_not_current/1` on the prior row, inside one transaction.
  """
  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [
      :intent_id,
      :derived_trust,
      :confidence,
      :contradictions,
      :supporting_assertion_ids,
      :supporting_evidence_ids,
      :rationale,
      :generated_at,
      :generated_by,
      :current,
      :supersedes_id
    ])
    |> validate_required([
      :intent_id,
      :derived_trust,
      :confidence,
      :generated_at,
      :generated_by
    ])
    |> foreign_key_constraint(:intent_id)
    |> foreign_key_constraint(:supersedes_id)
    |> unique_constraint(:intent_id,
      name: :epistemic_claims_intent_current_idx,
      message: "another current claim already exists for this intent"
    )
  end

  @doc """
  Builds the successor changeset — carries `intent_id` forward and
  links `supersedes_id`. Does not set `current` automatically; the
  caller picks the right flag state per transaction.
  """
  def supersede(%__MODULE__{} = prior, attrs) do
    attrs =
      attrs
      |> Map.put(:intent_id, prior.intent_id)
      |> Map.put(:supersedes_id, prior.id)

    changeset(%__MODULE__{}, attrs)
  end

  @doc "Flips a prior claim's `current` flag off before inserting a successor."
  def mark_not_current(%__MODULE__{} = claim) do
    change(claim, current: false)
  end
end
