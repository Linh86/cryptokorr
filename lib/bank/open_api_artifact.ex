defmodule Bank.OpenApiArtifact do
  @moduledoc """
  Shared logic for the checked-in OpenAPI artifact (issue #90, epic #85).

  Produces a deterministic JSON rendering of `BankWeb.ApiSpec.spec/0`
  at `priv/openapi/openapi.json` so the code-first spec has a stable
  derived file SDK generators, Postman, CI, and docs can consume.

  The `mix openapi.gen` and `mix openapi.check` tasks are thin
  wrappers over `render/0` and `path/0`; keeping the logic in one
  module makes the generate / check pair provably produce the same
  bytes.

  ## Determinism

  Elixir's `Map` iteration order is not portable across BEAM versions
  and hosts for large maps, so `render/0` canonicalises the spec
  before encoding:

    1. Serialize the `%OpenApi{}` struct with Jason so every
       OpenApiSpex struct is collapsed to plain JSON-compatible maps
       with string keys.
    2. Walk the resulting tree, sorting every map's keys
       alphabetically into a `Jason.OrderedObject`.
    3. Pretty-print with a trailing newline so the file is a clean
       unix text file.

  Regenerating on the same code therefore yields byte-identical
  output across runs, hosts, and Elixir/OTP versions — which is
  exactly what the drift check in `mix openapi.check` depends on.

  ## Not called from application code

  This module is a build-time helper consumed only by the two Mix
  tasks. The live OpenAPI document stays in memory via
  `BankWeb.ApiSpec.spec/0`; the JSON file is the derived artifact.
  """

  @relative_path "priv/openapi/openapi.json"

  @doc """
  Absolute path to the checked-in artifact in the source tree.

  Resolves from the current working directory, which is the project
  root for `mix` invocations. Intentionally NOT resolved from
  `:code.priv_dir/1` — that would point at the build-output copy
  under `_build/`, which is not what we commit.
  """
  @spec path() :: String.t()
  def path do
    Path.join(File.cwd!(), @relative_path)
  end

  @doc "Path rendered relative to the current working directory, for nicer CLI messages."
  @spec relative_path() :: String.t()
  def relative_path, do: Path.relative_to_cwd(path())

  @doc """
  Deterministic JSON rendering of `BankWeb.ApiSpec.spec/0`, suitable
  for writing directly to `path/0`.
  """
  @spec render() :: binary()
  def render do
    BankWeb.ApiSpec.spec()
    |> Jason.encode!()
    |> Jason.decode!()
    |> canonicalize()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  # --- internals ---

  defp canonicalize(%Jason.OrderedObject{} = ordered), do: ordered

  defp canonicalize(%{} = map) when not is_struct(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> {k, canonicalize(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other
end
