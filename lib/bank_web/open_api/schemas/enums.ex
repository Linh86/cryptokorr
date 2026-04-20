defmodule BankWeb.OpenApi.Schemas.Enums do
  @moduledoc """
  Shared enum schemas for the external `/v1` OpenAPI document
  (issue #87, epic #85).

  Each enum value list is authoritative: it matches the `/v1`
  runtime contract and the domain model, and the tests pin the
  values so a rename or drop surfaces as a test failure rather
  than a silent drift.

  Enums covered:

    * `Chain` — EVM chain identifier. Schema is chain-agnostic;
      `/v1` today only accepts `"base"`.
    * `Asset` — asset symbol. `"USDC"` is first-class; policy
      whitelists others on a per-deployment basis.
    * `IntentState` — state machine of `AgentIntent` as it moves
      through evaluation and execution.
    * `DecisionOutcome` — the four outcomes the decision engine
      can write into a `DecisionEnvelope`.
    * `TrustLevel` — derived trust level from the trust engine's
      assessment.
    * `TrustConfidence` — qualitative confidence of the trust
      assessment.
  """
end

defmodule BankWeb.OpenApi.Schemas.Chain do
  @moduledoc """
  Chain identifier. Schema is chain-agnostic; the `/v1` runtime
  today rejects anything other than `"base"` at the boundary.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Chain",
    description: """
    EVM chain identifier. The schema permits additional values
    so operators can extend the allowlist without a schema
    change, but at runtime `/v1` v1 accepts only `"base"`.
    """,
    type: :string,
    enum: ["base"],
    example: "base"
  })
end

defmodule BankWeb.OpenApi.Schemas.Asset do
  @moduledoc """
  Asset symbol. `"USDC"` is first-class.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Asset",
    description: """
    Asset symbol. `"USDC"` is first-class on the default policy;
    other values may be modelled but must be whitelisted by an
    active `PolicyRule` before they are accepted at `/v1/intents`.
    """,
    type: :string,
    example: "USDC"
  })
end

defmodule BankWeb.OpenApi.Schemas.IntentState do
  @moduledoc """
  Lifecycle state of an `AgentIntent`.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "IntentState",
    description: """
    Lifecycle state of an `AgentIntent`. The flow is
    `submitted → evaluating → decided → executing → executed`
    on the happy path, with `blocked` and `cancelled` as
    terminal side branches.
    """,
    type: :string,
    enum: ~w(submitted evaluating decided executing executed blocked cancelled),
    example: "decided"
  })
end

defmodule BankWeb.OpenApi.Schemas.DecisionOutcome do
  @moduledoc """
  Outcome written by the decision engine into a `DecisionEnvelope`.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DecisionOutcome",
    description: """
    Outcome written by the decision engine:

      * `auto_exec` — within policy, trust engine reports trusted,
        simulation healthy.
      * `hold` — permissions pass but something is temporarily off
        (stale simulation, cooldown window, trust re-check needed).
      * `approval_required` — sensitive trust, autonomy-tier
        threshold, or simulation flag routes to the operator
        approval queue.
      * `block` — terminal rejection; a new intent is required
        to retry.
    """,
    type: :string,
    enum: ~w(auto_exec hold approval_required block),
    example: "approval_required"
  })
end

defmodule BankWeb.OpenApi.Schemas.TrustLevel do
  @moduledoc """
  Derived trust level from a trust assessment.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TrustLevel",
    description: """
    Derived trust level from the trust engine's assessment.
    Unknown addresses (raw or otherwise unattributed) default
    to `unknown`; conflicted means the evidence base disagrees
    and an operator must resolve the trust state before
    auto-execution can proceed.
    """,
    type: :string,
    enum: ~w(trusted sensitive unknown conflicted),
    example: "trusted"
  })
end

defmodule BankWeb.OpenApi.Schemas.TrustConfidence do
  @moduledoc """
  Qualitative confidence of a trust assessment.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TrustConfidence",
    description: """
    Qualitative confidence of the trust engine's assessment of a
    target. `low` / `medium` / `high` map to widening-caution
    behavior on downstream routing.
    """,
    type: :string,
    enum: ~w(low medium high),
    example: "high"
  })
end
