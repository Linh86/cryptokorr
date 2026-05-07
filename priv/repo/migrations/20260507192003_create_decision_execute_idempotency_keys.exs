defmodule Bank.Repo.Migrations.CreateDecisionExecuteIdempotencyKeys do
  @moduledoc """
  Idempotency tracking for `POST /v1/decisions/:id/execute` (audit C6).

  The endpoint accepts an optional `Idempotency-Key` header. When
  present, the controller persists a row in this table inside the
  same transaction as the resulting `ExecutionPlan`. A retry with
  the same key + same body looks up the row, loads the original
  plan, and replays the response. A retry with the same key + a
  different body returns `409 idempotency_conflict`.

  The unique index on `(decision_id, idempotency_key)` is the
  enforcement boundary. The `body_hash` column stores a SHA-256
  hex digest of the canonical request body so we can distinguish
  same-key replays from same-key conflicts.

  Pattern mirrors `agent_intents.idempotency_key` (raw key stored
  alongside a payload hash) but lives in its own table because the
  decision execute path is 1:N — a single decision can produce
  multiple execution plans over time as retries flip the prior
  plan's `active` flag off, while the idempotency record needs to
  outlive any single plan.
  """

  use Ecto.Migration

  def change do
    create table(:decision_execute_idempotency_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :decision_id,
          references(:decision_envelopes, type: :binary_id, on_delete: :restrict),
          null: false

      add :idempotency_key, :text, null: false
      add :body_hash, :text, null: false

      add :execution_plan_id,
          references(:execution_plans, type: :binary_id, on_delete: :restrict),
          null: false

      timestamps()
    end

    create unique_index(:decision_execute_idempotency_keys, [:decision_id, :idempotency_key],
             name: :decision_execute_idem_keys_unique_idx
           )

    create index(:decision_execute_idempotency_keys, [:execution_plan_id])
  end
end
