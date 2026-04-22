defmodule BankWeb.OpenApi.Schemas.Intents do
  @moduledoc """
  Per-domain request / response schemas for the `/v1/intents`
  endpoints (issue #88, epic #85).

  Scope and truthfulness:

    * Request bodies (`IntentSubmissionRequest`, `SimulationRequest`,
      `CancelRequest`) are modelled per the authoritative contract in
      `docs/bank-v0.1-runtime-flow-and-api.md`. The controller in
      `lib/bank_web/controllers/api/v1/intent_controller.ex` currently
      routes the submit / show / simulate / cancel actions through
      `BankWeb.API.V1.FallbackController.not_implemented/3` and returns
      `501`. The operation specs in that controller document this
      truthfully (see the per-action description) — request bodies
      still reflect the real contract so that #88's spec is useful to
      SDK and Postman tooling once the engine lands.
    * `IntentReplayResponse` matches the real response of
      `IntentController.replay/2`, which calls `Bank.Audit.replay/1`
      and renders via `BankWeb.API.V1.AuditJSON.replay/1`. The
      top-level keys are pinned; individual items are modelled as
      permissive objects to avoid inventing a sub-schema per
      replay-bundle entity in this issue's scope.

  Reuses shared primitives from #87 (`Id`, `Timestamp`, `AmountString`,
  `EvmAddress`, `Chain`, `Asset`, `IntentState`) via `$ref` rather
  than redefining them here.
  """
end

defmodule BankWeb.OpenApi.Schemas.IntentTarget do
  @moduledoc """
  Target of an `AgentIntent`: exactly one of
  `(counterparty_id [+ address_label_id])` or `raw_address`.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "IntentTarget",
    description: """
    Target of an agent intent. The contract requires exactly one of:

      * a `counterparty_id` (optionally with `address_label_id` when
        the counterparty has multiple labels), or
      * a `raw_address`, which is always evaluated at trust `unknown`.

    OpenAPI cannot perfectly express "exactly one of these two
    disjoint field groups"; validation happens in `Bank.Intents` at
    the runtime boundary. The shape below allows either set of fields
    so tooling can describe the contract without over-constraining.
    """,
    type: :object,
    properties: %{
      counterparty_id: %Reference{"$ref": "#/components/schemas/Id"},
      address_label_id: %Reference{"$ref": "#/components/schemas/Id"},
      raw_address: %Reference{"$ref": "#/components/schemas/EvmAddress"}
    },
    example: %{
      "counterparty_id" => "b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11"
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.IntentSubmissionRequest do
  @moduledoc """
  Body for `POST /v1/intents`.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "IntentSubmissionRequest",
    description: """
    Agent-supplied intent submission body. Matches the shape pinned
    in `docs/bank-v0.1-runtime-flow-and-api.md`.

    `idempotency_key` is required in the body even though the
    contract also requires the `Idempotency-Key` header — the body
    field is what the runtime persists for deterministic dedupe.
    `chain` accepts the full chain enum at the schema level; the
    runtime rejects non-`"base"` values at the boundary today.
    """,
    type: :object,
    required: [:idempotency_key, :source, :agent_id, :kind, :asset, :chain, :amount, :target],
    properties: %{
      idempotency_key: %Schema{type: :string, example: "8f0b3c82-2e6e-4f80-bb35-4a0f02d9d5d9"},
      source: %Schema{type: :string, example: "agent-cli@1.2.0"},
      agent_id: %Schema{type: :string, example: "agent-alice"},
      kind: %Schema{
        type: :string,
        enum: ["transfer", "swap", "scheduled_transfer"],
        example: "transfer"
      },
      asset: %Reference{"$ref": "#/components/schemas/Asset"},
      chain: %Reference{"$ref": "#/components/schemas/Chain"},
      amount: %Reference{"$ref": "#/components/schemas/AmountString"},
      target: %Reference{"$ref": "#/components/schemas/IntentTarget"},
      notes: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.SimulationRequest do
  @moduledoc """
  Body for `POST /v1/intents/{id}/simulate`.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SimulationRequest",
    description: """
    Body for an on-demand simulation request. `reason` describes why
    the simulation was requested; `"refresh"` resets the active
    report used for decisioning.
    """,
    type: :object,
    required: [:reason],
    properties: %{
      reason: %Schema{
        type: :string,
        enum: ["pre_submit_dry_run", "refresh", "operator_inspection"],
        example: "refresh"
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.CancelRequest do
  @moduledoc """
  Body for `POST /v1/intents/{id}/cancel`.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CancelRequest",
    description: """
    Operator cancellation body. `reason` is required and is
    persisted to the audit trail.
    """,
    type: :object,
    required: [:reason],
    properties: %{
      reason: %Schema{type: :string, example: "superseded by updated intent"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.IntentReplayResponse do
  @moduledoc """
  Response body for `GET /v1/intents/{id}/replay`.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "IntentReplayResponse",
    description: """
    Full replay bundle for an intent: the original intent record,
    the policy snapshot each decision referenced, the trust
    assessment chain, the simulation chain, the decision envelope
    chain, the execution plan chain, and the audit events. Rendered
    by `BankWeb.API.V1.AuditJSON.replay/1`.

    Individual item shapes (intent, policy_rule, trust_assessment,
    simulation, decision, plan, audit_event) are left as permissive
    objects in this foundation-level spec; per-entity sub-schemas
    are a follow-up once the dedicated entity schemas are needed
    elsewhere.
    """,
    type: :object,
    required: [
      :intent,
      :policy_snapshot,
      :trust_assessments,
      :simulations,
      :decisions,
      :plans,
      :audit
    ],
    properties: %{
      intent: %Schema{type: :object, additionalProperties: true},
      policy_snapshot: %Schema{
        type: :array,
        items: %Schema{type: :object, additionalProperties: true}
      },
      trust_assessments: %Schema{
        type: :array,
        items: %Schema{type: :object, additionalProperties: true}
      },
      simulations: %Schema{
        type: :array,
        items: %Schema{type: :object, additionalProperties: true}
      },
      decisions: %Schema{
        type: :array,
        items: %Schema{type: :object, additionalProperties: true}
      },
      plans: %Schema{
        type: :array,
        items: %Schema{type: :object, additionalProperties: true}
      },
      audit: %Schema{
        type: :array,
        items: %Schema{type: :object, additionalProperties: true}
      },
      screening_evidence: %Schema{type: :object, additionalProperties: true},
      stablecoin_route_evidence: %Schema{
        description: """
        Stablecoin route evaluations captured in the audit trail for
        this intent. Each entry includes the selected provider, route
        kind, policy decision, fee summary, provider errors, and the
        execution-state truth (`requires_adapter` until swap/bridge
        adapter dispatch is wired).
        """,
        type: :array,
        items: %Schema{type: :object, additionalProperties: true}
      }
    }
  })
end
