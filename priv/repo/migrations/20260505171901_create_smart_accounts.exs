defmodule Bank.Repo.Migrations.CreateSmartAccounts do
  use Ecto.Migration

  @moduledoc """
  Creates the `smart_accounts` table for #183 — the workspace-scoped
  domain model for smart contract accounts (ERC-4337 / kernel
  smart accounts) that today live as opaque
  `delegation.smart_account_id` strings.

  ## Why this exists

  Today, `delegation.smart_account_id` and
  `execution_plan.smart_account_id` are bare `:text` columns.
  Phoenix never parses them — they are free-form identifiers
  whose meaning lives outside the database. That works while
  every workspace runs at most one smart account, but breaks
  the multi-account epic (#167) acceptance:

    * "Workspace can have multiple smart accounts."
    * "Smart account status is queryable without scanning
      delegations."
    * "Cross-workspace duplicate address behavior is explicit
      and tested."

  This migration introduces a workspace-scoped
  `smart_accounts` table so smart-account state has a first-
  class home, distinct from delegation lifecycle. Existing
  callers continue to read `delegation.smart_account_id`
  unchanged — this PR is **additive**. Wiring the new model
  into intent / decision / dispatch paths is the deliverable
  of #184 (intent contract) and #185 (account-aware routing).

  ## Backfill posture

  The issue body says "Migration/backfill from existing
  delegation/smart-account config if applicable." After
  inspection: there is no hardcoded config to backfill from
  (the codebase reads chain/asset/workspace from the database,
  not config files), and `delegation.smart_account_id` strings
  are opaque (free-form, never parsed) so we don't know each
  row's `(workspace_id, chain, address)` triple from the
  string alone. The existing test fixture pattern is
  `"sa-<int>"` — clearly not on-chain addresses.

  The migration therefore creates an **empty** `smart_accounts`
  table. #184 / #185 backfill from the *new* row each
  workspace creates explicitly when it provisions a smart
  account through the new flow.

  ## Columns

    * `workspace_id` — `null: false`. FK with
      `on_delete: :restrict` (workspace deletion is a manual
      operator action; smart accounts never cascade-delete).
    * `chain` — `null: false`. Lowercased chain id (e.g.
      `"base"`, `"base-sepolia"`); same vocabulary as
      `delegations.chain` (default `"base"`).
    * `address` — `null: false`. The smart account's
      on-chain address. Stored lowercased + checksum-stripped
      at the changeset boundary so duplicate detection is
      reliable across operator typing.
    * `status` — `null: false`, default `"provisioning"`. The
      schema layer constrains values to
      `:provisioning | :active | :inactive | :revoked`.
    * `owner_user_id` — `null: true`. FK with
      `on_delete: :nilify_all`. Nullable because operator-
      provisioned accounts may not have a 1:1 user binding
      yet (#169 wallet identity binding handles that).
    * `owner_wallet_address` — `null: true`. EOA address that
      controls the smart account, when known. Independent of
      `owner_user_id` because a wallet may not have a Bank
      user record.
    * `metadata` — `null: false`, default `'{}'::jsonb`. Free-
      form provisioning / deployment metadata (factory
      address, deploy tx hash, kernel version, etc.). Render
      surfaces must escape — the schema's free-form metadata
      is exempt from the `:unsafe_text` gate that title-style
      columns get because no rendering happens at the data
      layer.
    * `provisioned_at` — `null: true`. Wall-clock for
      `:active` transition; separate from `inserted_at` so a
      future replay/import pipeline can backfill historical
      rows.
    * `revoked_at` — `null: true`. Wall-clock for `:revoked`
      transition.
    * `inserted_at` / `updated_at` — standard.

  ## Indexes

    * `(workspace_id, chain, lower(address))` UNIQUE — one
      smart account per workspace+chain+address triple. Cross-
      workspace duplicate addresses are explicitly allowed
      (the same on-chain address could legitimately be used
      from different workspaces in some configurations,
      mirroring how `access_invites` allow the same email in
      different workspaces). The `lower(address)` predicate
      keeps the index canonical even if a future caller
      forgets to lowercase at the boundary.
    * `(workspace_id, status, inserted_at DESC)` — operator
      listing.
    * `(owner_user_id, status)` partial index — "list smart
      accounts I own" without scanning the whole table.
  """

  def change do
    create table(:smart_accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: false

      add :chain, :string, null: false, size: 32
      add :address, :string, null: false, size: 64

      add :status, :string, null: false, default: "provisioning", size: 16

      add :owner_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all),
          null: true

      add :owner_wallet_address, :string, null: true, size: 64

      add :metadata, :map, null: false, default: %{}

      add :provisioned_at, :utc_datetime_usec, null: true
      add :revoked_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # Canonical uniqueness: one (workspace, chain, address) row
    # regardless of operator casing.
    create unique_index(
             :smart_accounts,
             ["workspace_id", "chain", "lower(address)"],
             name: :smart_accounts_workspace_chain_address_uidx
           )

    create index(
             :smart_accounts,
             [:workspace_id, :status, :inserted_at],
             name: :smart_accounts_workspace_status_idx
           )

    create index(
             :smart_accounts,
             [:owner_user_id, :status],
             where: "owner_user_id IS NOT NULL",
             name: :smart_accounts_owner_user_status_idx
           )
  end
end
