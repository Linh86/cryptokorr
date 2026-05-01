defmodule Bank.Repo.Migrations.AddAgentKeysPauseToWorkspaces do
  use Ecto.Migration

  @moduledoc """
  Adds workspace-wide agent-key pause flag (#231-a).

  Three nullable columns on `workspaces`:

    * `agent_keys_paused_at :utc_datetime_usec` — presence = paused.
    * `agent_keys_paused_reason :text` — operator-supplied free
      string (capped at 256 chars by CHECK).
    * `agent_keys_paused_by_user_id` — FK to `users.id` with
      `on_delete: :nilify_all`. The pointer is audit metadata
      (not load-bearing), so user deletion nullifies the pointer
      without blocking. Audit events preserve actor durably.

  All columns are nullable-first; NULL = "not paused" = default.
  No backfill, no NOT NULL flip planned.

  Plus an index on `paused_by_user_id WHERE NOT NULL` so the rare
  "who paused this workspace?" lookup is cheap without bloating
  the index for the common unpaused case.
  """

  def change do
    alter table(:workspaces) do
      add :agent_keys_paused_at, :utc_datetime_usec
      add :agent_keys_paused_reason, :text

      add :agent_keys_paused_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create constraint(:workspaces, :agent_keys_paused_reason_length,
             check:
               "agent_keys_paused_reason IS NULL OR char_length(agent_keys_paused_reason) <= 256"
           )

    create index(:workspaces, [:agent_keys_paused_by_user_id],
             where: "agent_keys_paused_by_user_id IS NOT NULL",
             name: :workspaces_agent_keys_paused_by_user_idx
           )
  end
end
