defmodule Bank.Repo.Migrations.AddRevokeFailedDelegationState do
  @moduledoc """
  Extend the delegation state enum with `:revoke_failed`.

  Context: issue #31. The adapter's revoke path can fail on-chain
  (send rejected, confirmation timeout, sentinel reverted). Before
  this migration all failures were reported as `:revoked` with a
  diagnostic reason string, which conflated a confirmed revoke with
  a failed one — Phoenix could no longer tell whether the delegation
  was actually disabled.

  `:revoke_failed` is non-terminal on purpose: the operator can
  retry the revoke, which transitions the row back through
  `:revoking`. Because the on-chain delegation is still live when a
  revoke fails, the `:revoke_failed` row still participates in the
  non-terminal uniqueness constraint — a fresh grant must wait for
  the prior delegation to be cleanly revoked or aborted at the
  adapter level.
  """

  use Ecto.Migration

  def up do
    drop constraint(:delegations, :state_valid)

    create constraint(:delegations, :state_valid,
             check: "state IN ('pending','active','revoking','revoke_failed','revoked','expired')"
           )

    drop unique_index(:delegations, [:smart_account_id],
           name: :delegations_smart_account_active_idx
         )

    create unique_index(:delegations, [:smart_account_id],
             name: :delegations_smart_account_active_idx,
             where: "state IN ('pending', 'active', 'revoking', 'revoke_failed')"
           )
  end

  def down do
    drop unique_index(:delegations, [:smart_account_id],
           name: :delegations_smart_account_active_idx
         )

    execute("UPDATE delegations SET state = 'revoking' WHERE state = 'revoke_failed'")

    drop constraint(:delegations, :state_valid)

    create constraint(:delegations, :state_valid,
             check: "state IN ('pending','active','revoking','revoked','expired')"
           )

    create unique_index(:delegations, [:smart_account_id],
             name: :delegations_smart_account_active_idx,
             where: "state IN ('pending', 'active', 'revoking')"
           )
  end
end
