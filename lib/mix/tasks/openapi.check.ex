defmodule Mix.Tasks.Openapi.Check do
  @moduledoc """
  Verify the checked-in OpenAPI artifact matches `BankWeb.ApiSpec`.

      mix openapi.check

  Regenerates the artifact bytes in memory and compares them to the
  committed `priv/openapi/openapi.json`. Exits non-zero on mismatch
  or if the artifact file is missing.

  This task is part of the `mix precommit` alias, so local precommit
  runs and CI both fail on artifact drift without any additional
  workflow wiring.

  ## What to do when this fails

    * Artifact out of date (committed file differs from current
      spec): run `mix openapi.gen` and commit the updated file
      alongside your spec change.
    * Artifact missing: run `mix openapi.gen` once; the file lives
      at `priv/openapi/openapi.json` and should be tracked in git.

  This task never mutates the file — it only reports.
  """

  use Mix.Task

  @shortdoc "Fail if priv/openapi/openapi.json has drifted from BankWeb.ApiSpec"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    Application.ensure_loaded(:bank)

    path = Bank.OpenApiArtifact.path()
    expected = Bank.OpenApiArtifact.render()

    case File.read(path) do
      {:ok, ^expected} ->
        Mix.shell().info(
          "OpenAPI artifact is up to date: #{Bank.OpenApiArtifact.relative_path()}"
        )

      {:ok, _other} ->
        Mix.raise("""
        OpenAPI artifact is out of date.

          Committed file:  #{Bank.OpenApiArtifact.relative_path()}

        Regenerate and commit:

          mix openapi.gen
          git add #{Bank.OpenApiArtifact.relative_path()}
        """)

      {:error, reason} ->
        Mix.raise("""
        OpenAPI artifact not found.

          Expected at:  #{Bank.OpenApiArtifact.relative_path()}
          Reason:       #{inspect(reason)}

        Generate it once with:

          mix openapi.gen
        """)
    end
  end
end
