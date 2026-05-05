defmodule Bank.Repo.Migrations.ExtendIntentKindForDefiYieldDeposit do
  use Ecto.Migration

  @moduledoc """
  Extends the `agent_intents.kind` CHECK constraint with the
  `defi_yield_deposit` value used by the Morpho deposit decision
  pipeline (#203).

  ## Why a constraint swap, not a column rewrite

  `kind` is a `text` column with a CHECK constraint pinning it to
  the v0.1 transfer/swap/scheduled vocabulary. Adding the new
  value is a constraint-only change: no row data is rewritten, no
  per-row scan is needed. Postgres re-evaluates the constraint
  against existing rows, but every existing row carries one of the
  v0.1 values so the validation is a no-op.

  Mirrors the precedent set by
  `extend_policy_rule_types_for_morpho` (#202).
  """

  @v01_kinds ~w(transfer swap scheduled_transfer)
  @added_kinds ~w(defi_yield_deposit)
  @all_kinds @v01_kinds ++ @added_kinds

  def up do
    drop constraint(:agent_intents, :kind_valid)

    create constraint(:agent_intents, :kind_valid,
             check: "kind IN (#{quoted_list(@all_kinds)})"
           )
  end

  def down do
    drop constraint(:agent_intents, :kind_valid)

    create constraint(:agent_intents, :kind_valid,
             check: "kind IN (#{quoted_list(@v01_kinds)})"
           )
  end

  defp quoted_list(values) do
    values
    |> Enum.map(&"'#{&1}'")
    |> Enum.join(",")
  end
end
