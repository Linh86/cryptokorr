defmodule Bank.Repo.Migrations.AddExpiresAtToPauses do
  use Ecto.Migration

  @moduledoc """
  Adds optional `expires_at` to `pauses` for #228 Phase 1.5 — auto-
  resume sweeper.

  `expires_at` is nullable: most pauses today are operator-driven
  with no expiry. When set, it carries the wall-clock UTC instant
  at or after which `Bank.Runtime.Workers.SweepExpiredPauses`
  resumes the pause automatically. The sweeper writes
  `resumed_at = NOW()` (or the recorded `expires_at`, whichever it
  flips to) so the existing partial unique index
  `pauses_active_uniq` continues to enforce single-active without
  changes — the active definition stays `resumed_at IS NULL`.

  Adds a partial index on `expires_at` for active pauses with an
  expiry, so the sweeper can scan with `WHERE resumed_at IS NULL
  AND expires_at IS NOT NULL AND expires_at <= now()` cheaply
  even at scale. Pauses without `expires_at` (the common case)
  do not bloat this index.

  No backfill: existing rows keep `expires_at NULL` and behave as
  manual-resume-only.
  """

  def change do
    alter table(:pauses) do
      add :expires_at, :utc_datetime_usec, null: true
    end

    create index(:pauses, [:expires_at],
             where: "resumed_at IS NULL AND expires_at IS NOT NULL",
             name: :pauses_active_expiring_idx
           )
  end
end
