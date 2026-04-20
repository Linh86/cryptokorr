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
