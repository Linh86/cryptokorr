defmodule Bank.Repo.Migrations.AddOban do
  @moduledoc """
  Install Oban's schema. See `Oban.Migration`.

  Oban backs the runtime's async queues (see `config/config.exs`).
  Running this migration is a prerequisite for booting the app against
  a real database.
  """

  use Ecto.Migration

  def up, do: Oban.Migration.up()

  def down, do: Oban.Migration.down(version: 1)
end
