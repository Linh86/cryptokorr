/**
 * CryptoKorr TypeScript SDK — public exports.
 *
 * @example Submit a transfer (Node, Base Sepolia):
 * ```ts
 * import { CryptoKorr } from "@cryptokorr/sdk";
 *
 * const client = CryptoKorr.fromEnv();
 *
 * const result = await client.submitTransfer({
 *   agentId: "agent-alice",
 *   asset: "USDC",
 *   chain: "base-sepolia",
 *   amount: "10.50",
 *   target: { counterpartyId: "b6a10f53-..." },
 * });
 *
 * const decision = await client.waitForDecision(result.intentId, {
 *   timeoutSeconds: 30,
 * });
 *
 * switch (decision.outcome) {
 *   case "auto_exec":
 *     console.log("Dispatched.");
 *     break;
 *   case "approval_required":
 *     console.log("Operator approval pending.");
 *     break;
 *   case "hold":
 *   case "block":
 *     console.log("Refused:", decision.reasons);
 *     break;
 * }
 * ```
 *
 * The SDK never asks for a private key. The browser-wallet
 * onboarding flow lives at `docs/wallet-quickstart.md` and is out
 * of scope here.
 */

export { CryptoKorr } from "./client.js";
export {
  type ClientConfig,
  DEFAULT_BASE_URL,
  DEFAULT_TIMEOUT_MS,
  SDK_VERSION,
} from "./config.js";
export type {
  CancelIntentArgs,
  ListCounterpartiesArgs,
  SimulateIntentArgs,
  SubmitAllocateIdleCapitalArgs,
  SubmitSwapArgs,
  SubmitTransferArgs,
  WaitForDecisionArgs,
} from "./client.js";
export { OperatorClient } from "./operator.js";
export type {
  ApprovalActionArgs,
  PauseRuntimeArgs,
  ResumeRuntimeArgs,
} from "./operator.js";

// Errors
export {
  APIError,
  AuthenticationError,
  AuthorizationError,
  ChainPausedError,
  ConflictError,
  IdempotencyConflictError,
  MorphoSafetyError,
  NotFoundError,
  RateLimitError,
  ServiceUnavailableError,
  SwapSafetyError,
  UpstreamError,
  ValidationError,
  WorkspacePausedError,
  WrongStateError,
  classifyError,
  decodeError,
} from "./errors.js";
export type { ErrorEnvelope, APIErrorOptions } from "./errors.js";

// Types
export type {
  ApprovalActionResult,
  ApprovalDecisionSummary,
  ApprovalDispatch,
  ApprovalQueueItem,
  ApprovalQueueResponse,
  AuditEvent,
  AuditTrail,
  Chain,
  CounterpartyListResponse,
  CounterpartySummary,
  Decision,
  DecisionOutcome,
  DecisionReasonItem,
  DecisionReasons,
  Intent,
  IntentCancelResult,
  IntentKind,
  IntentState,
  IntentSubmitResult,
  IntentTarget,
  Policy,
  RiskTier,
  RuntimeOverallStatus,
  RuntimeStatus,
  SimulateReason,
  SimulationResult,
} from "./types.js";

// Helpers (advanced)
export { redact, redactString, REDACTED } from "./redaction.js";
