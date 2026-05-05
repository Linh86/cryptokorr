defmodule Bank.Repo.Migrations.AddMainnetEnabledToWorkspaces do
  use Ecto.Migration

  @moduledoc """
  Adds workspace-level Base mainnet eligibility flag (#178).

  A single boolean column on `workspaces`:

    * `mainnet_enabled :boolean DEFAULT false NOT NULL` — `false`
      means the workspace cannot run intents on a mainnet chain
      (`Bank.Chains.mainnet_chains/0`); `true` means an admin
      has explicitly opted this workspace into mainnet.

  ## Schema-default backfill

  PostgreSQL's `ALTER TABLE ADD COLUMN ... DEFAULT false NOT NULL`
  initialises every existing row to `false` atomically — no
  separate backfill step is needed. `workspaces` is operator-
  managed (low row count), so this is safe even on a hot table.

  ## Why default false

  Issue #178's acceptance criterion: *"Mainnet disabled by default
  in all envs."* A `false` default means a freshly-created
  workspace cannot accidentally dispatch a mainnet intent — an
  admin must take an explicit action (a follow-up admin path will
  expose the flip; #178 only ships the column + read surface).

  ## No follow-up backfill

  All existing rows are testnet-only by current product reality
  (chain_id 84532 = Base Sepolia in `Bank.Delegations.Provisioning`).
  Setting them to `false` matches that reality — no row is
  retroactively granted mainnet access by this migration.
  """

  def change do
    alter table(:workspaces) do
      add :mainnet_enabled, :boolean, default: false, null: false
    end
  end
end
