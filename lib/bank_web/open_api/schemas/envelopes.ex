defmodule BankWeb.OpenApi.Schemas.Envelopes do
  @moduledoc """
  Shared envelope schemas for the external `/v1` OpenAPI document
  (issue #87, epic #85).

  Three envelopes live here:

    * `Links` — the `{ "self": "...", "replay": "..." }` block
      that write responses return alongside the new or updated
      object, pointing at related resources.
    * `ErrorDetail` — the inner error object; matches what `/v1`
      controllers actually emit today.
    * `ErrorEnvelope` — the outer response body returned on every
      non-2xx `/v1` response: `{ "error": ErrorDetail }`. This is
      the shape `BankWeb.OpenApi.Responses` references, so every
      reusable error response points at one truth.

  ### Why outer + inner

  The runtime-flow prose doc
  (`docs/bank-v0.1-runtime-flow-and-api.md`) describes the *inner*
  shape informally, but every `/v1` controller in
  `lib/bank_web/controllers/api/v1/` wraps the payload in a single
  `error` key. Modelling only the inner shape would silently
  contradict every actual 4xx / 5xx body on the wire. Later issues
  (#88, #89) can `$ref` either layer:

    * `#/components/schemas/ErrorEnvelope` — full response body.
    * `#/components/schemas/ErrorDetail` — just the inner object,
      useful when describing individual error cases.
  """
end

defmodule BankWeb.OpenApi.Schemas.Links do
  @moduledoc """
  Related-resource links returned alongside write responses.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Links",
    description: """
    Related-resource links returned alongside write responses on
    the `/v1` contract (e.g. `{ "self": "/v1/intents/...", "replay":
    "/v1/intents/.../replay" }`). Keys are well-known relation
    names; values are relative URL strings. Callers should treat
    the key set as additive — new relations may appear without
    being breaking changes.
    """,
    type: :object,
    additionalProperties: %OpenApiSpex.Schema{type: :string},
    example: %{
      "self" => "/v1/intents/b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11",
      "replay" => "/v1/intents/b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11/replay"
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ErrorDetail do
  @moduledoc """
  Inner error object carried inside `ErrorEnvelope.error`.

  Matches the truthful common denominator of what `/v1`
  controllers emit today (see
  `lib/bank_web/controllers/api/v1/`). `code` and `message` are
  required because every error path sets both; `hint`,
  `retryable`, and `details` are optional because not every path
  emits them, and #87 deliberately refuses to pin a stricter
  universal contract than the runtime actually delivers.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ErrorDetail",
    description: """
    Inner error object carried inside `ErrorEnvelope.error`.

    `code` and `message` are guaranteed on every non-2xx `/v1`
    response. `hint`, `retryable`, and `details` are
    opportunistic — clients MUST NOT assume they are present.
    Absence of `retryable` means the caller has to decide from
    the status code alone; it does NOT imply `false`.

    `details` appears on 422 responses produced by changeset
    validation: a map from field path to the list of error
    messages for that field.
    """,
    type: :object,
    required: [:code, :message],
    properties: %{
      code: %Schema{
        type: :string,
        description: "Stable machine-readable error code.",
        example: "idempotency_conflict"
      },
      message: %Schema{
        type: :string,
        description: "Human-readable explanation.",
        example: "Idempotency-Key reused with a mismatched payload."
      },
      hint: %Schema{
        type: :string,
        nullable: true,
        description:
          "Optional operator-facing remediation hint. Some paths " <>
            "set this to `null` explicitly; callers should treat " <>
            "`null` and absence as the same signal.",
        example: "Retry with a fresh Idempotency-Key or resend the original payload."
      },
      retryable: %Schema{
        type: :boolean,
        description:
          "Optional. Present when the controller opts in; absence " <>
            "does NOT imply `false`. When present, callers must " <>
            "not loop on `false`.",
        example: false
      },
      details: %Schema{
        type: :object,
        description:
          "Optional; only present on 422 responses produced by " <>
            "changeset validation. Maps a field path (e.g. " <>
            "`\"scope.amount_ceiling\"`) to the list of error " <>
            "messages for that field.",
        additionalProperties: %Schema{
          type: :array,
          items: %Schema{type: :string}
        },
        example: %{
          "scope.amount_ceiling" => ["must be greater than 0"]
        }
      }
    },
    example: %{
      "code" => "not_found",
      "message" => "decision envelope not found"
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ErrorEnvelope do
  @moduledoc """
  Canonical outer response body for every non-2xx `/v1` response.

  Shape: a single `error` key wrapping an `ErrorDetail`. This is
  what every `/v1` controller actually emits today (see
  `lib/bank_web/controllers/api/v1/fallback_controller.ex` and
  the per-controller render helpers).
  """

  require OpenApiSpex
  alias OpenApiSpex.Reference

  OpenApiSpex.schema(%{
    title: "ErrorEnvelope",
    description: """
    Outer response body returned on every non-2xx `/v1` response.
    A single `error` key wraps an `ErrorDetail`; every reusable
    error response in `BankWeb.OpenApi.Responses` references this
    schema as its JSON body.
    """,
    type: :object,
    required: [:error],
    properties: %{
      error: %Reference{"$ref": "#/components/schemas/ErrorDetail"}
    },
    example: %{
      "error" => %{
        "code" => "idempotency_conflict",
        "message" => "Idempotency-Key reused with a mismatched payload.",
        "hint" => "Retry with a fresh Idempotency-Key or resend the original payload.",
        "retryable" => false
      }
    }
  })
end
