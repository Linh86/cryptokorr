defmodule BankWeb.OpenApi.Schemas.TrustAssertions do
  @moduledoc """
  Per-domain schemas for `POST /v1/trust_assertions` (issue #89).

  Reuses `TrustAssertionEntity` (defined in the counterparties schema
  file since it is embedded in the counterparty-detail preloads).
  """
end

defmodule BankWeb.OpenApi.Schemas.IssueTrustAssertionRequest do
  @moduledoc """
  Body for `POST /v1/trust_assertions`.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "IssueTrustAssertionRequest",
    description: """
    Operator-issued trust assertion. The runtime supersedes any
    prior active assertion with overlapping scope. Trust-engine-
    derived assertions take the same internal shape but never come
    through this endpoint — `issued_by` on the response distinguishes
    the two sources.
    """,
    type: :object,
    required: [:subject, :level],
    properties: %{
      subject: %Schema{
        type: :object,
        required: [:type, :id],
        properties: %{
          type: %Schema{type: :string, enum: ["counterparty", "address_label"]},
          id: %Reference{"$ref": "#/components/schemas/Id"}
        }
      },
      level: %Reference{"$ref": "#/components/schemas/TrustLevel"},
      scope: %Schema{
        type: :object,
        description:
          "Optional scope object — asset / chain / amount_ceiling / " <>
            "time_window. Unscoped `trusted` is accepted but surfaced in " <>
            "the response as `coarse: true`.",
        additionalProperties: true,
        example: %{"asset" => "USDC", "chain" => "base"}
      },
      rationale: %Schema{type: :string, nullable: true},
      expires_at: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Timestamp"}],
        nullable: true
      },
      evidence_ids: %Schema{
        type: :array,
        items: %Reference{"$ref": "#/components/schemas/Id"},
        description: "Ids of supporting evidence artifacts (optional)."
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.IssueTrustAssertionResponse do
  @moduledoc "Response for `POST /v1/trust_assertions`."

  require OpenApiSpex
  alias OpenApiSpex.Reference

  OpenApiSpex.schema(%{
    title: "IssueTrustAssertionResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Reference{"$ref": "#/components/schemas/TrustAssertionEntity"}
    }
  })
end
