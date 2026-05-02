defmodule BankWeb.OpenApi.Schemas.Security do
  @moduledoc """
  Per-domain schemas for `/v1/security/*` (issue #89).

  Matches `BankWeb.API.V1.SecurityController` exactly. The prose
  contract states:

    * Pause is soft — new `executing` transitions are blocked but
      pending confirmations keep polling, agents can still submit,
      and decisions may still be written.
    * Resume does not auto-flush the accumulated queue into
      execution.
    * Revoke is **one-way at the API**. Re-delegation is intentionally
      not a v1 API operation; it is an operator flow in the web app's
      security console, outside external-API scope.

  The revoke endpoint returns `202 revoke_enqueued` with the
  `smart_account_id` as its handle — the final chain-side state
  change is delivered asynchronously via the `security:events`
  realtime channel and the audit stream, never in the synchronous
  response.
  """
end

defmodule BankWeb.OpenApi.Schemas.SecurityPauseRequest do
  @moduledoc "Body for `POST /v1/security/pause`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SecurityPauseRequest",
    description: """
    Request body for `pause`. `reason` defaults to
    `"operator_requested"`; the value is persisted to audit. See
    the `scope` property for the truthful parse semantics — the
    runtime does NOT reject unrecognised scope values today.
    """,
    type: :object,
    properties: %{
      scope: %Schema{
        type: :string,
        description: """
        Pause scope. The controller parses two shapes:

          * `"counterparty:{id}"` → counterparty-scoped pause.
          * anything else (omitted, `null`, `"global"`, or any
            unrecognised value) → global pause.

        The runtime does NOT currently reject unknown `scope`
        values — a string that does not match
        `"counterparty:{id}"` is silently treated as global. This
        field is documented as a plain string rather than an enum
        to stay truthful to that parse behavior. A future issue
        may tighten the runtime to reject unknown values.
        """,
        example: "global"
      },
      reason: %Schema{type: :string, example: "operator_requested"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.SecurityResumeRequest do
  @moduledoc "Body for `POST /v1/security/resume`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SecurityResumeRequest",
    description: """
    Request body for `resume`. Same `scope` parse semantics as
    pause — the runtime does not reject unrecognised values.
    """,
    type: :object,
    properties: %{
      scope: %Schema{
        type: :string,
        description:
          "Resume scope. Controller recognises `\"counterparty:{id}\"` and " <>
            "treats every other value (including omitted, `\"global\"`, or " <>
            "any unrecognised string) as a global resume. Unknown values " <>
            "are NOT rejected at the runtime today.",
        example: "global"
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.SecurityStateResponse do
  @moduledoc """
  Response body for `POST /v1/security/pause` and
  `POST /v1/security/resume`.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SecurityStateResponse",
    description: """
    Pause / resume response. `status` carries both the successful
    transition (`"paused"` / `"resumed"`) and the already-in-state
    idempotent case (`"already_paused"` / `"already_running"`). The
    already-in-state cases still return `200` — they are not
    errors.
    """,
    type: :object,
    required: [:status, :scope],
    properties: %{
      status: %Schema{
        type: :string,
        enum: ["paused", "already_paused", "resumed", "already_running"],
        example: "paused"
      },
      scope: %Schema{
        type: :string,
        description:
          "Echoed scope. Always either `\"global\"` or " <>
            "`\"counterparty:{id}\"` — the response renders the parsed " <>
            "scope, so unrecognised request-side values appear here as " <>
            "`\"global\"` (see the request schemas' `scope` notes).",
        example: "global"
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.RevokeDelegationRequest do
  @moduledoc "Body for `POST /v1/security/revoke_delegation`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "RevokeDelegationRequest",
    type: :object,
    required: [:smart_account_id],
    properties: %{
      smart_account_id: %Schema{type: :string, example: "sa_primary"},
      reason: %Schema{
        type: :string,
        description:
          "Audit-persisted reason. Defaults to `\"operator_requested\"` " <>
            "when absent.",
        example: "operator_requested"
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.AgentKeysPauseRequest do
  @moduledoc "Body for `POST /v1/security/pause_agent_keys` (#231-b)."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AgentKeysPauseRequest",
    description: """
    Request body for `pause_agent_keys`. Only the optional `reason`
    field is read — `workspace_id` from the body is silently
    ignored; the workspace is taken from the calling key's
    `current_scope`. `reason` is capped at 256 characters by the
    schema CHECK; longer values return `422 invalid_reason`.
    """,
    type: :object,
    properties: %{
      reason: %Schema{
        type: :string,
        maxLength: 256,
        description: """
        Optional operator-supplied reason persisted to both the
        workspace row and the `agent_keys.paused` audit event.
        Empty/whitespace-only is treated as `nil`.
        """,
        example: "credential leak under investigation"
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.AgentKeysPauseStateResponse do
  @moduledoc """
  Response body for `POST /v1/security/pause_agent_keys` and
  `POST /v1/security/resume_agent_keys` (#231-b).

  ## Bootstrap caveat (load-bearing)

  Once `paused: true`, every API key in this workspace returns
  `401 invalid_credentials` from `/v1` — including the key that
  just made the pause call. Resume MUST come from a non-API-key
  path: the LiveView Security console at `/security` (Google OAuth
  session) or `Bank.APIKeys.resume_workspace/3` from IEx. There
  is no API-side resume bypass.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "AgentKeysPauseStateResponse",
    description: """
    Workspace agent-key pause state. Returned by both pause and
    resume on `200`. Idempotent re-call returns the same payload
    as the original transition.

    `paused` is the boolean source of truth; the timestamp /
    user / reason fields are populated only when `paused: true`.

    ## Bootstrap caveat (load-bearing)

    Once paused, every API key in this workspace returns
    `401 invalid_credentials` from `/v1` — including the key that
    just made the pause call. Resume MUST come from a non-API-key
    path: the LiveView Security console at `/security` (Google
    OAuth session) or `Bank.APIKeys.resume_workspace/3` from IEx.
    There is no API-side resume bypass.
    """,
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:workspace_id, :paused],
        properties: %{
          workspace_id: %Reference{"$ref": "#/components/schemas/Id"},
          paused: %Schema{type: :boolean, example: true},
          agent_keys_paused_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
          paused_by_user_id: %Reference{"$ref": "#/components/schemas/Id"},
          reason: %Schema{
            type: :string,
            description:
              "Operator-supplied reason recorded at pause time. Null when " <>
                "`paused: false` or when no reason was supplied.",
            example: "credential leak under investigation"
          }
        }
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.RevokeDelegationResponse do
  @moduledoc "Response body for `POST /v1/security/revoke_delegation`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "RevokeDelegationResponse",
    description: """
    Synchronous response is a receipt — the chain-side state change
    has NOT yet landed. The adapter has been asked to submit the
    revoke; final state (`revoked` / `revoke_failed`) is delivered
    asynchronously via the `security:events` channel and the audit
    stream. Revoke is one-way at the API: re-delegation is not a v1
    `/v1/security` operation.
    """,
    type: :object,
    required: [:status, :smart_account_id],
    properties: %{
      status: %Schema{
        type: :string,
        enum: ["revoke_enqueued"],
        example: "revoke_enqueued"
      },
      smart_account_id: %Schema{type: :string, example: "sa_primary"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.AbortExecutionRequest do
  @moduledoc "Body for `POST /v1/security/abort_execution` (#230)."

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "AbortExecutionRequest",
    description: """
    Manually abort a stuck execution plan. The runtime forces the
    plan to the terminal `aborted` state and persists `final_reason`
    on the audit row. Only `:prepared` plans are abortable here —
    plans that have already been dispatched (`:signing`,
    `:broadcasting`, `:pending_confirmation`) return
    `409 not_safe_to_abort`. Already-terminal plans return `200`
    idempotently with no second audit row.
    """,
    type: :object,
    required: [:execution_plan_id],
    properties: %{
      execution_plan_id: %Reference{"$ref": "#/components/schemas/Id"},
      reason: %Schema{
        type: :string,
        enum: ["operator_requested", "stuck_pending", "adapter_unrecoverable"],
        description:
          "Audit-persisted reason. Server allowlists three values; any " <>
            "other value collapses to `\"operator_requested\"`. Defaults " <>
            "to `\"operator_requested\"` when absent.",
        example: "stuck_pending"
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.AbortExecutionResponse do
  @moduledoc "Response body for `POST /v1/security/abort_execution` (#230)."

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "AbortExecutionResponse",
    description: """
    Synchronous terminal-state response. Unlike
    `revoke_delegation` (which is a `202` chain-side receipt),
    abort is a DB-only state-machine flip that completes inside
    the request — by the time `200` returns, the plan row is
    `aborted` and the `execution.aborted` audit row has been
    appended.

    Top-level `status` discriminates between a fresh abort and an
    idempotent re-call against an already-terminal plan:

      * `"aborted"` — the call performed the transition.
      * `"already_terminal"` — the plan was already in
        `:aborted`, `:confirmed`, or `:reverted` when the call
        landed; no second audit row was emitted. Callers MUST
        read `data.execution_status` to learn the actual terminal
        state — it may be `confirmed` or `reverted`, NOT `aborted`,
        in this branch.

    Both branches return `200` so callers can safely retry on
    partial network failures without branching on the response
    code; the `status` discriminator carries the truth.
    """,
    type: :object,
    required: [:status, :data],
    properties: %{
      status: %Schema{
        type: :string,
        enum: ["aborted", "already_terminal"],
        example: "aborted"
      },
      data: %Schema{
        type: :object,
        required: [:execution_plan_id, :decision_id, :execution_status, :workspace_id],
        properties: %{
          execution_plan_id: %Reference{"$ref": "#/components/schemas/Id"},
          decision_id: %Reference{"$ref": "#/components/schemas/Id"},
          execution_status: %Schema{
            type: :string,
            description:
              "Terminal status of the plan after the call. `aborted` for a " <>
                "fresh abort; `aborted`, `confirmed`, or `reverted` in the " <>
                "`already_terminal` branch depending on the prior terminal " <>
                "transition.",
            example: "aborted"
          },
          final_outcome: %Schema{
            type: :string,
            nullable: true,
            description:
              "Mirrors the plan's `final_outcome` enum value. Always set " <>
                "to match `execution_status` once terminal.",
            example: "aborted"
          },
          final_reason: %Schema{
            type: :string,
            nullable: true,
            description: "Operator-supplied reason; null on already-terminal idempotent paths.",
            example: "stuck_pending"
          },
          workspace_id: %Reference{"$ref": "#/components/schemas/Id"}
        }
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.PauseChainRequest do
  @moduledoc "Body for `POST /v1/security/pause_chain` (#228 phase 1)."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PauseChainRequest",
    description: """
    Pause execution dispatch for a chain inside the calling key's
    workspace. Workspace-scoped: a pause set here only affects this
    workspace's plans — sibling workspaces continue dispatching on
    the same chain. Idempotent: re-pausing an already-paused chain
    returns `200` with `status: "already_paused"` and does not
    emit a second audit row.

    `workspace_id` from the body (if present) is ignored — the
    workspace is resolved from `current_scope`.
    """,
    type: :object,
    required: [:chain],
    properties: %{
      chain: %Schema{
        type: :string,
        description:
          "Chain identifier to pause. v0.1 ships `\"base\"` only; future " <>
            "phases extend the supported set without changing this wire shape.",
        example: "base",
        minLength: 1,
        maxLength: 64
      },
      reason: %Schema{
        type: :string,
        maxLength: 256,
        description: """
        Optional operator-supplied reason persisted to the `pauses`
        row and the `security.scope_paused` audit event. Empty or
        whitespace-only is treated as `nil`.
        """,
        example: "RPC outage on Base"
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ResumeChainRequest do
  @moduledoc "Body for `POST /v1/security/resume_chain` (#228 phase 1)."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ResumeChainRequest",
    description: """
    Resume execution dispatch for a chain inside the calling key's
    workspace. Workspace-scoped — only clears the pause this
    workspace set. Idempotent: resuming a chain that is not paused
    returns `200` with `status: "already_running"` and does not
    emit a second audit row.

    `workspace_id` from the body (if present) is ignored.
    """,
    type: :object,
    required: [:chain],
    properties: %{
      chain: %Schema{
        type: :string,
        description: "Chain identifier to resume.",
        example: "base",
        minLength: 1,
        maxLength: 64
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ChainPauseStateResponse do
  @moduledoc """
  Response body for `POST /v1/security/pause_chain` and
  `POST /v1/security/resume_chain` (#228 phase 1).
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "ChainPauseStateResponse",
    description: """
    Per-chain pause state for the calling workspace. Returned by
    both `pause_chain` and `resume_chain` on `200`. `status`
    discriminates between a real transition and the idempotent
    no-op:

      * `"paused"` — the call inserted a fresh active pause row.
      * `"already_paused"` — an active pause was already in place
        for this `(workspace, chain)`; no second audit row was
        emitted.
      * `"resumed"` — the call cleared the active pause.
      * `"already_running"` — no active pause existed; no audit row
        emitted.

    The `data` block carries the safe pause-row fields (no secrets,
    no API-key data, no chain-side artefacts). On the
    `already_running` branch `data` is null.
    """,
    type: :object,
    required: [:status],
    properties: %{
      status: %Schema{
        type: :string,
        enum: ["paused", "already_paused", "resumed", "already_running"],
        example: "paused"
      },
      data: %Schema{
        type: :object,
        nullable: true,
        required: [:scope_type, :scope_value, :workspace_id],
        properties: %{
          scope_type: %Schema{type: :string, enum: ["chain"], example: "chain"},
          scope_value: %Schema{type: :string, example: "base"},
          workspace_id: %Reference{"$ref": "#/components/schemas/Id"},
          paused_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
          resumed_at: %Schema{
            type: :string,
            format: :"date-time",
            nullable: true,
            description: "Set when the pause has been resumed; null on active pauses."
          },
          reason: %Schema{
            type: :string,
            nullable: true,
            description:
              "Operator-supplied reason recorded at pause time. Null when no reason was supplied.",
            example: "RPC outage on Base"
          },
          created_by_user_id: %Schema{
            type: :string,
            format: :uuid,
            nullable: true,
            description: "User id of the operator who initiated the pause, if known."
          },
          resumed_by_user_id: %Schema{
            type: :string,
            format: :uuid,
            nullable: true,
            description: "User id of the operator who lifted the pause, if applicable."
          }
        }
      }
    }
  })
end
