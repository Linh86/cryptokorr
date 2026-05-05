defmodule Bank.Repo.Migrations.CreateNotificationDeliveries do
  use Ecto.Migration

  def change do
    create table(:notification_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      # Per-channel attempt log for one inbox notification. We
      # never delete inbox rows on delivery failure (acceptance
      # bullet: "in-app notification still exists even if
      # external delivery fails"); this row tracks the
      # external-channel side independently.
      add :notification_id,
          references(:notifications, type: :binary_id, on_delete: :delete_all),
          null: false

      # Workspace denormalization for cheap workspace-scoped
      # reads (the LiveView inbox UI #235 will surface delivery
      # state alongside the inbox row; this index is the cheap
      # join key).
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      # External channels only. `:in_app` is implicit (the
      # `notifications` row itself).
      add :channel, :string, null: false

      # Status enum:
      #   :queued             — waiting for the worker
      #   :delivering         — in-flight (locked by the worker)
      #   :delivered          — terminal success
      #   :failed             — transient failure; will retry
      #                         after `next_attempt_at`
      #   :permanently_failed — terminal: hit the retry cap
      add :status, :string, null: false, default: "queued"

      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 5

      # Last-error label is from a closed allowlist
      # (`:transport_error`, `:provider_5xx`, `:provider_4xx`,
      # `:malformed_payload`, ...). Never carries a raw
      # response body or a free-text reason — pinned by tests.
      add :last_error, :string

      add :next_attempt_at, :utc_datetime_usec
      add :delivered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:notification_deliveries, [:notification_id])
    create index(:notification_deliveries, [:workspace_id])
    create index(:notification_deliveries, [:status, :next_attempt_at])

    # Idempotency: at most one delivery row per (notification,
    # channel). A second `enqueue_deliveries/1` call must not
    # double-enqueue a delivery for the same channel.
    create unique_index(
             :notification_deliveries,
             [:notification_id, :channel],
             name: :nd_notification_channel_uidx
           )
  end
end
