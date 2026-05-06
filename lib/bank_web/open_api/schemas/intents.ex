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
        enum: ["transfer", "swap", "scheduled_transfer", "allocate_idle_capital"],
        description:
          "`allocate_idle_capital` is the MVP Morpho ERC-4626 USDC deposit kind " <>
            "(#203). It must be submitted with `chain: \"base-sepolia\"` " <>
            "and is approval-required by construction.",
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

defmodule BankWeb.OpenApi.Schemas.IntentEntity do
  @moduledoc """
  Persisted `AgentIntent` projection used in `IntentSubmitResponse`
  and `IntentShowResponse`. Mirrors the body the runtime accepted
  plus the `state`, `submitted_at`, and cached current-pointer
  fields.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "IntentEntity",
    description: """
    The persisted intent record. Round-trips the submitted body
    plus the lifecycle state, the runtime-assigned id and
    `submitted_at`, the deterministic `payload_hash` used for
    idempotency, and the cached current-pointer ids. The current
    pointer fields are `null` until the corresponding engine writes
    a row (decision / simulation / trust assessment / execution
    plan), so callers must not assume they are populated for a
    freshly-submitted intent.
    """,
    type: :object,
    required: [
      :id,
      :agent_id,
      :source,
      :idempotency_key,
      :payload_hash,
      :kind,
      :asset,
      :chain,
      :amount,
      :state,
      :submitted_at
    ],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      agent_id: %Schema{type: :string, example: "agent-alice"},
      source: %Schema{type: :string, enum: ~w(agent user runtime), example: "agent"},
      idempotency_key: %Schema{type: :string, example: "8f0b3c82-2e6e-4f80-bb35-4a0f02d9d5d9"},
      payload_hash: %Schema{
        type: :string,
        description: "SHA-256 of the canonical JSON encoding of the submitted body.",
        example: "a8f7..."
      },
      schema_version: %Schema{type: :string, example: "1"},
      kind: %Schema{
        type: :string,
        enum: ["transfer", "swap", "scheduled_transfer", "allocate_idle_capital"],
        description:
          "Public kind string. The persisted `AgentIntent.kind` is internally " <>
            "`:defi_yield_deposit` for `allocate_idle_capital`; the API mapping " <>
            "is bidirectional so the response always shows the public name.",
        example: "transfer"
      },
      asset: %Reference{"$ref": "#/components/schemas/Asset"},
      chain: %Reference{"$ref": "#/components/schemas/Chain"},
      amount: %Reference{"$ref": "#/components/schemas/AmountString"},
      target: %Reference{"$ref": "#/components/schemas/IntentTarget"},
      notes: %Schema{type: :string, nullable: true},
      state: %Reference{"$ref": "#/components/schemas/IntentState"},
      submitted_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      current_decision_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "Cached pointer to the active decision envelope, if any."
      },
      current_simulation_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "Cached pointer to the active simulation report, if any."
      },
      current_trust_assessment_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "Cached pointer to the active trust assessment, if any."
      },
      current_execution_plan_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "Cached pointer to the active execution plan, if any."
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.IntentSubmitResponse do
  @moduledoc """
  Body for `POST /v1/intents` (`202 Accepted`).
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "IntentSubmitResponse",
    description: """
    Response body for a successful intent submission. Returned with
    `202 Accepted`. `idempotent_replay` is `true` when the
    `(agent_id, idempotency_key)` pair already existed and the
    submitted body matched the original — the runtime does not write
    a new intent, audit event, or evaluation job in that case.
    """,
    type: :object,
    required: [:intent_id, :state, :idempotent_replay, :links, :intent],
    properties: %{
      intent_id: %Reference{"$ref": "#/components/schemas/Id"},
      state: %Reference{"$ref": "#/components/schemas/IntentState"},
      idempotent_replay: %Schema{
        type: :boolean,
        description:
          "True when the submission was deduped against an existing " <>
            "intent with the same `(agent_id, idempotency_key)` and a " <>
            "matching payload."
      },
      links: %Reference{"$ref": "#/components/schemas/Links"},
      intent: %Reference{"$ref": "#/components/schemas/IntentEntity"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.IntentShowResponse do
  @moduledoc """
  Body for `GET /v1/intents/{id}`.
  """

  require OpenApiSpex
  alias OpenApiSpex.Reference

  OpenApiSpex.schema(%{
    title: "IntentShowResponse",
    description: """
    Response body for an intent lookup. Returns the persisted
    intent record with `links` to `self` and `replay`. Decision /
    simulation / plan summaries are not inlined here in v0.1 — the
    cached `current_*_id` fields on `IntentEntity` point at the
    active rows once the engines populate them, and full history is
    available via `GET /v1/intents/{id}/replay`.
    """,
    type: :object,
    required: [:intent_id, :state, :links, :intent],
    properties: %{
      intent_id: %Reference{"$ref": "#/components/schemas/Id"},
      state: %Reference{"$ref": "#/components/schemas/IntentState"},
      links: %Reference{"$ref": "#/components/schemas/Links"},
      intent: %Reference{"$ref": "#/components/schemas/IntentEntity"}
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

defmodule BankWeb.OpenApi.Schemas.SimulationReportEntity do
  @moduledoc """
  Persisted `SimulationReport` projection embedded in
  `IntentSimulationResponse`.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "SimulationReportEntity",
    description: """
    A persisted `SimulationReport` row. `current` is `true` when the
    report is the active one for its intent (only one current report
    per intent at a time, enforced by a partial unique index).
    `status` is `"completed"` when the underlying provider preview
    succeeded and `"failed"` when it did not — failed reports still
    persist so replay can show what was attempted.
    """,
    type: :object,
    required: [
      :id,
      :provider,
      :chain,
      :asset,
      :status,
      :current,
      :generated_at,
      :freshness_ttl_seconds
    ],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      provider: %Schema{type: :string, example: "stub"},
      provider_trace_ref: %Schema{type: :string, nullable: true},
      chain: %Reference{"$ref": "#/components/schemas/Chain"},
      asset: %Reference{"$ref": "#/components/schemas/Asset"},
      status: %Schema{
        type: :string,
        enum: ["pending", "completed", "failed", "stale"],
        example: "completed"
      },
      current: %Schema{type: :boolean, description: "Active flag for this intent."},
      generated_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      freshness_ttl_seconds: %Schema{type: :integer, minimum: 1, example: 30},
      predicted_balance_changes: %Schema{
        type: :object,
        additionalProperties: true,
        description:
          ~s|Provider-shaped balance impact, e.g. `{"items": [{"asset":"USDC","delta":"-25"}]}`.|
      },
      estimated_gas: %Schema{type: :integer, nullable: true},
      estimated_fees: %Schema{
        type: :object,
        additionalProperties: true,
        nullable: true,
        description: ~s|Provider fee summary, e.g. `{"asset":"ETH","amount":"0.00015"}`.|
      },
      routing_path: %Schema{type: :object, additionalProperties: true, nullable: true},
      expected_output: %Schema{type: :string, nullable: true},
      slippage_exposure: %Schema{type: :string, nullable: true},
      failure_conditions: %Schema{type: :object, additionalProperties: true},
      supersedes_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "Prior report this one supersedes, if any."
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.IntentSimulationResponse do
  @moduledoc """
  Body for `POST /v1/intents/{id}/simulate` (`200 OK`).
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "IntentSimulationResponse",
    description: """
    Response body for a successful on-demand simulation. The runtime
    persists the produced `SimulationReport` and returns it inline
    along with the (possibly updated) intent and its links.
    `refreshed` is `true` when the produced report became the
    intent's active one (`reason == "refresh"`); for
    `pre_submit_dry_run` and `operator_inspection` the field is
    `false` and the intent's `current_simulation_id` is unchanged.
    """,
    type: :object,
    required: [:intent_id, :state, :reason, :refreshed, :links, :intent, :simulation],
    properties: %{
      intent_id: %Reference{"$ref": "#/components/schemas/Id"},
      state: %Reference{"$ref": "#/components/schemas/IntentState"},
      reason: %Schema{
        type: :string,
        enum: ["pre_submit_dry_run", "refresh", "operator_inspection"],
        example: "refresh"
      },
      refreshed: %Schema{
        type: :boolean,
        description:
          "True when the produced report supersedes the prior current report and " <>
            "the intent's `current_simulation_id` advances. Always `true` for " <>
            "`reason == \"refresh\"`, otherwise `false`."
      },
      links: %Reference{"$ref": "#/components/schemas/Links"},
      intent: %Reference{"$ref": "#/components/schemas/IntentEntity"},
      simulation: %Reference{"$ref": "#/components/schemas/SimulationReportEntity"}
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

defmodule BankWeb.OpenApi.Schemas.IntentCancelResponse do
  @moduledoc """
  Body for `POST /v1/intents/{id}/cancel` (`200 OK`).
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "IntentCancelResponse",
    description: """
    Response body for a successful intent cancellation. Returned
    with `200 OK`. `idempotent` is `true` when the call re-cancels
    an already-`cancelled` intent — no new state transition or
    audit event was written, but the response shape is identical
    to the first-time cancel for caller convenience.
    """,
    type: :object,
    required: [:intent_id, :state, :idempotent, :reason, :links, :intent],
    properties: %{
      intent_id: %Reference{"$ref": "#/components/schemas/Id"},
      state: %Reference{"$ref": "#/components/schemas/IntentState"},
      idempotent: %Schema{
        type: :boolean,
        description:
          "True when the request re-cancelled an already-`cancelled` intent; " <>
            "no new state transition or audit event was written."
      },
      reason: %Schema{
        type: :string,
        description: "The cancellation reason echoed back from the request body.",
        example: "superseded by updated intent"
      },
      links: %Reference{"$ref": "#/components/schemas/Links"},
      intent: %Reference{"$ref": "#/components/schemas/IntentEntity"}
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
