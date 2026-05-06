/**
 * Cross-SDK types — shared with the Python SDK, generated
 * conceptually from `priv/openapi/openapi.json`. The wire is
 * snake_case; the SDK exposes camelCase.
 *
 * Keep this file flat and copy-pasteable into TypeScript
 * application code; deep narrowing is the consumer's job.
 */

// --- Enums --------------------------------------------------------------

export type IntentKind = "transfer" | "swap" | "scheduled_transfer" | "defi_yield_deposit";

export type IntentState =
  | "submitted"
  | "evaluating"
  | "decided"
  | "executing"
  | "executed"
  | "blocked"
  | "cancelled"
  | "expired";

export type DecisionOutcome = "auto_exec" | "approval_required" | "hold" | "block";

export type RiskTier = "low" | "moderate" | "elevated" | "severe";

export type Chain = "base" | "base-sepolia";

export type SimulateReason = "pre_submit_dry_run" | "refresh" | "operator_inspection";

export type ApprovalDispatch = "dispatched" | "held" | "no_dispatch";

// --- Intent target ------------------------------------------------------

/**
 * Tagged union — exactly one of `counterpartyId` or `rawAddress`.
 * The runtime rejects mixed shapes with `invalid_target`.
 */
export type IntentTarget =
  | { counterpartyId: string; addressLabelId?: string }
  | { rawAddress: string };

// --- Intent -------------------------------------------------------------

export interface Intent {
  id: string;
  agentId: string;
  source: "agent" | "user" | "runtime";
  kind: IntentKind;
  asset: string;
  chain: Chain;
  amount: string;
  target: {
    counterpartyId?: string;
    addressLabelId?: string;
    rawAddress?: string;
  };
  state: IntentState;
  smartAccountId: string | null;
  submittedAt: string;
  currentDecisionId: string | null;
  currentSimulationId: string | null;
  currentExecutionPlanId: string | null;
  notes?: string | null;
  // Forward-compatible pass-through for fields the OpenAPI artifact
  // adds without an SDK bump. Consumers reading new fields can rely
  // on the wire snake_case names being present here verbatim.
  [extra: string]: unknown;
}

export interface IntentSubmitResult {
  intentId: string;
  state: IntentState;
  idempotentReplay: boolean;
  intent: Intent;
  links: { self: string; replay: string };
}

export interface IntentCancelResult {
  intentId: string;
  state: IntentState;
  /** True when this is a key-replay (the cancel was already applied). */
  idempotent: boolean;
  reason: string;
  intent: Intent;
  links: { self: string; replay: string };
}

// --- Simulation ---------------------------------------------------------

export interface SimulationResult {
  id: string;
  intentId: string;
  status: string;
  /** Raw simulation envelope; the OpenAPI artifact pins the field set. */
  [extra: string]: unknown;
}

// --- Decision -----------------------------------------------------------

export interface DecisionReasonItem {
  code: string;
  message?: string;
  details?: Record<string, unknown>;
}

export interface DecisionReasons {
  items: DecisionReasonItem[];
}

export interface Decision {
  id: string;
  intentId: string;
  outcome: DecisionOutcome;
  state: "decided";
  current: boolean;
  riskTier: RiskTier | null;
  reasons: DecisionReasons;
  approvalExpiresAt: string | null;
  decidedAt: string;
  decidedBy: string | null;
  policySnapshotRef: string | null;
  supersedesId: string | null;
  /** Forward-compatible pass-through for new envelope fields. */
  [extra: string]: unknown;
}

// --- Approvals ----------------------------------------------------------

export interface ApprovalDecisionSummary {
  id: string;
  intentId: string;
  outcome: DecisionOutcome;
  approvalExpiresAt: string | null;
  /** Forward-compatible. */
  [extra: string]: unknown;
}

export interface ApprovalActionResult {
  decision: ApprovalDecisionSummary;
  dispatch: ApprovalDispatch;
  executionPlan?: { planId: string; smartAccountId: string };
  heldReason?: string;
  nextStep?: Record<string, unknown>;
}

export interface ApprovalQueueItem extends ApprovalDecisionSummary {
  /** Wire shape includes the parent intent summary + cap window. */
  [extra: string]: unknown;
}

export interface ApprovalQueueResponse {
  data: ApprovalQueueItem[];
  page?: { cursor: string | null };
}

// --- Counterparties -----------------------------------------------------

export interface CounterpartySummary {
  id: string;
  name: string;
  active: boolean;
  /** Forward-compatible. */
  [extra: string]: unknown;
}

export interface CounterpartyListResponse {
  data: CounterpartySummary[];
  page?: { cursor: string | null };
}

// --- Policies -----------------------------------------------------------

export interface Policy {
  id: string;
  state: string;
  ruleType: string;
  /** Forward-compatible. */
  [extra: string]: unknown;
}

// --- Audit --------------------------------------------------------------

export interface AuditEvent {
  id: string;
  ts: string;
  actor: string;
  actorId: string | null;
  eventType: string;
  subjectType: string;
  subjectId: string;
  correlationId: string | null;
  workspaceId: string | null;
  payloadHash: string;
  /** Forward-compatible — `before_ref` / `after_ref` etc. */
  [extra: string]: unknown;
}

export interface AuditTrail {
  intent: Intent | null;
  decisions: Decision[];
  simulations: SimulationResult[];
  /** Forward-compatible — full replay bundle shape. */
  [extra: string]: unknown;
}

// --- Runtime status -----------------------------------------------------

export type RuntimeOverallStatus = "ok" | "degraded" | "failing";

export interface RuntimeStatus {
  status: RuntimeOverallStatus;
  service: string;
  version: string;
  checks: Record<string, unknown>;
}
