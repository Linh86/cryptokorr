defmodule Bank.Repo.Migrations.AddNotifyExecutionConfirmedToWorkspaces do
  use Ecto.Migration

  @moduledoc """
  Add the `notify_execution_confirmed` opt-in flag to `workspaces`
  (#234). When `true`, `Bank.Notifications.Emitter.emit_execution_outcome/1`
  surfaces `:info` notifications for the success-side terminal
  status (`execution.confirmed`). When `false` (default) the
  emitter remains silent on confirmed — the operator does not
  get a row for every happy-path payment.

  Default `false` so existing workspaces keep today's behaviour
  on apply. Additive migration; nullable: false with default
  matches the same posture as the existing `mainnet_enabled`
  flag (#178).
  """

  def change do
    alter table(:workspaces) do
      add :notify_execution_confirmed, :boolean, null: false, default: false
    end
  end
end
