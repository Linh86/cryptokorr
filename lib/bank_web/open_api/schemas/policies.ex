defmodule BankWeb.OpenApi.Schemas.Policies do
  @moduledoc """
  Per-domain schemas for `/v1/policies*` (issue #89).

  Mirrors `BankWeb.API.V1.PolicyJSON`. Policy edits never mutate in
  place — every change is a new version, which is how replay stays
  deterministic.
  """
end

defmodule BankWeb.OpenApi.Schemas.PolicyRuleEntity do
  @moduledoc """
  Policy rule entity returned by list / create / revise / archive.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "PolicyRuleEntity",
    description: """
    Policy rule as rendered by `PolicyJSON.rule/1`. `state` reflects
    the row's position in the supersession chain
    (`draft | active | superseded | archived`); `supersedes_id`
    points at the prior version when a rule has been revised.
    """,
    type: :object,
    required: [:id, :version, :state, :rule_type, :params],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      version: %Schema{type: :integer, example: 1},
      state: %Schema{
        type: :string,
        enum: ["draft", "active", "superseded", "archived"],
        example: "active"
      },
      rule_type: %Schema{
        type: :string,
        enum: [
          "amount_limit",
          "rolling_spend_cap",
          "slippage_ceiling",
          "allowed_router",
          "allowed_asset",
          "allowed_chain",
          "autonomy_tier",
          "time_window"
        ],
        example: "amount_limit"
      },
      scope: %Schema{
        type: :object,
        description:
          "Rule scope object (e.g. `{counterparty_id: ...}` or " <>
            "`{asset: \"USDC\"}`). Shape is rule-specific.",
        additionalProperties: true
      },
      params: %Schema{
        type: :object,
        description:
          "Rule-specific parameters. Decimal values are emitted as " <>
            "strings (JSON has no native decimal).",
        additionalProperties: true
      },
      priority: %Schema{type: :integer, example: 0},
      created_by: %Schema{type: :string, nullable: true, example: "user"},
      supersedes_id: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Id"}],
        nullable: true
      },
      inserted_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      updated_at: %Reference{"$ref": "#/components/schemas/Timestamp"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.PolicyListResponse do
  @moduledoc "`GET /v1/policies` response body."

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "PolicyListResponse",
    type: :object,
    required: [:data, :page],
    properties: %{
      data: %Schema{
        type: :array,
        items: %Reference{"$ref": "#/components/schemas/PolicyRuleEntity"}
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

defmodule BankWeb.OpenApi.Schemas.PolicyResponse do
  @moduledoc "Create / revise / archive policy response body."

  require OpenApiSpex
  alias OpenApiSpex.Reference

  OpenApiSpex.schema(%{
    title: "PolicyResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Reference{"$ref": "#/components/schemas/PolicyRuleEntity"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.CreatePolicyRequest do
  @moduledoc "Body for `POST /v1/policies`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CreatePolicyRequest",
    description: """
    Create a new policy rule. `rule_type` is required; `params` and
    `scope` shape depend on the rule type and the decision engine
    validates them at the context boundary.
    """,
    type: :object,
    required: [:rule_type],
    properties: %{
      rule_type: %Schema{
        type: :string,
        enum: [
          "amount_limit",
          "rolling_spend_cap",
          "slippage_ceiling",
          "allowed_router",
          "allowed_asset",
          "allowed_chain",
          "autonomy_tier",
          "time_window"
        ]
      },
      params: %Schema{type: :object, additionalProperties: true},
      scope: %Schema{type: :object, additionalProperties: true},
      priority: %Schema{type: :integer, example: 0},
      state: %Schema{
        type: :string,
        enum: ["draft", "active", "superseded", "archived"],
        description: "Initial state. Defaults to `active`."
      },
      created_by: %Schema{type: :string, example: "user"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.RevisePolicyRequest do
  @moduledoc "Body for `POST /v1/policies/{id}/revise`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "RevisePolicyRequest",
    description: """
    Write a new version of an active policy rule. The prior version
    flips to `superseded`; in-flight evaluations continue to use
    their captured snapshot. `rule_type` cannot change across a
    revision (the prior value is carried forward).
    """,
    type: :object,
    properties: %{
      params: %Schema{type: :object, additionalProperties: true},
      scope: %Schema{type: :object, additionalProperties: true},
      priority: %Schema{type: :integer},
      state: %Schema{
        type: :string,
        enum: ["draft", "active", "superseded", "archived"]
      },
      created_by: %Schema{type: :string}
    }
  })
end
