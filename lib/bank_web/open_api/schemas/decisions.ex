defmodule BankWeb.OpenApi.Schemas.Decisions do
  @moduledoc """
  Per-domain request / response schemas for the `/v1/decisions`
  endpoints (issue #88, epic #85).

  All shapes mirror `BankWeb.API.V1.DecisionController` exactly as
  it renders today:

    * `DecisionShowResponse` — `show/2` response body
      (`{data: DecisionEnvelopeDetail}`).
    * `DecisionEnvelopeDetail` — the envelope plus its
      `execution_plans` array.
    * `ExecutionPlanSummary` — the minimum subset of plan fields
      the execute/show responses surface.
    * `ExecuteDecisionRequest` — body for
      `POST /v1/decisions/{id}/execute` (`smart_account_id`
      required, `reason` optional).
    * `ExecuteDecisionResponse` — the `202` body
      (`{data: ExecutionPlanSummary, status: "execution_enqueued"}`).
  """
end

defmodule BankWeb.OpenApi.Schemas.ExecutionPlanSummary do
  @moduledoc """
  Execution-plan subset returned by the decision show and execute
  endpoints.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "ExecutionPlanSummary",
    description: """
    Summary fields surfaced on execution plans by the `/v1/decisions`
    endpoints today. Mirrors the keys produced in
    `BankWeb.API.V1.DecisionController.show/2` and `execute/2`.
    """,
    type: :object,
    required: [:id, :execution_status, :active, :smart_account_id],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      decision_id: %Reference{"$ref": "#/components/schemas/Id"},
      intent_id: %Reference{"$ref": "#/components/schemas/Id"},
      execution_status: %Schema{
        type: :string,
        description: "Lifecycle state of the execution plan.",
        example: "prepared"
      },
      active: %Schema{type: :boolean, example: true},
      smart_account_id: %Schema{type: :string, example: "sa_primary"},
      final_outcome: %Schema{
        type: :string,
        nullable: true,
        description: "Terminal chain outcome once known.",
        example: nil
      },
      final_reason: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.DecisionEnvelopeDetail do
  @moduledoc """
  `DecisionEnvelope` detail returned by `GET /v1/decisions/{id}`.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "DecisionEnvelopeDetail",
    description: """
    Decision envelope detail returned under the `data` key of
    `GET /v1/decisions/{id}`. Mirrors the fields projected by
    `BankWeb.API.V1.DecisionController.show/2` — including the
    current-envelope flag, the supersession pointer, the policy
    snapshot reference, and the current execution plan list.
    """,
    type: :object,
    required: [:id, :intent_id, :outcome, :state, :current, :execution_plans],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      intent_id: %Reference{"$ref": "#/components/schemas/Id"},
      outcome: %Reference{"$ref": "#/components/schemas/DecisionOutcome"},
      risk_tier: %Schema{type: :string, nullable: true, example: "elevated"},
      state: %Schema{
        type: :string,
        description: "Envelope state.",
        example: "decided"
      },
      current: %Schema{type: :boolean, example: true},
      decided_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      decided_by: %Schema{type: :string, nullable: true, example: "decision_engine"},
      approval_expires_at: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Timestamp"}],
        nullable: true
      },
      supersedes_id: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Id"}],
        nullable: true
      },
      policy_snapshot_ref: %Schema{type: :string, nullable: true},
      execution_plans: %Schema{
        type: :array,
        items: %Reference{"$ref": "#/components/schemas/ExecutionPlanSummary"}
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.DecisionShowResponse do
  @moduledoc """
  Response body for `GET /v1/decisions/{id}`.
  """

  require OpenApiSpex
  alias OpenApiSpex.Reference

  OpenApiSpex.schema(%{
    title: "DecisionShowResponse",
    description:
      "Outer envelope around the decision detail. `data` carries the " <>
        "`DecisionEnvelopeDetail`; no other top-level keys are currently set.",
    type: :object,
    required: [:data],
    properties: %{
      data: %Reference{"$ref": "#/components/schemas/DecisionEnvelopeDetail"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ExecuteDecisionRequest do
  @moduledoc """
  Body for `POST /v1/decisions/{id}/execute`.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ExecuteDecisionRequest",
    description: """
    Body for manual execute. `smart_account_id` is required and
    selects the delegation / smart account the adapter should sign
    with. `reason` is optional and is persisted to audit; it
    defaults to `"manual_confirm"` when absent.
    """,
    type: :object,
    required: [:smart_account_id],
    properties: %{
      smart_account_id: %Schema{type: :string, example: "sa_primary"},
      reason: %Schema{
        type: :string,
        enum: ["hold_release", "retry", "manual_confirm"],
        example: "manual_confirm"
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ExecuteDecisionResponse do
  @moduledoc """
  Response body for `POST /v1/decisions/{id}/execute`.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "ExecuteDecisionResponse",
    description:
      "202 response body: the newly enqueued execution plan under `data`, " <>
        "plus a fixed `status` tag used by the runtime as a step marker.",
    type: :object,
    required: [:data, :status],
    properties: %{
      data: %Reference{"$ref": "#/components/schemas/ExecutionPlanSummary"},
      status: %Schema{
        type: :string,
        enum: ["execution_enqueued"],
        example: "execution_enqueued"
      }
    }
  })
end
