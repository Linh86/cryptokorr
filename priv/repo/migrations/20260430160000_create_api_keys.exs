defmodule Bank.Repo.Migrations.CreateApiKeys do
  @moduledoc """
  API key foundation (#218a).

  Creates the `api_keys` table that backs workspace-scoped,
  role-bound machine credentials for the `/v1` API. This migration
  ships ONLY the storage shape and indexes — the authentication
  plug and route enforcement are deferred to #218b. Until that
  lands, rows can be created and revoked but never authenticate
  anything.

  ## Storage contract

    * `secret_hash` is `BYTEA` and contains a SHA-256 hash of the
      raw 32-byte secret. The raw secret is shown ONCE on creation
      via `Bank.APIKeys.create_key/4` and is never persisted in
      cleartext anywhere — not in logs, not in audit `after_ref`,
      not in any column other than this hash.
    * `prefix` is the first 8 lowercased base32 chars after the
      `cb_` namespace and is unique globally so the auth plug can
      do an O(log n) prefix lookup before invoking the constant-
      time hash compare.
    * `role` mirrors `Bank.Workspaces.Membership.role` exactly so
      `Plugs.RequireRole` (#159a) can reuse the same hierarchy
      check whether the request is session- or key-authenticated.
    * `revoked_at` is the soft-revoke marker — once set, the key
      MUST never authenticate (#218b enforces this; this migration
      just keeps the column nullable).

  ## FK on_delete

  `:restrict` on both `workspace_id` and `created_by_user_id`,
  consistent with #158a's workspace-scoping foundation. Workspaces
  cannot be deleted while keys exist; users who created keys
  cannot be deleted while their keys are live. Deletion paths land
  alongside an explicit revoke-then-delete migration when one is
  needed.

  ## Out of scope

    * No authentication plug (#218b).
    * No route enforcement (#218b).
    * No `last_used_at` write path (a future PR adds aggregated
      usage tracking; for now the column exists but stays NULL).
    * No rotation / key versioning (a future PR; the hash is
      single-version SHA-256 today).
    * No management UI / API surface — no `/v1/api_keys` routes,
      so this migration adds zero OpenAPI impact.
  """
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: false

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      add :role, :text, null: false
      add :name, :text, null: false
      add :prefix, :text, null: false
      add :secret_hash, :binary, null: false

      add :last_used_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:api_keys, :role_valid,
             check: "role IN ('viewer','operator','admin','owner')"
           )

    create unique_index(:api_keys, [:prefix])
    create index(:api_keys, [:workspace_id])
    create index(:api_keys, [:created_by_user_id])
  end
end
