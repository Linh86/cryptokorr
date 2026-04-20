defmodule BankWeb.OpenApi.Schemas.Audit do
  @moduledoc """
  Per-domain schemas for `GET /v1/audit` (issue #89).

  Mirrors `BankWeb.API.V1.AuditJSON.index/1` and `render_event/1`
  exactly. Audit events cannot be edited via any endpoint — the
  stream is append-only.
  """
end

defmodule BankWeb.OpenApi.Schemas.AuditEventEntity do
  @moduledoc """
  Audit event entity returned by the `/v1/audit` list endpoint and
  embedded in intent replay bundles.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "AuditEventEntity",
    description: """
    Audit event projected by `AuditJSON.render_event/1`.
    `correlation_id` is the intent id that ties related events
    together across the runtime flow.
    """,
    type: :object,
    required: [:id, :ts, :event_type],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      ts: %Reference{"$ref": "#/components/schemas/Timestamp"},
      actor: %Schema{
        type: :string,
        nullable: true,
        description: "Actor category (`\"user\"`, `\"adapter\"`, `\"system\"`, …).",
        example: "user"
      },
      actor_id: %Schema{type: :string, nullable: true},
      event_type: %Schema{type: :string, example: "intent.submitted"},
      subject_type: %Schema{type: :string, nullable: true, example: "agent_intent"},
      subject_id: %Schema{
        type: :string,
        nullable: true,
        description:
          "Opaque id of the event subject. Typically a UUID; may also be a " <>
            "smart-account id or an on-chain address for non-intent subjects."
      },
      correlation_id: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Id"}],
        nullable: true,
        description: "Intent id the event is correlated to, when applicable."
      },
      before_ref: %Schema{type: :string, nullable: true},
      after_ref: %Schema{type: :string, nullable: true},
      payload_hash: %Schema{type: :string, nullable: true},
      schema_version: %Schema{type: :integer, nullable: true, example: 1}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.AuditListResponse do
  @moduledoc "`GET /v1/audit` response body."

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "AuditListResponse",
    description:
      "Paged audit stream. `next_cursor` is an opaque string; callers pass " <>
        "it back as `?cursor=...` to retrieve the next page.",
    type: :object,
    required: [:data, :page],
    properties: %{
      data: %Schema{
        type: :array,
        items: %Reference{"$ref": "#/components/schemas/AuditEventEntity"}
      },
      page: %Schema{
        type: :object,
        required: [:next_cursor],
        properties: %{
          next_cursor: %Schema{type: :string, nullable: true}
        }
      }
    }
  })
end
