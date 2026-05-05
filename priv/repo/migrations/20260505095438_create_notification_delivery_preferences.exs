defmodule Bank.Repo.Migrations.CreateNotificationDeliveryPreferences do
  use Ecto.Migration

  def change do
    create table(:notification_delivery_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      # Workspace boundary: every preference is scoped to one
      # workspace. The `Bank.Notifications` inbox table follows
      # the same scope; preferences enforce it at the same
      # boundary so a sibling workspace cannot opt this
      # workspace's users into anything.
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      # Recipient targeting: exactly one of `user_id` or
      # `role_target` must be set. The Ecto changeset enforces
      # the XOR; partial unique indexes below enforce single
      # row per (workspace, target, channel) at the DB layer.
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :role_target, :string

      # Channel vocabulary mirrors the issue body order. The
      # `:in_app` channel is intentionally NOT in this enum at
      # the column level — the inbox row IS in-app delivery; a
      # preference for in-app would be redundant. External
      # channels only.
      add :channel, :string, null: false

      # Minimum severity that triggers delivery on this channel.
      # `:info` means "deliver everything"; `:critical` means
      # "only critical alerts". Matches the existing
      # `Bank.Notifications.Notification.@severities` enum.
      add :min_severity, :string, null: false, default: "warning"

      # Toggle: false suppresses delivery on this channel even
      # if a row exists. Operators can keep the row with
      # `enabled: false` to preserve their threshold history
      # without re-creating it later.
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:notification_delivery_preferences, [:workspace_id])

    # Single preference per (workspace, user, channel) when the
    # row targets a specific user. The partial-index predicate
    # is needed because `user_id` is nullable.
    create unique_index(
             :notification_delivery_preferences,
             [:workspace_id, :user_id, :channel],
             where: "user_id IS NOT NULL",
             name: :ndp_workspace_user_channel_uidx
           )

    # Single preference per (workspace, role, channel) when the
    # row targets a role.
    create unique_index(
             :notification_delivery_preferences,
             [:workspace_id, :role_target, :channel],
             where: "role_target IS NOT NULL",
             name: :ndp_workspace_role_channel_uidx
           )
  end
end
