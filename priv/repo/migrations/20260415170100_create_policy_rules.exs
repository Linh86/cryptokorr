defmodule Bank.Repo.Migrations.CreatePolicyRules do
  @moduledoc """
  Policy rules with versioning and supersession.

  Edits do not mutate rows in place: a new row is written with
  `supersedes_id` pointing at the prior one, and the prior row is
  flipped to `state = 'superseded'`. In-flight evaluations continue to
  reference the exact rule-row uuids they captured in the decision
  envelope's `policy_snapshot_ref`, so replay stays deterministic even
  as rules evolve.

  `version` is an operator-visible integer that increments per
  supersession chain; it is a convenience for the UI, not the source of
  identity. The uuid is the identity.
  """

  use Ecto.Migration

  def change do
    create table(:policy_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :version, :integer, null: false, default: 1
      add :state, :text, null: false, default: "draft"
      add :scope, :map, null: false, default: %{}
      add :rule_type, :text, null: false
      add :params, :map, null: false, default: %{}
      add :priority, :integer, null: false, default: 0
      add :created_by, :text, null: false

      add :supersedes_id,
          references(:policy_rules, type: :binary_id, on_delete: :restrict)

      timestamps()
    end

    create constraint(:policy_rules, :state_valid,
             check: "state IN ('draft','active','superseded','archived')"
           )

    create constraint(:policy_rules, :rule_type_valid,
             check:
               "rule_type IN ('amount_limit','rolling_spend_cap','slippage_ceiling','allowed_router','allowed_asset','allowed_chain','autonomy_tier','time_window')"
           )

    # Fast lookups for the evaluation pipeline: active rules of a given
    # type, filterable by the jsonb scope at query time.
    create index(:policy_rules, [:state])
    create index(:policy_rules, [:rule_type, :state])
    create index(:policy_rules, [:supersedes_id])
  end
end
