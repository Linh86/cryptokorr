defmodule Bank.Decisions.ExecutionPlan do
  @moduledoc """
  The concrete plan the runtime hands to the execution adapter: steps,
  signing requirements, nonce, and the resulting tx refs.

  Plans are attached to a decision envelope. At most one plan per
  decision is `active` at a time — a retry flips the prior plan's
  `active` flag off and inserts a new plan for the same decision. The
  partial unique index `(decision_id) WHERE active` enforces the
  invariant.

  Final outcome (`:confirmed`, `:reverted`, `:aborted`) is recorded
  along with `final_reason`. `tx_refs` is a plain text array, not an
  FK array, since references are per-chain strings (tx hashes,
  user-op hashes, internal adapter ids) that aren't uniform enough to
  foreign-key.
  """

  use Bank.Schema

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Intents.AgentIntent
  alias Bank.Workspaces.Workspace

  @execution_statuses [
    :prepared,
    :signing,
    :broadcasting,
    :pending_confirmation,
    :confirmed,
    :reverted,
    :aborted
  ]
  @final_outcomes [:confirmed, :reverted, :aborted]

  @type t :: %__MODULE__{}

  schema "execution_plans" do
    field :chain, :string
    field :asset, :string
    field :smart_account_id, :string
    field :steps, :map, default: %{"items" => []}
    field :signing_requirements, :map, default: %{}
    field :adapter_ref, :string
    field :nonce, :integer
    field :execution_status, Ecto.Enum, values: @execution_statuses, default: :prepared
    field :tx_refs, {:array, :string}, default: []
    field :final_outcome, Ecto.Enum, values: @final_outcomes
    field :final_reason, :string
    field :active, :boolean, default: true

    belongs_to :decision, DecisionEnvelope
    belongs_to :intent, AgentIntent

    # Nullable workspace scope (#158a foundation; runtime filter in
    # #158b). Read-hint column for adapter callbacks that resolve
    # plans by `execution_plan_id` and need workspace context for
    # audit. The existing `(decision_id) WHERE active` partial unique
    # is unchanged.
    belongs_to :workspace, Workspace

    timestamps()
  end

  @doc """
  Changeset for creating or updating an execution plan. The writer
  pairs insert-of-successor with `deactivate/1` on the prior plan in a
  single transaction.
  """
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :decision_id,
      :intent_id,
      :chain,
      :asset,
      :smart_account_id,
      :steps,
      :signing_requirements,
      :adapter_ref,
      :nonce,
      :execution_status,
      :tx_refs,
      :final_outcome,
      :final_reason,
      :active,
      :workspace_id
    ])
    |> validate_required([
      :decision_id,
      :intent_id,
      :chain,
      :asset,
      :smart_account_id,
      :execution_status
    ])
    |> validate_final_outcome_matches_status()
    |> foreign_key_constraint(:decision_id)
    |> foreign_key_constraint(:intent_id)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:decision_id,
      name: :execution_plans_decision_active_idx,
      message: "another active plan already exists for this decision"
    )
  end

  @doc """
  Dedicated changeset for status/tx-ref progression. Kept apart from
  `changeset/2` so the adapter-facing pipeline can't rewrite the plan
  body after broadcast.
  """
  def progress_changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :execution_status,
      :tx_refs,
      :adapter_ref,
      :nonce,
      :final_outcome,
      :final_reason,
      :active
    ])
    |> validate_final_outcome_matches_status()
  end

  @doc "Flips `active` false on a superseded plan."
  def deactivate(%__MODULE__{} = plan) do
    change(plan, active: false)
  end

  defp validate_final_outcome_matches_status(changeset) do
    case {get_field(changeset, :execution_status), get_field(changeset, :final_outcome)} do
      {:confirmed, outcome} when outcome not in [nil, :confirmed] ->
        add_error(changeset, :final_outcome, "must be :confirmed when status is :confirmed")

      {:reverted, outcome} when outcome not in [nil, :reverted] ->
        add_error(changeset, :final_outcome, "must be :reverted when status is :reverted")

      {:aborted, outcome} when outcome not in [nil, :aborted] ->
        add_error(changeset, :final_outcome, "must be :aborted when status is :aborted")

      _ ->
        changeset
    end
  end
end
