defmodule BankWeb.OpenApi.Schemas.Envelopes do
  @moduledoc """
  Shared envelope schemas for the external `/v1` OpenAPI document
  (issue #87, epic #85).

  Two envelopes live here:

    * `Links` — the `{ "self": "...", "replay": "..." }` block
      that write responses return alongside the new or updated
      object, pointing at related resources.
    * `ErrorEnvelope` — the `{ code, message, hint, retryable }`
      error body returned on every non-2xx `/v1` response. Pinned
      once here so the reusable error responses in
      `BankWeb.OpenApi.Responses` can all cite the same shape.

  Keeping these in one tiny file rather than a per-type module
  is deliberate: they are small, related, and already defined
  against the `/v1` runtime contract.
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

defmodule BankWeb.OpenApi.Schemas.ErrorEnvelope do
  @moduledoc """
  Canonical error body for every non-2xx `/v1` response.
  """

  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ErrorEnvelope",
    description: """
    Standard error envelope returned by every non-2xx `/v1`
    response. Matches the shape pinned in
    `docs/bank-v0.1-runtime-flow-and-api.md` — `{ code, message,
    hint, retryable }`. `code` is machine-readable and stable
    across deployments; `retryable` is a hard flag callers can
    branch on without parsing `message`.
    """,
    type: :object,
    required: [:code, :message, :retryable],
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
        description: "Optional operator-facing remediation hint.",
        example: "Retry with a fresh Idempotency-Key, or resend the original payload."
      },
      retryable: %Schema{
        type: :boolean,
        description:
          "Whether a well-formed retry has any chance of succeeding. " <>
            "Callers must not loop on `false`.",
        example: false
      }
    }
  })
end
