defmodule Bank.Repo.Migrations.CreateWorkspaces do
  @moduledoc """
  Workspaces table for the alpha gate (epic #153, issue #155).

  A workspace is the unit of product scope: counterparties, policies,
  delegations, intents, decisions all eventually pivot off
  `workspace_id` (issue #158). This migration only creates the
  workspaces themselves — it does not yet add the foreign key to any
  existing scoped table; that lands with #158.

  Slug is the human-friendly handle used in URLs and the operator
  Telegram bot. Names are display-only.
  """
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :slug, :text, null: false
      add :name, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspaces, ["lower(slug)"], name: :workspaces_lower_slug_idx)
  end
end
