defmodule BankWeb.OpenApi.Schemas.Approvals do
  @moduledoc """
  Per-domain request / response schemas for the `/v1/approvals`
  endpoints (issue #88, epic #85).

  Shapes mirror `BankWeb.API.V1.ApprovalController` exactly:

    * `ApprovalDecisionSummary` — the subset of decision-envelope
      fields `summarize/1` projects into queue entries and into
      approve / reject responses.
    * `ApprovalQueueResponse` — list response for `GET /v1/approvals`.
    * `ApprovalActionRequest` — body shared by approve (`note`
      optional today) and reject; `actor_id` is required. The
      controller also accepts `reason`, which is persisted to audit.
    * `ApprovalActionResponse` — unified shape for approve + reject
      responses, discriminated by `dispatch`:
        * `"recorded"` — approve path; carries `next_step` hinting at
          `POST /v1/decisions/{id}/execute`.
        * `"no_dispatch"` — reject path; no follow-up.
  """
end

defmodule BankWeb.OpenApi.Schemas.ApprovalDecisionSummary do
  @moduledoc """
  Condensed decision view used in approval queue entries and
  approve/reject responses.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "ApprovalDecisionSummary",
    description: """
    Condensed decision view projected by
    `BankWeb.API.V1.ApprovalController.summarize/1`. The field set is
    deliberately narrower than `DecisionEnvelopeDetail` — queue
    entries do not need the policy-snapshot reference or the
    execution-plan list.
    """,
    type: :object,
    required: [:id, :intent_id, :outcome],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      intent_id: %Reference{"$ref": "#/components/schemas/Id"},
      outcome: %Reference{"$ref": "#/components/schemas/DecisionOutcome"},
      risk_tier: %Schema{type: :string, nullable: true, example: "elevated"},
      decided_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      decided_by: %Schema{type: :string, nullable: true},
      approval_expires_at: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Timestamp"}],
        nullable: true
      },
      reasons: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "Decision-engine reason codes carried on the envelope.",
        example: ["trust_sensitive"]
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ApprovalQueueResponse do
  @moduledoc """
  Response body for `GET /v1/approvals`.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "ApprovalQueueResponse",
    description:
      "List response returning every decision envelope currently in " <>
        "`approval_required`. The `decisions` array is unpaged today; a " <>
        "future issue may introduce cursor-based pagination.",
    type: :object,
    required: [:decisions],
    properties: %{
      decisions: %Schema{
        type: :array,
        items: %Reference{"$ref": "#/components/schemas/ApprovalDecisionSummary"}
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ApprovalActionRequest do
  @moduledoc """
  Body for `POST /v1/approvals/{decision_id}/approve` and
  `POST /v1/approvals/{decision_id}/reject`.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ApprovalActionRequest",
    description: """
    Shared body shape for the approve and reject endpoints.
    `actor_id` is required — it is captured on the successor
    envelope and every audit event. `reason` is optional and is
    persisted to the audit trail; reject paths typically set it.
    """,
    type: :object,
    required: [:actor_id],
    properties: %{
      actor_id: %Schema{type: :string, example: "ops-alice"},
      reason: %Schema{type: :string, example: "counterparty mismatch"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ApprovalNextStep do
  @moduledoc """
  Operator hint carried on `recorded` approval responses.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ApprovalNextStep",
    description: """
    Operator-facing hint returned on the `"recorded"` dispatch
    branch. Points at `POST /v1/decisions/{id}/execute` since v0.1
    does not auto-dispatch after approval.
    """,
    type: :object,
    required: [:endpoint, :message],
    properties: %{
      endpoint: %Schema{
        type: :string,
        example: "POST /v1/decisions/b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11/execute"
      },
      message: %Schema{
        type: :string,
        example: "approval recorded; execute manually with smart_account_id when ready"
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ApprovalActionResponse do
  @moduledoc """
  Response body for approve and reject actions.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "ApprovalActionResponse",
    description: """
    Unified approve / reject response. `decision` carries the
    successor envelope; `dispatch` discriminates the branch:

      * `"recorded"` — approve path, emitted with a `next_step`
        hint pointing at the execute endpoint. v0.1 does not
        auto-dispatch after approval — the operator must follow
        up with `POST /v1/decisions/{id}/execute`.
      * `"no_dispatch"` — reject path; the successor is a `block`
        envelope and nothing is scheduled.
    """,
    type: :object,
    required: [:decision, :dispatch],
    properties: %{
      decision: %Reference{"$ref": "#/components/schemas/ApprovalDecisionSummary"},
      dispatch: %Schema{
        type: :string,
        enum: ["recorded", "no_dispatch"],
        example: "recorded"
      },
      next_step: %Reference{"$ref": "#/components/schemas/ApprovalNextStep"}
    }
  })
end
