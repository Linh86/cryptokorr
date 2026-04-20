defmodule Mix.Tasks.Openapi.Gen do
  @moduledoc """
  Regenerate the checked-in OpenAPI artifact from `BankWeb.ApiSpec`.

      mix openapi.gen

  Writes a deterministic JSON rendering of `BankWeb.ApiSpec.spec/0` to
  `priv/openapi/openapi.json`. The rendering sorts map keys
  alphabetically at every level so the file diffs cleanly across
  runs, hosts, and OTP versions — see `Bank.OpenApiArtifact` for the
  canonicalisation details.

  Running this task is the **only** supported way to update the
  artifact. Never hand-edit the generated file: every workflow that
  depends on it (`mix openapi.check`, CI, SDK generators) assumes it
  is a pure derived output.

  ## Typical usage

    * After any change to `BankWeb.ApiSpec`, shared components, or
      endpoint operation specs: run `mix openapi.gen`, then commit
      the updated `priv/openapi/openapi.json` alongside the spec
      change. `mix precommit` (and therefore CI) will fail if you
      forget.
    * On a clean checkout to confirm nothing drifted:
      `mix openapi.gen` and then `git diff priv/openapi/openapi.json`.
  """

  use Mix.Task

  @shortdoc "Regenerate priv/openapi/openapi.json from BankWeb.ApiSpec"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    Application.ensure_loaded(:bank)

    path = Bank.OpenApiArtifact.path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Bank.OpenApiArtifact.render())

    Mix.shell().info("Wrote #{Bank.OpenApiArtifact.relative_path()}")
  end
end
