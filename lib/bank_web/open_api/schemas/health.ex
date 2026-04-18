defmodule BankWeb.OpenApi.Schemas.Health do
  @moduledoc """
  Health-probe response schemas for the external `/v1` OpenAPI
  document (issue #88, epic #85).

  Two response shapes:

    * `HealthReadinessResponse` — `/v1/health`. Checks is a map of
      check name to a status string (e.g. `%{"database" => "ok"}`).
    * `HealthDeepResponse` — `/v1/health/deep`. Checks is a map of
      check name to an object carrying at least `status` (more
      fields may be added additively by the operational-health
      snapshot).

  The top-level shape is identical across both endpoints: `status`,
  `service`, `version`, `checks`. Only the inner check-value
  polymorphism differs, which is why we model them as two schemas
  rather than one overly-permissive union. Both match exactly what
  `BankWeb.HealthController.readiness/2` and `deep/2` return today.
  """
end

defmodule BankWeb.OpenApi.Schemas.HealthReadinessResponse do
  @moduledoc """
  `GET /v1/health` — readiness probe response.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "HealthReadinessResponse",
    description: """
    Readiness probe payload returned by `GET /v1/health`. `status` is
    `"ok"` when every check reports `"ok"` and `"degraded"` otherwise;
    the endpoint returns `503` with a `"degraded"` body when any check
    fails. `checks` currently contains only `database`, whose value is
    `"ok"` on a reachable Postgres connection and `"error"` otherwise.
    """,
    type: :object,
    required: [:status, :service, :version, :checks],
    properties: %{
      status: %Schema{
        type: :string,
        enum: ["ok", "degraded"],
        example: "ok"
      },
      service: %Schema{type: :string, example: "bank"},
      version: %Schema{type: :string, example: "0.1.0"},
      checks: %Schema{
        type: :object,
        description: "Map of check name to status string.",
        additionalProperties: %Schema{
          type: :string,
          enum: ["ok", "error"]
        },
        example: %{"database" => "ok"}
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.HealthDeepResponse do
  @moduledoc """
  `GET /v1/health/deep` — deep operational-health probe response.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "HealthDeepResponse",
    description: """
    Deep health probe payload returned by `GET /v1/health/deep`. Runs
    every operational check in `Bank.Ops.Health.snapshot/0` (Postgres,
    adapter reachability, stuck-plan count, …) and returns `503` with a
    non-`"ok"` overall `status` if any check is degraded. `checks` maps
    check name to a check-object whose required field is `status`;
    individual checks may add fields additively.
    """,
    type: :object,
    required: [:status, :service, :version, :checks],
    properties: %{
      status: %Schema{
        type: :string,
        description: "Overall health — stringified snapshot status.",
        example: "ok"
      },
      service: %Schema{type: :string, example: "bank"},
      version: %Schema{type: :string, example: "0.1.0"},
      checks: %Schema{
        type: :object,
        description: "Map of check name to check-object.",
        additionalProperties: %Schema{
          type: :object,
          required: [:status],
          properties: %{
            status: %Schema{type: :string, example: "ok"}
          },
          additionalProperties: true
        },
        example: %{
          "database" => %{"status" => "ok"},
          "adapter" => %{"status" => "ok"}
        }
      }
    }
  })
end
