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

    ## Per-check status enum (#253)

    - `ok` — explicitly verified healthy this tick.
    - `degraded` — known partially functional (e.g. adapter 5xx,
      stuck plans present).
    - `down` — known not working (transport error, DB unreachable).
    - `not_configured` — the dependency is intentionally absent
      (e.g. local/dev without an adapter `base_url`). Treated as
      benign: a fresh checkout that has never set up the chain
      feature is not falsely degraded by that absence.
    - `unknown` — could not determine. Returned when a check times
      out or raises unexpectedly. NEVER reported as healthy at the
      overall level.

    Top-level `status` is `ok` when every check is `ok` or
    `not_configured`; otherwise `degraded` (and the response is
    `503`).

    ## Detail-field redaction (#253)

    Individual check `detail` fields are either `null` or a short
    fixed-shape enum string (e.g. `http_2xx`, `transport_error`,
    `database_unreachable`, `adapter_base_url_not_configured`). Raw
    `inspect/1` of internal structs, exception text, RPC URLs
    (which can carry credentials), and Authorization headers are
    deliberately not surfaced.
    """,
    type: :object,
    required: [:status, :service, :version, :checks],
    properties: %{
      status: %Schema{
        type: :string,
        description: "Overall health — stringified snapshot status.",
        enum: ["ok", "degraded"],
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
            status: %Schema{
              type: :string,
              enum: ["ok", "degraded", "down", "not_configured", "unknown"],
              example: "ok"
            },
            detail: %Schema{
              type: :string,
              nullable: true,
              description:
                "Sanitized detail for this check. Either `null` or one of a small fixed allowlist of enum strings; never raw exception text or credentialed URLs."
            }
          },
          additionalProperties: true
        },
        example: %{
          "database" => %{"status" => "ok", "detail" => nil},
          "adapter" => %{"status" => "ok", "detail" => "http_2xx"}
        }
      }
    }
  })
end
