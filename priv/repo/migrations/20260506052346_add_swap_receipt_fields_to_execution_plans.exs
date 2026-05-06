defmodule Bank.Repo.Migrations.AddSwapReceiptFieldsToExecutionPlans do
  use Ecto.Migration

  @moduledoc """
  Add swap-specific receipt columns to `execution_plans` (#193,
  epic #188).

  Both columns are nullable: legacy transfer plans never populate
  them, swap plans populate them when the adapter callback supplies
  the data. The remaining receipt fields (user_op_hash,
  transaction_hash, route_hash, source/destination token addresses,
  input amount) are already covered:

    * `tx_refs` (text[]) — userop_hash and transaction hash entries.
    * `steps` (jsonb) — `route_hash`, `source_token_address`,
      `destination_token_address`, `input_amount`, etc., persisted
      by `Bank.Decisions.SwapRouteArtifacts.from_route/1` (#190).
    * `final_reason` (text) — safe reason atom string for
      `:reverted` / `:aborted` outcomes, mirroring transfers.

  The two new columns capture what the existing schema cannot:

    * `block_number` (bigint) — chain inclusion block. Useful to
      ops queries (`WHERE block_number IS NOT NULL`) and to replay
      so operators can cross-link to a block explorer without
      digging into `tx_refs`.
    * `actual_output_amount` (numeric) — observed swap output in
      destination-asset units. Distinct from the route's
      `expected_output_amount` (already in `steps`) — this is the
      post-swap measured value and matters for slippage audits.
  """

  def change do
    alter table(:execution_plans) do
      add :block_number, :bigint
      add :actual_output_amount, :decimal, precision: 38, scale: 18
    end
  end
end
