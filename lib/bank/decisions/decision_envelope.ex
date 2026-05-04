defmodule Bank.Decisions.DecisionEnvelope do
  @moduledoc """
  The runtime's decision on an intent: auto-exec, hold, require
  operator approval, or block. Carries the ordered list of reasons and
  the policy-snapshot reference used to evaluate the intent.

  ## Policy snapshot

  `policy_snapshot_ref` is a jsonb object of the shape:

      %{
        "rule_ids" => ["uuid-1", "uuid-2", ...],
        # Optional, set when the workspace had a published
        # `Bank.Policies.PolicyVersion` at decision time (#226):
        "policy_version_id" => "uuid",
        "policy_version_number" => 3
      }

  Those rule uuids point at `policy_rules.id`. Because the
  `policy_rules` table is append-only (edits supersede rather
  than mutate), capturing the rule uuids at decision time is
  sufficient for deterministic replay — the referenced rows
  never change.

  When `policy_version_id` is present, the decision was pinned
  to a specific published policy version (#223 / #226). Replay
  reads continue to work even if a future operator publishes a
  new version or rolls back: the original decision's pinned ids
  resolve to the same `policy_rules` rows. Decisions made before
  the policy-version surface (legacy) carry only `rule_ids` and
  no version metadata; that path remains valid.

  ## Approval path

  `approval_expires_at` is set only when `outcome == :approval_required`.
  The approvals queue read path joins a partial index on
  `(outcome, approval_expires_at) WHERE current AND outcome =
  'approval_required'`. Timing out an approval supersedes the envelope
  with a new one whose outcome is `:block`.

  ## Supersession

  One `current` envelope per intent, enforced by a partial unique
  index. `state` carries the lifecycle status (`:pending_decision`,
  `:decided`, `:resolved`) independent of `outcome`.
  """

  use Bank.Schema

  alias Bank.Decisions.{TrustAssessment, ExecutionPlan, SimulationReport}
  alias Bank.Intents.AgentIntent

  @outcomes [:auto_exec, :hold, :approval_required, :block]
  @risk_tiers [:low, :moderate, :elevated, :severe]
  @states [:pending_decision, :decided, :resolved]
  @deciders [:runtime, :agent, :user, :adapter]

  @type t :: %__MODULE__{}

  schema "decision_envelopes" do
    field :outcome, Ecto.Enum, values: @outcomes
    field :risk_tier, Ecto.Enum, values: @risk_tiers
    field :reasons, :map, default: %{"items" => []}
    field :policy_snapshot_ref, :map, default: %{"rule_ids" => []}

    field :decided_at, :utc_datetime_usec
    field :decided_by, Ecto.Enum, values: @deciders
    field :state, Ecto.Enum, values: @states, default: :decided
    field :current, :boolean, default: false
    field :approval_expires_at, :utc_datetime_usec

    belongs_to :intent, AgentIntent
    belongs_to :trust_assessment, TrustAssessment
    belongs_to :simulation_report, SimulationReport
    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_id

    has_many :execution_plans, ExecutionPlan, foreign_key: :decision_id

    timestamps()
  end

  @doc """
  Changeset for writing a decision. `approval_expires_at` is required
  iff `outcome == :approval_required`, enforced here rather than at the
  DB so an operator sees a friendly error rather than a check violation.
  """
  def changeset(envelope, attrs) do
    envelope
    |> cast(attrs, [
      :intent_id,
      :outcome,
      :risk_tier,
      :reasons,
      :policy_snapshot_ref,
      :trust_assessment_id,
      :simulation_report_id,
      :decided_at,
      :decided_by,
      :state,
      :current,
      :approval_expires_at,
      :supersedes_id
    ])
    |> validate_required([
      :intent_id,
      :outcome,
      :risk_tier,
      :decided_at,
      :decided_by
    ])
    |> validate_policy_snapshot_shape()
    |> validate_approval_expiry()
    |> foreign_key_constraint(:intent_id)
    |> foreign_key_constraint(:trust_assessment_id)
    |> foreign_key_constraint(:simulation_report_id)
    |> foreign_key_constraint(:supersedes_id)
    |> unique_constraint(:intent_id,
      name: :decision_envelopes_intent_current_idx,
      message: "another current decision already exists for this intent"
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

  @doc "Flips a prior envelope's `current` flag off."
  def mark_not_current(%__MODULE__{} = envelope) do
    change(envelope, current: false)
  end

  @doc """
  Extracts the rule uuids captured in the policy snapshot, returning
  `[]` when the shape is missing. Callers shouldn't need to know the
  jsonb wrapper shape.
  """
  def snapshot_rule_ids(%__MODULE__{policy_snapshot_ref: %{"rule_ids" => ids}})
      when is_list(ids),
      do: ids

  def snapshot_rule_ids(_), do: []

  @doc """
  Extract `{policy_version_id, policy_version_number}` from the
  `policy_snapshot_ref` (#226). Returns `{nil, nil}` for legacy
  envelopes that pre-date the policy-version surface.
  """
  @spec snapshot_version(t() | nil) ::
          {String.t() | nil, integer() | nil}
  def snapshot_version(%__MODULE__{policy_snapshot_ref: ref}) when is_map(ref) do
    {Map.get(ref, "policy_version_id"), Map.get(ref, "policy_version_number")}
  end

  def snapshot_version(_), do: {nil, nil}

  defp validate_policy_snapshot_shape(changeset) do
    case get_field(changeset, :policy_snapshot_ref) do
      nil ->
        changeset

      %{"rule_ids" => ids} when is_list(ids) ->
        changeset

      _ ->
        add_error(
          changeset,
          :policy_snapshot_ref,
          ~s|must be shaped like %{"rule_ids" => [uuid, ...]}|
        )
    end
  end

  defp validate_approval_expiry(changeset) do
    outcome = get_field(changeset, :outcome)
    expires_at = get_field(changeset, :approval_expires_at)

    case {outcome, expires_at} do
      {:approval_required, nil} ->
        add_error(
          changeset,
          :approval_expires_at,
          "must be set when outcome is approval_required"
        )

      {other, ts} when other != :approval_required and not is_nil(ts) ->
        add_error(
          changeset,
          :approval_expires_at,
          "must be nil unless outcome is approval_required"
        )

      _ ->
        changeset
    end
  end
end
