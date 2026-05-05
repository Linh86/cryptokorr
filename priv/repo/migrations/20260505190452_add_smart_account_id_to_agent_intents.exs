defmodule Bank.Repo.Migrations.AddSmartAccountIdToAgentIntents do
  use Ecto.Migration

  @moduledoc """
  Add the optional `smart_account_id` column to `agent_intents` (#184,
  epic #167). The column is a `binary_id` foreign key to
  `smart_accounts(id)` (created in #183 / migration
  `20260505171901_create_smart_accounts.exs`).

  Nullable on purpose:

    * legacy intents pre-date the column,
    * single-account workspaces may rely on the `Bank.Intents.submit/2`
      compatibility-mode auto-resolution path,
    * intent kinds that do not touch chain dispatch (future) may carry
      no account selection at all.

  `on_delete: :restrict` mirrors the rest of the agent-intents FK
  policy: an account that has been targeted by an intent cannot be
  hard-deleted; revocation lives at the `smart_accounts.status` level
  (`:revoked` is terminal there).
  """

  def change do
    alter table(:agent_intents) do
      add :smart_account_id,
          references(:smart_accounts, type: :binary_id, on_delete: :restrict)
    end

    create index(:agent_intents, [:smart_account_id])
  end
end
