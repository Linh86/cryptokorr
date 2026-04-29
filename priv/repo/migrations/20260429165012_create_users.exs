defmodule Bank.Repo.Migrations.CreateUsers do
  @moduledoc """
  Initial users table for the auth foundation (epic #153, issue #154).

  Identity-only schema: Google OAuth's `(provider, provider_subject)`
  pair plus a normalized email and a `status` field. We store no
  OAuth tokens (access / refresh / id) — Google is identity, not a
  capability we proxy.

  Status defaults to `pending_access`; workspace approval (issues
  #155-#157) flips it to `active`. Disabled users keep their row for
  audit replay but cannot start a session.
  """
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :email, :text, null: false
      add :name, :text
      add :avatar_url, :text

      add :provider, :text, null: false
      add :provider_subject, :text, null: false

      add :status, :text,
        null: false,
        default: "pending_access"

      add :last_login_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # `(provider, provider_subject)` is the canonical identity tuple.
    # A Google user's `sub` is stable across email changes; pinning
    # uniqueness here is what makes "find or create" idempotent.
    create unique_index(:users, [:provider, :provider_subject], name: :users_provider_subject_idx)

    # Email is stored as the user supplied it (normalized at the app
    # layer to lowercase + trimmed), and uniqueness is enforced
    # case-insensitively at the DB. Functional unique index on
    # `lower(email)` matches the app-layer normalization.
    create unique_index(:users, ["lower(email)"], name: :users_lower_email_idx)

    create constraint(:users, :status_valid,
             check: "status IN ('pending_access', 'active', 'disabled')"
           )

    create constraint(:users, :provider_valid, check: "provider IN ('google')")
  end
end
