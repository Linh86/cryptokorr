defmodule Bank.Repo.Migrations.CreateAccessInvites do
  @moduledoc """
  Access invite / allowlist table for the alpha gate (epic #153,
  issue #156).

  Google OAuth proves identity. This table answers the next question:
  *is this person allowed in, and into which workspace?* Two invite
  shapes are supported:

    * `exact_email` — one specific address, lowercased + matched
      case-insensitively. Sole row uniquely identifies the invitee
      per workspace.
    * `domain` — any address whose domain part matches, also
      case-insensitive. Useful for "anyone @customer-corp.com that
      signs up" without naming each person up-front.

  Exact-email invites are the strong signal — matching one creates a
  membership immediately. Domain invites are conservative: matching
  one records the match in audit but leaves the user in
  `:pending_access` until an admin approves them via #157.

  ## Status lifecycle

      active ──match (exact_email)──▶ accepted
      active ──operator action─────▶ revoked
      active ──expires_at < now────▶ expired (set lazily on read)

  `accepted` and `revoked` are terminal. `expired` is set lazily by
  `Bank.Workspaces.find_matching_invite_for_email/1` when it
  encounters an active row whose `expires_at` is in the past — that
  way the operator UI shows the right state without a background
  sweeper.

  ## Uniqueness

  Two partial unique indexes prevent duplicate *active* invites:

    * `(workspace_id, lower(email))` for `invite_type = 'exact_email'`
    * `(workspace_id, lower(domain))` for `invite_type = 'domain'`

  Revoked or accepted invites are not subject to those indexes, so an
  operator can revoke and re-invite without DB churn. Lookup indexes
  on `(lower(email), status)` and `(lower(domain), status)` keep the
  `find_matching_invite_for_email/1` read path on a sub-millisecond
  plan even with many tenants.
  """
  use Ecto.Migration

  def change do
    create table(:access_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: false

      add :invite_type, :text, null: false

      add :email, :text
      add :domain, :text

      add :role, :text, null: false
      add :status, :text, null: false, default: "active"

      add :invited_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :accepted_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :expires_at, :utc_datetime_usec
      add :accepted_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:access_invites, :invite_type_valid,
             check: "invite_type IN ('exact_email', 'domain')"
           )

    create constraint(:access_invites, :role_valid,
             check: "role IN ('owner', 'admin', 'operator', 'viewer')"
           )

    create constraint(:access_invites, :status_valid,
             check: "status IN ('active', 'accepted', 'revoked', 'expired')"
           )

    create constraint(:access_invites, :shape_valid,
             check: """
             (invite_type = 'exact_email' AND email IS NOT NULL AND domain IS NULL) OR
             (invite_type = 'domain' AND domain IS NOT NULL AND email IS NULL)
             """
           )

    create unique_index(:access_invites, [:workspace_id, "lower(email)"],
             name: :access_invites_active_email_idx,
             where: "invite_type = 'exact_email' AND status = 'active'"
           )

    create unique_index(:access_invites, [:workspace_id, "lower(domain)"],
             name: :access_invites_active_domain_idx,
             where: "invite_type = 'domain' AND status = 'active'"
           )

    create index(:access_invites, ["lower(email)", :status],
             name: :access_invites_lookup_email_idx,
             where: "invite_type = 'exact_email'"
           )

    create index(:access_invites, ["lower(domain)", :status],
             name: :access_invites_lookup_domain_idx,
             where: "invite_type = 'domain'"
           )

    create index(:access_invites, [:workspace_id, :status],
             name: :access_invites_workspace_status_idx
           )
  end
end
