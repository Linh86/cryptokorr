defmodule Bank.Intents.AgentIntent do
  @moduledoc """
  The authoritative input record for the runtime. A transfer, swap, or
  scheduled transfer expressed by an agent (or a human operator acting
  through the agent-intent surface).

  ## Idempotency

  `(agent_id, idempotency_key)` is unique. `payload_hash` captures the
  canonical hash of the submission body; a replay with a matching hash
  returns the existing intent, and a replay with a differing hash
  returns a 409 (enforced by the API layer against the hash stored
  here).

  ## Target shape

  Exactly one of the following is set:

    * `(target_counterparty_id[, target_address_label_id])` — a known
      recipient, trust-evaluated through assertions on the counterparty
      or label.
    * `target_raw_address` — a raw on-chain address, which always
      evaluates to trust `unknown`.

  A DB CHECK constraint (`target_shape_valid`) mirrors this so the
  invariant holds even against direct SQL.

  ## Current-pointer columns

  `current_decision_id`, `current_trust_assessment_id`,
  `current_simulation_id`, and `current_execution_plan_id` are cached
  uuids with no FK. They are set inside the same transaction that
  writes the new child row (decision envelope, claim, etc.). The
  canonical "current" invariant lives on the child table's partial
  unique index — these columns are a convenience to let
  `GET /v1/intents/:id?include=...` resolve everything in one read.
  """

  use Bank.Schema

  alias Bank.Counterparties.{AddressLabel, Counterparty}
  alias Bank.Decisions.{DecisionEnvelope, TrustAssessment, ExecutionPlan, SimulationReport}

  @kinds [:transfer, :swap, :scheduled_transfer]
  @states [
    :submitted,
    :evaluating,
    :decided,
    :executing,
    :executed,
    :blocked,
    :cancelled,
    :expired
  ]
  @sources [:agent, :user, :runtime]

  @type t :: %__MODULE__{}

  schema "agent_intents" do
    field :agent_id, :string
    field :source, Ecto.Enum, values: @sources
    field :idempotency_key, :string
    field :payload_hash, :string

    field :kind, Ecto.Enum, values: @kinds
    field :asset, :string
    field :chain, :string
    field :amount, :decimal

    field :target_raw_address, :string

    field :notes, :string
    field :schema_version, :string, default: "1"
    field :state, Ecto.Enum, values: @states, default: :submitted
    field :submitted_at, :utc_datetime_usec

    # Cached pointers to the active child rows — set in the same
    # transaction that writes the successor, no FK.
    field :current_decision_id, Ecto.UUID
    field :current_trust_assessment_id, Ecto.UUID
    field :current_simulation_id, Ecto.UUID
    field :current_execution_plan_id, Ecto.UUID

    belongs_to :target_counterparty, Counterparty
    belongs_to :target_address_label, AddressLabel

    has_many :trust_assessments, TrustAssessment, foreign_key: :intent_id
    has_many :simulation_reports, SimulationReport, foreign_key: :intent_id
    has_many :decision_envelopes, DecisionEnvelope, foreign_key: :intent_id
    has_many :execution_plans, ExecutionPlan, foreign_key: :intent_id

    timestamps()
  end

  @doc """
  Changeset for newly-submitted intents. Enforces the target-shape
  invariant at the Ecto layer so validation errors surface nicely;
  the DB CHECK is the backstop.
  """
  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :agent_id,
      :source,
      :idempotency_key,
      :payload_hash,
      :kind,
      :asset,
      :chain,
      :amount,
      :target_counterparty_id,
      :target_address_label_id,
      :target_raw_address,
      :notes,
      :schema_version,
      :state,
      :submitted_at
    ])
    |> validate_required([
      :agent_id,
      :source,
      :idempotency_key,
      :payload_hash,
      :kind,
      :asset,
      :chain,
      :amount,
      :submitted_at
    ])
    |> validate_number(:amount, greater_than: Decimal.new(0))
    |> validate_target_shape()
    |> foreign_key_constraint(:target_counterparty_id)
    |> foreign_key_constraint(:target_address_label_id)
    |> unique_constraint([:agent_id, :idempotency_key])
    |> check_constraint(:target_counterparty_id,
      name: :target_shape_valid,
      message: "exactly one of counterparty or raw address must be set"
    )
    |> check_constraint(:target_address_label_id,
      name: :address_label_requires_counterparty,
      message: "address label requires a counterparty"
    )
  end

  @doc """
  Dedicated changeset for bumping the cached current-pointer columns.
  Kept separate from `changeset/2` so the runtime can't accidentally
  rewrite business fields while advancing the pointer.
  """
  def current_pointer_changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :current_decision_id,
      :current_trust_assessment_id,
      :current_simulation_id,
      :current_execution_plan_id,
      :state
    ])
  end

  defp validate_target_shape(changeset) do
    counterparty_id = get_field(changeset, :target_counterparty_id)
    address_label_id = get_field(changeset, :target_address_label_id)
    raw_address = get_field(changeset, :target_raw_address)

    cond do
      counterparty_id && raw_address ->
        add_error(
          changeset,
          :target_raw_address,
          "cannot be set together with target_counterparty_id"
        )

      is_nil(counterparty_id) && is_nil(raw_address) ->
        add_error(
          changeset,
          :target_counterparty_id,
          "either target_counterparty_id or target_raw_address must be set"
        )

      address_label_id && is_nil(counterparty_id) ->
        add_error(
          changeset,
          :target_address_label_id,
          "requires target_counterparty_id"
        )

      true ->
        changeset
    end
  end
end
