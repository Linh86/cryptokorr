defmodule Bank.Repo.Migrations.AddWorkspaceIdScopingFoundation do
  @moduledoc """
  Workspace-scoping foundation (epic #153, issue #158a).

  Adds **nullable** `workspace_id` foreign keys to every table that
  holds workspace-scoped business data, plus a `workspace_id` read
  hint on `audit_events` for future filtered listing.

  Scope of THIS migration is intentionally tiny:

    * Add the column on every table in scope.
    * Add a lookup index per column so future filtered queries don't
      sequential-scan.
    * Do NOT alter any existing unique index or check constraint.
    * Do NOT make any column NOT NULL — the runtime filtering layer
      lands in #158b, and the NOT NULL flip lands later still after
      every caller has been migrated.
    * Do NOT touch the canonical audit hash payload (#161 already
      pinned the canonical fields; adding `workspace_id` to
      `Envelope.@canonical_fields` is a separate decision).

  ## FK on_delete

  `:restrict` everywhere. The workspace deletion path does not exist
  yet, and a conservative default forces an operator to handle
  cleanup explicitly before deleting a workspace. Audit, in
  particular, must never lose history to an accidental cascade.

  ## Tables touched

    * `counterparties` — workspace-scoped business entity.
    * `policy_rules` — operator-authored decision rules.
    * `agent_intents` — submission record. The existing
      `(agent_id, idempotency_key)` unique index will need to be
      lifted to `(workspace_id, agent_id, idempotency_key)` in a
      future PR; that lift is NOT part of #158a.
    * `delegations` — smart-account delegation projection. The
      existing `delegations_smart_account_active_idx` partial unique
      will likewise need a future workspace lift; not in #158a.
    * `screening_records` — wallet-screening hits.
    * `execution_plans` — execution-adapter plan rows.
    * `audit_events` — append-only audit trail. Column is added as a
      read hint so future filtered listing has an index. Stays
      nullable indefinitely; existing event hashes are unaffected
      because `Bank.Audit.Envelope` does not include `workspace_id`
      in `@canonical_fields`.
  """
  use Ecto.Migration

  @scoped_tables [
    :counterparties,
    :policy_rules,
    :agent_intents,
    :delegations,
    :screening_records,
    :execution_plans,
    :audit_events
  ]

  def change do
    for table_name <- @scoped_tables do
      alter table(table_name) do
        add :workspace_id,
            references(:workspaces, type: :binary_id, on_delete: :restrict)
      end

      create index(table_name, [:workspace_id])
    end
  end
end
