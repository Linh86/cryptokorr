defmodule Bank.Repo.Migrations.CreateAccessInvites do
  @moduledoc """
  Invite-only allowlist for the alpha gate (epic #153, issue #156).

  An access invite says "this email (or any email under this domain)
  may join workspace X with role Y on next login". Two invite types:

    * `exact_email` — `email` is set, `domain` is null. On a successful
      OAuth login that matches by lowercased email, the invite is
      consumed (`status = accepted`) and a membership is created
      automatically.
    * `domain` — `domain` is set, `email` is null. Matches any
      authenticated user whose email's after-`@` part matches.
      Domain matches do NOT auto-create memberships; they remain
      pending until an operator approves the request via the admin
      flow that lands with issue #157.

  Status lifecycle (`active` → terminal):

    * `active` — eligible to match a login.
    * `accepted` — exact-email invite already consumed; idempotent
      on repeat login.
    * `revoked` — operator-cancelled; never matches.
    * `expired` — past `expires_at`; never matches.

  Audit hooks for invite creation / acceptance / revocation are
  deferred to issue #161 to keep this migration small.
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
          references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      add :accepted_by_user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: true

      add :matched_by_user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: true

      add :expires_at, :utc_datetime_usec
      add :accepted_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :matched_at, :utc_datetime_usec

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

    # XOR on the matcher column — exact-email rows carry email and no
    # domain; domain rows carry domain and no email. Enforcing it at
    # the DB stops any malformed row from sneaking in.
    create constraint(:access_invites, :invite_type_fields_match,
             check:
               "(invite_type = 'exact_email' AND email IS NOT NULL AND domain IS NULL) OR " <>
                 "(invite_type = 'domain' AND domain IS NOT NULL AND email IS NULL)"
           )

    # Lookup paths use `lower(email)` and `lower(domain)`. Functional
    # indexes match the way `Bank.Access` queries are written.
    create index(:access_invites, ["lower(email)"],
             name: :access_invites_lower_email_idx,
             where: "email IS NOT NULL"
           )

    create index(:access_invites, ["lower(domain)"],
             name: :access_invites_lower_domain_idx,
             where: "domain IS NOT NULL"
           )

    # At most one *active* exact-email invite per workspace × email,
    # and at most one *active* domain invite per workspace × domain.
    # Once an invite transitions to accepted/revoked/expired it leaves
    # the partial index so a new active invite can be issued.
    create unique_index(:access_invites, [:workspace_id, "lower(email)"],
             name: :access_invites_active_workspace_email_idx,
             where: "status = 'active' AND invite_type = 'exact_email'"
           )

    create unique_index(:access_invites, [:workspace_id, "lower(domain)"],
             name: :access_invites_active_workspace_domain_idx,
             where: "status = 'active' AND invite_type = 'domain'"
           )
  end
end
