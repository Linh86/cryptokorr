defmodule Bank.Repo.Migrations.CreateDecisionFlowTables do
  @moduledoc """
  Per-intent derived objects: trust assessments, simulation reports,
  decision envelopes, and execution plans.

  ## Current + history convention

  The runtime-flow doc clarifies that the domain model's "1:1"
  relationship between each of these objects and `AgentIntent` really
  means "one current, zero or more historical via supersession." We
  encode that as:

    * a boolean flag (`current` for claims / simulations / envelopes,
      `active` for plans) that the app flips inside the same
      transaction that writes the successor row
    * a `supersedes_id` FK to self for the history chain
    * a partial unique index enforcing at most one live flag per
      intent (per decision for execution plans), so the invariant is
      a DB-level guarantee rather than a convention

  Default reads join on `WHERE current = true` / `WHERE active = true`
  and hit the partial unique index directly.

  ## Policy snapshots

  `decision_envelopes.policy_snapshot_ref` stores the set of
  `policy_rules.id` values that were active at decision time, as a
  jsonb array of uuid strings (e.g. `["uuid-1","uuid-2"]`). The uuids
  alone are sufficient for deterministic replay because `policy_rules`
  is append-only: the rule-row referenced never changes. A dedicated
  `policy_snapshots` table was considered and rejected for MVP — it
  would add a write on every decision for no replay benefit.
  """

  use Ecto.Migration

  def change do
    # Trust assessments ---------------------------------------------------
    create table(:trust_assessments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :intent_id,
          references(:agent_intents, type: :binary_id, on_delete: :restrict),
          null: false

      add :derived_trust, :text, null: false
      add :confidence, :text, null: false
      add :contradictions, :map, null: false, default: %{"items" => []}
      add :supporting_assertion_ids, {:array, :binary_id}, null: false, default: []
      add :supporting_evidence_ids, {:array, :binary_id}, null: false, default: []
      add :rationale, :map, null: false, default: %{}
      add :generated_at, :utc_datetime_usec, null: false
      add :generated_by, :text, null: false
      add :current, :boolean, null: false, default: false

      add :supersedes_id,
          references(:trust_assessments, type: :binary_id, on_delete: :restrict)

      timestamps()
    end

    create constraint(:trust_assessments, :derived_trust_valid,
             check: "derived_trust IN ('trusted','sensitive','unknown','conflicted')"
           )

    create constraint(:trust_assessments, :confidence_valid,
             check: "confidence IN ('low','medium','high')"
           )

    create index(:trust_assessments, [:intent_id])

    create unique_index(:trust_assessments, [:intent_id],
             name: :trust_assessments_intent_current_idx,
             where: "current"
           )

    # Simulation reports -------------------------------------------------
    create table(:simulation_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :intent_id,
          references(:agent_intents, type: :binary_id, on_delete: :restrict),
          null: false

      add :provider, :text, null: false
      add :provider_trace_ref, :text
      add :chain, :text, null: false
      add :asset, :text, null: false
      add :predicted_balance_changes, :map, null: false, default: %{"items" => []}
      add :estimated_gas, :bigint
      add :estimated_fees, :map
      add :routing_path, :map
      add :expected_output, :decimal, precision: 38, scale: 18
      add :slippage_exposure, :decimal, precision: 38, scale: 18
      add :failure_conditions, :map, null: false, default: %{"items" => []}
      add :generated_at, :utc_datetime_usec, null: false
      add :freshness_ttl_seconds, :integer, null: false
      add :status, :text, null: false, default: "pending"
      add :current, :boolean, null: false, default: false

      add :supersedes_id,
          references(:simulation_reports, type: :binary_id, on_delete: :restrict)

      timestamps()
    end

    create constraint(:simulation_reports, :status_valid,
             check: "status IN ('pending','completed','failed','stale')"
           )

    create index(:simulation_reports, [:intent_id])
    create index(:simulation_reports, [:status])

    create unique_index(:simulation_reports, [:intent_id],
             name: :simulation_reports_intent_current_idx,
             where: "current"
           )

    # Decision envelopes -------------------------------------------------
    create table(:decision_envelopes, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :intent_id,
          references(:agent_intents, type: :binary_id, on_delete: :restrict),
          null: false

      add :outcome, :text, null: false
      add :risk_tier, :text, null: false
      add :reasons, :map, null: false, default: %{"items" => []}
      # jsonb array of policy_rule uuids captured at decision time.
      add :policy_snapshot_ref, :map, null: false, default: %{"rule_ids" => []}

      add :trust_assessment_id,
          references(:trust_assessments, type: :binary_id, on_delete: :restrict)

      add :simulation_report_id,
          references(:simulation_reports, type: :binary_id, on_delete: :restrict)

      add :decided_at, :utc_datetime_usec, null: false
      add :decided_by, :text, null: false
      add :state, :text, null: false, default: "decided"
      add :current, :boolean, null: false, default: false
      # When set, this envelope is waiting for the operator or a timer.
      add :approval_expires_at, :utc_datetime_usec

      add :supersedes_id,
          references(:decision_envelopes, type: :binary_id, on_delete: :restrict)

      timestamps()
    end

    create constraint(:decision_envelopes, :outcome_valid,
             check: "outcome IN ('auto_exec','hold','approval_required','block')"
           )

    create constraint(:decision_envelopes, :risk_tier_valid,
             check: "risk_tier IN ('low','moderate','elevated','severe')"
           )

    create constraint(:decision_envelopes, :state_valid,
             check: "state IN ('pending_decision','decided','resolved')"
           )

    create index(:decision_envelopes, [:intent_id])
    create index(:decision_envelopes, [:outcome])

    create unique_index(:decision_envelopes, [:intent_id],
             name: :decision_envelopes_intent_current_idx,
             where: "current"
           )

    # Approval queue read path: live envelopes awaiting operator action.
    create index(:decision_envelopes, [:outcome, :approval_expires_at],
             name: :decision_envelopes_approval_queue_idx,
             where: "current AND outcome = 'approval_required'"
           )

    # Execution plans ----------------------------------------------------
    create table(:execution_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :decision_id,
          references(:decision_envelopes, type: :binary_id, on_delete: :restrict),
          null: false

      add :intent_id,
          references(:agent_intents, type: :binary_id, on_delete: :restrict),
          null: false

      add :chain, :text, null: false
      add :asset, :text, null: false
      add :smart_account_id, :text, null: false
      add :steps, :map, null: false, default: %{"items" => []}
      add :signing_requirements, :map, null: false, default: %{}
      add :adapter_ref, :text
      add :nonce, :bigint
      add :execution_status, :text, null: false, default: "prepared"
      add :tx_refs, {:array, :text}, null: false, default: []
      add :final_outcome, :text
      add :final_reason, :text
      add :active, :boolean, null: false, default: true

      timestamps()
    end

    create constraint(:execution_plans, :execution_status_valid,
             check:
               "execution_status IN ('prepared','signing','broadcasting','pending_confirmation','confirmed','reverted','aborted')"
           )

    create constraint(:execution_plans, :final_outcome_valid,
             check: "final_outcome IS NULL OR final_outcome IN ('confirmed','reverted','aborted')"
           )

    create index(:execution_plans, [:intent_id])
    create index(:execution_plans, [:decision_id])
    create index(:execution_plans, [:execution_status])

    # Exactly one active plan per decision — retries create a new plan
    # and flip the prior one's `active` to false.
    create unique_index(:execution_plans, [:decision_id],
             name: :execution_plans_decision_active_idx,
             where: "active"
           )
  end
end
