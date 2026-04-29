defmodule BankWeb.ApiSpec do
  @moduledoc """
  Top-level OpenAPI 3.0 document for the external CryptoBank `/v1`
  API (epic #85, issue #86).

  This module is the **foundation**: it pins the title, version,
  servers, tags, and security-scheme placeholder, and plugs an empty
  `paths` skeleton that subsequent issues fill in endpoint-by-endpoint.

  ## Scope

    * Describes only the external `/v1/...` surface. The private
      `/internal/adapter/callback` contract, `/health`, `/dev/*`,
      and the LiveView control tower are intentionally excluded —
      `paths/0` post-filters `OpenApiSpex.Paths.from_router/1` to
      `/v1/` prefixes, so even if a future edit adds operation specs
      to a non-`/v1` controller it will not leak into the external
      document.

  ## Current auth truth

  `/v1/` endpoints are **not** currently bearer-protected at runtime;
  they rely on the operator-console / network-boundary posture
  documented in `docs/security.md`. A reusable placeholder security
  scheme (`operator_bearer`, HTTP bearer) is declared in
  `components.securitySchemes` so individual operations in later
  issues can opt into it explicitly when the auth layer actually
  ships — but no operation is marked as requiring it here, and the
  top-level `security` array is empty.

  ## Layout convention for later issues

    * Shared primitive / enum / envelope schemas live under
      `lib/bank_web/open_api/schemas/` and are registered in
      `components.schemas` by title. Added in #87:

          BankWeb.OpenApi.Schemas.{Id, Timestamp, AmountString,
            EvmAddress, Chain, Asset, IntentState, DecisionOutcome,
            TrustLevel, TrustConfidence, Links, ErrorDetail,
            ErrorEnvelope}

      `ErrorEnvelope` is the outer `{error: ErrorDetail}` wrapper
      that every non-2xx `/v1` response actually emits today;
      `ErrorDetail` carries the inner object. Later issues
      `$ref` either layer depending on whether they describe the
      full response body or just the inner error.

    * Shared reusable components live under
      `lib/bank_web/open_api/`:

          BankWeb.OpenApi.Parameters       — request parameters
          BankWeb.OpenApi.Headers          — response headers
          BankWeb.OpenApi.Responses        — error responses
          BankWeb.OpenApi.SecuritySchemes  — auth placeholders

    * Per-domain request / response body schemas land in later
      issues at `lib/bank_web/open_api/schemas/<domain>.ex` and
      `$ref` the shared primitives above rather than redefining
      them. Added in #88 for the intents / decisions / approvals /
      health endpoints:

          BankWeb.OpenApi.Schemas.{HealthReadinessResponse,
            HealthDeepResponse, IntentTarget,
            IntentSubmissionRequest, SimulationRequest,
            CancelRequest, IntentReplayResponse,
            ExecutionPlanSummary, DecisionEnvelopeDetail,
            DecisionShowResponse, ExecuteDecisionRequest,
            ExecuteDecisionResponse, ApprovalDecisionSummary,
            ApprovalQueueResponse, ApprovalActionRequest,
            ApprovalNextStep, ApprovalActionResponse}
    * The ten domain tags are inline in `tags/0` below — the
      authoritative list matching the `/v1/...` router surface.
    * Controllers stay at `lib/bank_web/controllers/api/v1/*.ex`;
      they adopt `use OpenApiSpex.ControllerSpecs` and declare
      `operation :action, ...` alongside their actions, citing
      shared components by name (e.g.
      `%Reference{"$ref": "#/components/responses/Conflict"}`).
      The controller tree does not move.

  ## Non-goals for #86

    * Endpoint-by-endpoint operation coverage — #88 and #89.
    * Shared response / error envelope schemas — #87.
    * Generated `openapi.json` artifact + drift checks — #90.
    * Any depiction of `/internal/adapter/callback`.

  ## Inspection

  When `dev_routes` is on (dev only), the live spec is served at
  `GET /dev/openapi.json` via `OpenApiSpex.Plug.RenderSpec`. There is
  no production-facing spec endpoint — the artifact path lands with
  issue #90.
  """

  alias OpenApiSpex.{
    Components,
    Info,
    OpenApi,
    Paths,
    Server,
    ServerVariable,
    Tag
  }

  alias BankWeb.OpenApi.{Headers, Parameters, Responses, SecuritySchemes}

  alias BankWeb.OpenApi.Schemas.{
    AddEvidenceRequest,
    AddressLabelEntity,
    AddressLabelResponse,
    AmountString,
    ApprovalActionRequest,
    ApprovalActionResponse,
    ApprovalDecisionSummary,
    ApprovalDispatchedPlan,
    ApprovalNextStep,
    ApprovalQueueResponse,
    Asset,
    AttachAddressRequest,
    AuditEventEntity,
    AuditListResponse,
    CancelRequest,
    Chain,
    ConnectSmartAccountRequest,
    ConnectSmartAccountResponse,
    CounterpartyDetail,
    CounterpartyListResponse,
    CounterpartyResponse,
    CounterpartySummary,
    CreateCounterpartyRequest,
    CreatePolicyRequest,
    DecisionEnvelopeDetail,
    DecisionOutcome,
    DecisionShowResponse,
    ErrorDetail,
    ErrorEnvelope,
    EvidenceArtifactEntity,
    EvidenceResponse,
    EvmAddress,
    ExecuteDecisionRequest,
    ExecuteDecisionResponse,
    ExecutionPlanSummary,
    HealthDeepResponse,
    HealthReadinessResponse,
    Id,
    IntentCancelResponse,
    IntentEntity,
    IntentReplayResponse,
    IntentShowResponse,
    IntentSimulationResponse,
    IntentState,
    IntentSubmissionRequest,
    IntentSubmitResponse,
    IntentTarget,
    IssueTrustAssertionRequest,
    IssueTrustAssertionResponse,
    Links,
    PolicyListResponse,
    PolicyResponse,
    PolicyRuleEntity,
    RevisePolicyRequest,
    RevokeDelegationRequest,
    RevokeDelegationResponse,
    SecurityPauseRequest,
    SecurityResumeRequest,
    SecurityStateResponse,
    SimulationReportEntity,
    SimulationRequest,
    Timestamp,
    TrustAssertionEntity,
    TrustConfidence,
    TrustLevel,
    UpdateAddressLabelRequest,
    UpdateCounterpartyRequest
  }

  @behaviour OpenApi

  @v1_prefix "/v1/"

  @domain_tags [
    {"Intents", "Agent intent lifecycle (submit, inspect, simulate, cancel, replay)."},
    {"Decisions", "Decision envelopes and operator-initiated execution."},
    {"Approvals", "Human approval queue for decisions flagged by policy."},
    {"Counterparties", "Known counterparties, their evidence, and address book entries."},
    {"AddressLabels", "Chain addresses attributed to counterparties."},
    {"TrustAssertions", "Operator-issued trust statements that feed the trust engine."},
    {"Policies", "Policy catalog, revisions, and archival."},
    {"Audit", "Append-only runtime audit event stream."},
    {"Security", "Runtime pause, resume, and delegation revoke."},
    {"Connect", "Browser-wallet / smart-account connection scaffolding."},
    {"Health", "Readiness and deep operational-health probes under `/v1/health`."}
  ]

  @impl OpenApi
  def spec do
    %OpenApi{
      info: info(),
      servers: servers(),
      tags: tags(),
      paths: paths(),
      components: components(),
      security: []
    }
  end

  @doc "Canonical top-level tag names (ten business domains + `Health`)."
  @spec domain_tag_names() :: [String.t()]
  def domain_tag_names, do: Enum.map(@domain_tags, fn {name, _} -> name end)

  defp info do
    %Info{
      title: "CryptoBank /v1 API",
      version: app_version(),
      description: """
      External control-plane API for the CryptoBank non-custodial
      treasury runtime. Scoped to the public `/v1/...` surface; the
      private `/internal/adapter/callback` contract is intentionally
      out of scope. The authoritative prose contract for this API
      lives at `docs/bank-v0.1-runtime-flow-and-api.md`.
      """
    }
  end

  defp servers do
    # The server URL is the Phoenix endpoint root — NOT `/v1` — so
    # operation paths (which start with `/v1/...` per the router) do
    # not double-prefix as `/v1/v1/...` once #88/#89 attach them.
    [
      %Server{
        url: "{scheme}://{host}",
        description: "Phoenix endpoint; external API lives under `/v1/`.",
        variables: %{
          "scheme" => %ServerVariable{
            default: "http",
            enum: ["http", "https"],
            description: "Transport scheme (https in prod)."
          },
          "host" => %ServerVariable{
            default: "localhost:4000",
            description: "Host:port of the Phoenix endpoint."
          }
        }
      }
    ]
  end

  defp tags do
    for {name, description} <- @domain_tags do
      %Tag{name: name, description: description}
    end
  end

  # #86 ships with an empty `paths` skeleton. Later issues (#88, #89)
  # annotate each `/v1/*` controller with `use OpenApiSpex.ControllerSpecs`
  # and declare `operation/2` specs; `Paths.from_router/1` then picks
  # them up automatically. The post-filter below hard-enforces the
  # scope invariant regardless of what future edits do elsewhere.
  defp paths do
    BankWeb.Router
    |> Paths.from_router()
    |> Enum.filter(fn {path, _item} -> String.starts_with?(path, @v1_prefix) end)
    |> Map.new()
  end

  defp components do
    %Components{
      schemas: schemas(),
      parameters: parameters(),
      headers: headers(),
      responses: responses(),
      securitySchemes: security_schemes()
    }
  end

  # Registered by title so later issues can `$ref` them as
  # `#/components/schemas/<title>`. Titles come from each schema
  # module's `OpenApiSpex.schema/1` declaration and are asserted
  # by the component regression tests.
  defp schemas do
    %{
      "Id" => Id.schema(),
      "Timestamp" => Timestamp.schema(),
      "AmountString" => AmountString.schema(),
      "EvmAddress" => EvmAddress.schema(),
      "Chain" => Chain.schema(),
      "Asset" => Asset.schema(),
      "IntentState" => IntentState.schema(),
      "DecisionOutcome" => DecisionOutcome.schema(),
      "TrustLevel" => TrustLevel.schema(),
      "TrustConfidence" => TrustConfidence.schema(),
      "Links" => Links.schema(),
      "ErrorDetail" => ErrorDetail.schema(),
      "ErrorEnvelope" => ErrorEnvelope.schema(),

      # Per-domain shapes added in #88.
      "HealthReadinessResponse" => HealthReadinessResponse.schema(),
      "HealthDeepResponse" => HealthDeepResponse.schema(),
      "IntentTarget" => IntentTarget.schema(),
      "IntentSubmissionRequest" => IntentSubmissionRequest.schema(),
      "IntentEntity" => IntentEntity.schema(),
      "IntentSubmitResponse" => IntentSubmitResponse.schema(),
      "IntentShowResponse" => IntentShowResponse.schema(),
      "IntentCancelResponse" => IntentCancelResponse.schema(),
      "SimulationRequest" => SimulationRequest.schema(),
      "SimulationReportEntity" => SimulationReportEntity.schema(),
      "IntentSimulationResponse" => IntentSimulationResponse.schema(),
      "CancelRequest" => CancelRequest.schema(),
      "IntentReplayResponse" => IntentReplayResponse.schema(),
      "ExecutionPlanSummary" => ExecutionPlanSummary.schema(),
      "DecisionEnvelopeDetail" => DecisionEnvelopeDetail.schema(),
      "DecisionShowResponse" => DecisionShowResponse.schema(),
      "ExecuteDecisionRequest" => ExecuteDecisionRequest.schema(),
      "ExecuteDecisionResponse" => ExecuteDecisionResponse.schema(),
      "ApprovalDecisionSummary" => ApprovalDecisionSummary.schema(),
      "ApprovalQueueResponse" => ApprovalQueueResponse.schema(),
      "ApprovalActionRequest" => ApprovalActionRequest.schema(),
      "ApprovalNextStep" => ApprovalNextStep.schema(),
      "ApprovalDispatchedPlan" => ApprovalDispatchedPlan.schema(),
      "ApprovalActionResponse" => ApprovalActionResponse.schema(),

      # Per-domain shapes added in #89.
      "CounterpartySummary" => CounterpartySummary.schema(),
      "CounterpartyDetail" => CounterpartyDetail.schema(),
      "CounterpartyListResponse" => CounterpartyListResponse.schema(),
      "CounterpartyResponse" => CounterpartyResponse.schema(),
      "CreateCounterpartyRequest" => CreateCounterpartyRequest.schema(),
      "UpdateCounterpartyRequest" => UpdateCounterpartyRequest.schema(),
      "AddressLabelEntity" => AddressLabelEntity.schema(),
      "AddressLabelResponse" => AddressLabelResponse.schema(),
      "AttachAddressRequest" => AttachAddressRequest.schema(),
      "UpdateAddressLabelRequest" => UpdateAddressLabelRequest.schema(),
      "EvidenceArtifactEntity" => EvidenceArtifactEntity.schema(),
      "EvidenceResponse" => EvidenceResponse.schema(),
      "AddEvidenceRequest" => AddEvidenceRequest.schema(),
      "TrustAssertionEntity" => TrustAssertionEntity.schema(),
      "IssueTrustAssertionRequest" => IssueTrustAssertionRequest.schema(),
      "IssueTrustAssertionResponse" => IssueTrustAssertionResponse.schema(),
      "PolicyRuleEntity" => PolicyRuleEntity.schema(),
      "PolicyListResponse" => PolicyListResponse.schema(),
      "PolicyResponse" => PolicyResponse.schema(),
      "CreatePolicyRequest" => CreatePolicyRequest.schema(),
      "RevisePolicyRequest" => RevisePolicyRequest.schema(),
      "AuditEventEntity" => AuditEventEntity.schema(),
      "AuditListResponse" => AuditListResponse.schema(),
      "SecurityPauseRequest" => SecurityPauseRequest.schema(),
      "SecurityResumeRequest" => SecurityResumeRequest.schema(),
      "SecurityStateResponse" => SecurityStateResponse.schema(),
      "RevokeDelegationRequest" => RevokeDelegationRequest.schema(),
      "RevokeDelegationResponse" => RevokeDelegationResponse.schema(),
      "ConnectSmartAccountRequest" => ConnectSmartAccountRequest.schema(),
      "ConnectSmartAccountResponse" => ConnectSmartAccountResponse.schema()
    }
  end

  defp parameters do
    %{
      "IdempotencyKey" => Parameters.idempotency_key(),
      "RequestIdIn" => Parameters.request_id_in()
    }
  end

  defp headers do
    %{
      "RequestIdOut" => Headers.request_id_out()
    }
  end

  defp responses do
    %{
      "BadRequest" => Responses.bad_request(),
      "Forbidden" => Responses.forbidden(),
      "NotFound" => Responses.not_found(),
      "Conflict" => Responses.conflict(),
      "UnprocessableEntity" => Responses.unprocessable_entity(),
      "NotImplemented" => Responses.not_implemented(),
      "ServiceUnavailable" => Responses.service_unavailable(),
      "BadGateway" => Responses.bad_gateway(),
      "GatewayTimeout" => Responses.gateway_timeout()
    }
  end

  # Truthfulness note: both schemes carry the "Not currently
  # enforced" caveat in their descriptions (see
  # `BankWeb.OpenApi.SecuritySchemes`). The top-level
  # `security: []` in `spec/0` keeps the contract honest — no
  # operation is marked as requiring either scheme until the
  # runtime actually enforces one.
  defp security_schemes do
    %{
      "operator_bearer" => SecuritySchemes.operator_bearer(),
      "agent_api_key" => SecuritySchemes.agent_api_key()
    }
  end

  defp app_version do
    case Application.spec(:bank, :vsn) do
      nil -> "0.0.0-unknown"
      vsn -> to_string(vsn)
    end
  end
end
