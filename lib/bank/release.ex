defmodule Bank.Release do
  @moduledoc """
  Release helpers for running Ecto migrations and rollbacks against a
  compiled release (where `mix` is not available).

  Invoked by the `bin/migrate` overlay in the Docker image:

      /app/bin/migrate

  or directly:

      /app/bin/bank eval 'Bank.Release.migrate()'
  """

  @app :bank

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
