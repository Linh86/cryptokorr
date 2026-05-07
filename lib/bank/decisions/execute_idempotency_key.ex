defmodule Bank.Decisions.ExecuteIdempotencyKey do
  @moduledoc """
  Idempotency tracking for `POST /v1/decisions/:id/execute` (audit C6).

  Each row records that a particular `(decision_id, idempotency_key)`
  pair was seen, the SHA-256 `body_hash` of the canonical execute
  request body that came with it, and the resulting `execution_plan_id`.

  Same-key + same-body retries replay the linked plan; same-key +
  different-body retries surface as a `409 idempotency_conflict`. The
  unique index on `(decision_id, idempotency_key)` is the enforcement
  boundary; this schema only models the row.

  Mirrors the pattern `agent_intents.idempotency_key` uses (raw key
  alongside a payload hash) but lives in its own table because a
  single decision may produce many execution plans over time and the
  idempotency record needs to outlive any single plan.
  """

  use Bank.Schema

  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}

  @type t :: %__MODULE__{}

  schema "decision_execute_idempotency_keys" do
    field :idempotency_key, :string
    field :body_hash, :string

    belongs_to :decision, DecisionEnvelope
    belongs_to :execution_plan, ExecutionPlan

    timestamps()
  end

  @doc """
  Build a changeset for a new idempotency-key record. All four
  attributes (`decision_id`, `idempotency_key`, `body_hash`,
  `execution_plan_id`) are required and the `(decision_id,
  idempotency_key)` pair must be unique.
  """
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:decision_id, :idempotency_key, :body_hash, :execution_plan_id])
    |> validate_required([:decision_id, :idempotency_key, :body_hash, :execution_plan_id])
    |> unique_constraint([:decision_id, :idempotency_key],
      name: :decision_execute_idem_keys_unique_idx
    )
  end
end
