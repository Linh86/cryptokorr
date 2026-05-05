defmodule Bank.Policies.PolicyRule do
  @moduledoc """
  A single policy rule with typed scope and params. Rules are versioned
  by supersession: an edit inserts a new row with `supersedes_id`
  pointing at the prior rule and flips the prior row's `state` to
  `:superseded` in the same transaction.

  `version` is a human-visible counter that increments along the
  supersession chain. The authoritative identity is the uuid; decision
  envelopes capture a jsonb array of rule uuids in
  `policy_snapshot_ref`, which is stable because superseded rows are
  never deleted or edited.
  """

  use Bank.Schema

  alias Bank.Workspaces.Workspace

  @states [:draft, :active, :superseded, :archived]

  # v1 (non-DeFi) rule types — applied by the main evaluator at
  # `Bank.Policies.evaluate/2`.
  @v1_rule_types [
    :amount_limit,
    :rolling_spend_cap,
    :slippage_ceiling,
    :allowed_router,
    :allowed_asset,
    :allowed_chain,
    :autonomy_tier,
    :time_window
  ]

  # DeFi/Morpho rule types added by #202. The main evaluator
  # **skips** these with a `:not_applicable` reason for v1 intent
  # kinds (`:transfer`, `:swap`, `:scheduled_transfer`); the
  # evaluation seam is `Bank.Policies.Morpho.RulesCompiler`, which
  # folds active Morpho rules into a
  # `Bank.DefiVenues.Morpho.PolicyInput` struct that the
  # `Bank.DefiVenues.Morpho.RiskExplanation` engine (#201)
  # consumes. The dispatch-pipeline integration that picks the
  # Morpho path is #203's responsibility.
  @morpho_rule_types [
    :allowed_defi_venue,
    :allowed_vault,
    :allowed_curator,
    :allowed_collateral_asset,
    :allowed_oracle,
    :max_vault_exposure,
    :max_curator_exposure,
    :max_market_exposure,
    :max_collateral_exposure,
    :max_oracle_exposure,
    :max_market_lltv,
    :min_vault_liquidity,
    :min_timelock_seconds,
    :deny_morpho_warning,
    :incident_hold,
    :yield_anomaly_approval
  ]

  @rule_types @v1_rule_types ++ @morpho_rule_types

  @actors [:user, :agent, :runtime, :adapter]

  @type t :: %__MODULE__{}

  schema "policy_rules" do
    field :version, :integer, default: 1
    field :state, Ecto.Enum, values: @states, default: :draft
    field :scope, :map, default: %{}
    field :rule_type, Ecto.Enum, values: @rule_types
    field :params, :map, default: %{}
    field :priority, :integer, default: 0
    field :created_by, Ecto.Enum, values: @actors

    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_id

    # Nullable workspace scope (#158a foundation; runtime filter in
    # #158b). Successor rules carry the prior row's workspace_id.
    belongs_to :workspace, Workspace

    timestamps()
  end

  @doc """
  Changeset for creating a new draft or promoting a draft to active.
  Edits of a live rule must go through `supersede/2`.
  """
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :version,
      :state,
      :scope,
      :rule_type,
      :params,
      :priority,
      :created_by,
      :supersedes_id,
      :workspace_id
    ])
    |> validate_required([:rule_type, :created_by])
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:supersedes_id)
    |> foreign_key_constraint(:workspace_id)
  end

  @doc """
  Builds a successor rule. Carries `rule_type` forward (a supersession
  preserves what kind of rule it is) and auto-increments `version` from
  the prior row. The caller is responsible for flipping the prior row's
  state to `:superseded` via `mark_superseded/1` in the same
  transaction.
  """
  def supersede(%__MODULE__{} = prior, attrs) do
    attrs =
      attrs
      |> Map.put(:rule_type, prior.rule_type)
      |> Map.put(:version, (prior.version || 1) + 1)
      |> Map.put(:supersedes_id, prior.id)
      |> Map.put_new(:state, :active)
      |> Map.put_new(:workspace_id, prior.workspace_id)

    changeset(%__MODULE__{}, attrs)
  end

  @doc "Transitions a prior rule into the `:superseded` state."
  def mark_superseded(%__MODULE__{} = rule) do
    change(rule, state: :superseded)
  end

  @doc "Transitions a draft rule into the `:active` state."
  def activate(%__MODULE__{} = rule) do
    change(rule, state: :active)
  end

  @doc "All rule types accepted by the schema."
  @spec rule_types() :: [atom()]
  def rule_types, do: @rule_types

  @doc "v1 (non-DeFi) rule types — handled by `Bank.Policies.evaluate/2`."
  @spec v1_rule_types() :: [atom()]
  def v1_rule_types, do: @v1_rule_types

  @doc """
  DeFi / Morpho rule types added by #202.

  Folded into `Bank.DefiVenues.Morpho.PolicyInput` by
  `Bank.Policies.Morpho.RulesCompiler.compile/2`; the
  `Bank.DefiVenues.Morpho.RiskExplanation` engine (#201)
  consumes the resulting struct. The main non-DeFi evaluator
  treats these as `:not_applicable` for v1 intent kinds.
  """
  @spec morpho_rule_types() :: [atom()]
  def morpho_rule_types, do: @morpho_rule_types

  @doc "True iff `rule_type` is a Morpho/DeFi rule type."
  @spec morpho?(atom()) :: boolean()
  def morpho?(rule_type) when is_atom(rule_type), do: rule_type in @morpho_rule_types
  def morpho?(_), do: false
end
