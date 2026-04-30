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
  @rule_types [
    :amount_limit,
    :rolling_spend_cap,
    :slippage_ceiling,
    :allowed_router,
    :allowed_asset,
    :allowed_chain,
    :autonomy_tier,
    :time_window
  ]
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
end
