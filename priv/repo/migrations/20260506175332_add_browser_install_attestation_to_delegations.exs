defmodule Bank.Repo.Migrations.AddBrowserInstallAttestationToDelegations do
  @moduledoc """
  Browser-signed install attestation columns (#474).

  See `docs/design/browser-signed-install.md` § 7. Three additive,
  nullable columns let the same `delegations` table carry both:

    * legacy operator-signed delegations
      (`root_validator_owner = "operator"`, `binding_id = NULL`,
      `install_userop_hash = NULL`);
    * new browser-signed delegations
      (`root_validator_owner = "user"`, `binding_id` populated,
      `install_userop_hash` populated through the
      `submitted -> verifying -> active` lifecycle).

  Backfill is one-shot: every pre-existing row was installed by
  the operator EOA, so we stamp `root_validator_owner = "operator"`
  on every existing row. `binding_id` and `install_userop_hash`
  stay `NULL` for legacy rows; the revoke worker (#475) branches on
  `root_validator_owner` to keep using the cryptographic-revoke
  path for those rows.

  All three columns are nullable, so the migration is rollback-safe
  and does not require a backfill window.

  A partial unique index on `(binding_id, install_userop_hash)`
  stops a hostile or buggy browser from creating two pending rows
  for the same install attempt; multiple bindings that retry the
  same envelope-issued / submitted cycle still get a fresh row
  because the userop_hash differs (different nonce / timestamp
  produce a different EIP-4337 hash).
  """

  use Ecto.Migration

  def up do
    alter table(:delegations) do
      add :root_validator_owner, :string
      add :binding_id, :binary_id
      add :install_userop_hash, :string
    end

    execute(
      "UPDATE delegations SET root_validator_owner = 'operator' WHERE root_validator_owner IS NULL",
      ""
    )

    create constraint(:delegations, :root_validator_owner_valid,
             check: "root_validator_owner IN ('operator', 'user')"
           )

    # Extend the state constraint to include `:install_failed`
    # — the terminal state for a browser-signed install whose
    # on-chain verification failed or whose UserOp reverted.
    drop constraint(:delegations, :state_valid)

    create constraint(:delegations, :state_valid,
             check:
               "state IN ('pending','active','revoking','revoke_failed','revoked','expired','install_failed')"
           )

    create index(:delegations, [:binding_id])

    create unique_index(
             :delegations,
             [:binding_id, :install_userop_hash],
             where: "install_userop_hash IS NOT NULL",
             name: :delegations_binding_install_userop_hash_idx
           )
  end

  def down do
    drop index(:delegations, [:binding_id, :install_userop_hash],
           name: :delegations_binding_install_userop_hash_idx
         )

    drop index(:delegations, [:binding_id])

    drop constraint(:delegations, :root_validator_owner_valid)

    execute("UPDATE delegations SET state = 'revoked' WHERE state = 'install_failed'")

    drop constraint(:delegations, :state_valid)

    create constraint(:delegations, :state_valid,
             check: "state IN ('pending','active','revoking','revoke_failed','revoked','expired')"
           )

    alter table(:delegations) do
      remove :install_userop_hash
      remove :binding_id
      remove :root_validator_owner
    end
  end
end
