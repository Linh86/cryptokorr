defmodule Bank.Repo.Migrations.CreateDelegations do
  @moduledoc """
  Durable delegation state — replaces the in-memory GenServer.

  The authoritative delegation lives on-chain; this is the Phoenix-side
  projection. One row per smart account; state transitions update the
  existing row (not append-only) because delegations are a mutable
  cache projection, not an auditable domain object like policy rules.

  Audit coverage comes from `audit_events` with `subject_type =
  "delegation"`.
  """

  use Ecto.Migration

  def change do
    create table(:delegations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :smart_account_id, :text, null: false
      add :delegation_id, :text, null: false

      add :state, :text, null: false, default: "pending"
      add :chain, :text, null: false, default: "base"

      add :scope, :map, null: false, default: %{}

      add :granted_at, :utc_datetime_usec
      add :revoke_requested_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      add :last_reason, :text
      add :last_tx_hash, :text

      timestamps()
    end

    create constraint(:delegations, :state_valid,
             check: "state IN ('pending','active','revoking','revoked','expired')"
           )

    # At most one non-terminal delegation per smart account.
    # Terminal states (revoked, expired) are kept for history.
    create unique_index(:delegations, [:smart_account_id],
             name: :delegations_smart_account_active_idx,
             where: "state IN ('pending', 'active', 'revoking')"
           )

    create index(:delegations, [:state])
    create index(:delegations, [:smart_account_id])
  end
end
