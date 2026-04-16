defmodule Bank.Repo.Migrations.AddIntentCurrentPointers do
  @moduledoc """
  Cached pointers on `agent_intents` to the current decision /
  trust assessment / simulation / execution plan.

  These are convenience columns for fast single-row lookups (e.g.
  `GET /v1/intents/:id` with `?include=decision,simulation,plan`); the
  authoritative "current" invariant is enforced by the partial unique
  indexes on each child table (`WHERE current` or `WHERE active`), not
  by these pointers.

  Left as plain uuid columns (no FK) to avoid circular table
  dependencies and to keep the intent row trivially insertable before
  any child exists. The app layer sets these in the same transaction
  that writes the successor row on each child table.
  """

  use Ecto.Migration

  def change do
    alter table(:agent_intents) do
      add :current_decision_id, :binary_id
      add :current_trust_assessment_id, :binary_id
      add :current_simulation_id, :binary_id
      add :current_execution_plan_id, :binary_id
    end
  end
end
