defmodule Bank.Decisions.SimulationReport do
  @moduledoc """
  A pre-flight simulation produced by an off-chain provider
  (Tenderly-style dry run, fork simulation, etc.). Holds predicted
  balance changes, fee/gas estimates, routing path, and the
  provider-side trace reference for debugging.

  Each report has a `freshness_ttl_seconds`. The decision pipeline
  treats a report as `:stale` once the TTL has passed relative to
  `generated_at`, which triggers a resimulation. The supersession
  chain preserves every prior attempt for replay and incident review.

  Like other flow objects: one `current` per intent, enforced by a
  partial unique index on `(intent_id) WHERE current`.
  """

  use Bank.Schema

  alias Bank.Intents.AgentIntent

  @statuses [:pending, :completed, :failed, :stale]

  @type t :: %__MODULE__{}

  schema "simulation_reports" do
    field :provider, :string
    field :provider_trace_ref, :string
    field :chain, :string
    field :asset, :string
    field :predicted_balance_changes, :map, default: %{"items" => []}
    field :estimated_gas, :integer
    field :estimated_fees, :map
    field :routing_path, :map
    field :expected_output, :decimal
    field :slippage_exposure, :decimal
    field :failure_conditions, :map, default: %{"items" => []}
    field :generated_at, :utc_datetime_usec
    field :freshness_ttl_seconds, :integer
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :current, :boolean, default: false

    belongs_to :intent, AgentIntent
    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_id

    timestamps()
  end

  @doc """
  Changeset for creating or completing a simulation report. Status
  transitions are open here; the decision workflow is the authority
  on which transitions are legal, not this module.
  """
  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :intent_id,
      :provider,
      :provider_trace_ref,
      :chain,
      :asset,
      :predicted_balance_changes,
      :estimated_gas,
      :estimated_fees,
      :routing_path,
      :expected_output,
      :slippage_exposure,
      :failure_conditions,
      :generated_at,
      :freshness_ttl_seconds,
      :status,
      :current,
      :supersedes_id
    ])
    |> validate_required([
      :intent_id,
      :provider,
      :chain,
      :asset,
      :generated_at,
      :freshness_ttl_seconds,
      :status
    ])
    |> validate_number(:freshness_ttl_seconds, greater_than: 0)
    |> foreign_key_constraint(:intent_id)
    |> foreign_key_constraint(:supersedes_id)
    |> unique_constraint(:intent_id,
      name: :simulation_reports_intent_current_idx,
      message: "another current simulation already exists for this intent"
    )
  end

  @doc "Builds the successor changeset — carries `intent_id` forward."
  def supersede(%__MODULE__{} = prior, attrs) do
    attrs =
      attrs
      |> Map.put(:intent_id, prior.intent_id)
      |> Map.put(:supersedes_id, prior.id)

    changeset(%__MODULE__{}, attrs)
  end

  @doc "Flips a prior report's `current` flag off."
  def mark_not_current(%__MODULE__{} = report) do
    change(report, current: false)
  end

  @doc """
  True when the report's freshness window has elapsed relative to
  `generated_at`. Used by the runtime to decide whether a resimulation
  is required before a decision.
  """
  def stale?(%__MODULE__{} = report, now \\ DateTime.utc_now()) do
    expiry = DateTime.add(report.generated_at, report.freshness_ttl_seconds, :second)
    DateTime.compare(now, expiry) != :lt
  end
end
