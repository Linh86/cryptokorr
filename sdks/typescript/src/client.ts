/**
 * Public {@link CryptoKorr} client.
 *
 * Per `docs/api/sdk-surface.md` — single namespace for agent /
 * viewer surfaces, `client.operator` namespace for operator-scoped
 * surfaces. Method names mirror the Python SDK.
 */

import {
  type ClientConfig,
  type ResolvedConfig,
  resolveConfig,
  readConfigFromEnv,
} from "./config.js";
import { OperatorClient } from "./operator.js";
import { Transport } from "./transport.js";
import {
  type AuditTrail,
  type CounterpartyListResponse,
  type Decision,
  type Intent,
  type IntentCancelResult,
  type IntentSubmitResult,
  type IntentTarget,
  type Policy,
  type RuntimeStatus,
  type SimulationResult,
  type SimulateReason,
} from "./types.js";

export interface SubmitTransferArgs {
  agentId: string;
  asset: string;
  chain: string;
  amount: string;
  target: IntentTarget;
  notes?: string;
  smartAccountId?: string;
  source?: string;
  idempotencyKey?: string;
}

export interface SubmitSwapArgs {
  agentId: string;
  chain: string;
  sourceAsset: string;
  destinationAsset: string;
  amount: string;
  smartAccountId?: string;
  notes?: string;
  source?: string;
  idempotencyKey?: string;
}

export interface SubmitAllocateIdleCapitalArgs {
  agentId: string;
  asset: string;
  chain?: string;
  amount: string;
  vaultAddress: string;
  smartAccountId?: string;
  notes?: string;
  source?: string;
  idempotencyKey?: string;
}

export interface CancelIntentArgs {
  reason: string;
  idempotencyKey?: string;
}

export interface SimulateIntentArgs {
  reason?: SimulateReason;
  idempotencyKey?: string;
}

export interface ListCounterpartiesArgs {
  q?: string;
  active?: boolean;
  limit?: number;
  cursor?: string;
}

export interface WaitForDecisionArgs {
  /** Default 60s. */
  timeoutSeconds?: number;
  /** Default 500ms. */
  pollIntervalMs?: number;
}

const DEFAULT_WAIT_TIMEOUT_S = 60;
const DEFAULT_WAIT_POLL_MS = 500;

/**
 * The CryptoKorr API client.
 *
 * @example
 * ```ts
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
 * const decision = await client.waitForDecision(result.intentId);
 * ```
 */
export class CryptoKorr {
  /** Operator-scoped surfaces. Agents calling these get `403 insufficient_role`. */
  public readonly operator: OperatorClient;

  /** @internal */
  public readonly transport: Transport;

  /** @internal */
  public readonly resolvedConfig: ResolvedConfig;

  constructor(config: ClientConfig) {
    this.resolvedConfig = resolveConfig(config);
    this.transport = new Transport(this.resolvedConfig);
    this.operator = new OperatorClient(this.transport);
  }

  /**
   * Build a client from `CRYPTOKORR_API_KEY` + optional
   * `CRYPTOKORR_BASE_URL` / `CRYPTOKORR_TIMEOUT_MS`.
   */
  static fromEnv(env?: NodeJS.ProcessEnv): CryptoKorr {
    return new CryptoKorr(readConfigFromEnv(env));
  }

  /** Redact-safe inspect output. The API key is never echoed. */
  toString(): string {
    return `CryptoKorr(baseUrl=${this.resolvedConfig.baseUrl})`;
  }

  // --- Intents ---------------------------------------------------------

  async submitTransfer(args: SubmitTransferArgs): Promise<IntentSubmitResult> {
    const body = {
      agentId: args.agentId,
      kind: "transfer" as const,
      asset: args.asset,
      chain: args.chain,
      amount: args.amount,
      target: args.target,
      ...(args.smartAccountId !== undefined && { smartAccountId: args.smartAccountId }),
      ...(args.notes !== undefined && { notes: args.notes }),
      source: args.source ?? "agent",
    };

    const opts: Parameters<Transport["request"]>[0] = {
      method: "POST",
      path: "/v1/intents",
      body,
    };
    if (args.idempotencyKey !== undefined) opts.idempotencyKey = args.idempotencyKey;
    return this.transport.request<IntentSubmitResult>(opts);
  }

  async submitSwap(args: SubmitSwapArgs): Promise<IntentSubmitResult> {
    const body = {
      agentId: args.agentId,
      kind: "swap" as const,
      chain: args.chain,
      // Phoenix's swap intent contract carries the source-side asset
      // + amount as the canonical `asset` + `amount`. The
      // destination asset rides as `destination_asset` per
      // `priv/openapi/openapi.json`.
      asset: args.sourceAsset,
      destinationAsset: args.destinationAsset,
      amount: args.amount,
      ...(args.smartAccountId !== undefined && { smartAccountId: args.smartAccountId }),
      ...(args.notes !== undefined && { notes: args.notes }),
      source: args.source ?? "agent",
    };

    const opts: Parameters<Transport["request"]>[0] = {
      method: "POST",
      path: "/v1/intents",
      body,
    };
    if (args.idempotencyKey !== undefined) opts.idempotencyKey = args.idempotencyKey;
    return this.transport.request<IntentSubmitResult>(opts);
  }

  async submitAllocateIdleCapital(
    args: SubmitAllocateIdleCapitalArgs,
  ): Promise<IntentSubmitResult> {
    // The public wire enum is `allocate_idle_capital` (per
    // `IntentSubmissionRequest.kind` in `priv/openapi/openapi.json`).
    // Phoenix maps this to the internal `:defi_yield_deposit` atom
    // in `Bank.Intents.normalize/1`; submitting the internal name
    // is rejected with `{:invalid, :kind}`. Responses always render
    // the public name. See `docs/runbooks/morpho-deposits.md`.
    const body = {
      agentId: args.agentId,
      kind: "allocate_idle_capital" as const,
      asset: args.asset,
      chain: args.chain ?? "base-sepolia",
      amount: args.amount,
      vaultAddress: args.vaultAddress,
      ...(args.smartAccountId !== undefined && { smartAccountId: args.smartAccountId }),
      ...(args.notes !== undefined && { notes: args.notes }),
      source: args.source ?? "agent",
    };

    const opts: Parameters<Transport["request"]>[0] = {
      method: "POST",
      path: "/v1/intents",
      body,
    };
    if (args.idempotencyKey !== undefined) opts.idempotencyKey = args.idempotencyKey;
    return this.transport.request<IntentSubmitResult>(opts);
  }

  async getIntent(intentId: string): Promise<Intent> {
    return this.transport.request<Intent>({
      method: "GET",
      path: `/v1/intents/${encodeURIComponent(intentId)}`,
    });
  }

  async simulateIntent(
    intentId: string,
    args: SimulateIntentArgs = {},
  ): Promise<SimulationResult> {
    const body = { reason: args.reason ?? "refresh" };
    const opts: Parameters<Transport["request"]>[0] = {
      method: "POST",
      path: `/v1/intents/${encodeURIComponent(intentId)}/simulate`,
      body,
    };
    if (args.idempotencyKey !== undefined) opts.idempotencyKey = args.idempotencyKey;
    return this.transport.request<SimulationResult>(opts);
  }

  async cancelIntent(intentId: string, args: CancelIntentArgs): Promise<IntentCancelResult> {
    const body = { reason: args.reason };
    const opts: Parameters<Transport["request"]>[0] = {
      method: "POST",
      path: `/v1/intents/${encodeURIComponent(intentId)}/cancel`,
      body,
    };
    if (args.idempotencyKey !== undefined) opts.idempotencyKey = args.idempotencyKey;
    return this.transport.request<IntentCancelResult>(opts);
  }

  async getAuditTrail(intentId: string): Promise<AuditTrail> {
    return this.transport.request<AuditTrail>({
      method: "GET",
      path: `/v1/intents/${encodeURIComponent(intentId)}/replay`,
    });
  }

  // --- Decisions -------------------------------------------------------

  async getDecision(decisionId: string): Promise<Decision> {
    return this.transport.request<Decision>({
      method: "GET",
      path: `/v1/decisions/${encodeURIComponent(decisionId)}`,
    });
  }

  /**
   * Poll an intent's current decision until it leaves
   * `:evaluating`. Returns the decision regardless of `outcome` —
   * the caller decides what to do with `approval_required` /
   * `hold` / `block`.
   *
   * Internally polls `GET /v1/intents/:id` to learn
   * `currentDecisionId`, then `GET /v1/decisions/:id`. Bounded by
   * `timeoutSeconds`.
   */
  async waitForDecision(
    intentId: string,
    args: WaitForDecisionArgs = {},
  ): Promise<Decision> {
    const timeoutMs = (args.timeoutSeconds ?? DEFAULT_WAIT_TIMEOUT_S) * 1000;
    const interval = args.pollIntervalMs ?? DEFAULT_WAIT_POLL_MS;
    const deadline = Date.now() + timeoutMs;

    while (true) {
      const intent = await this.getIntent(intentId);
      const decisionId = intent.currentDecisionId;
      if (typeof decisionId === "string" && decisionId.length > 0) {
        const decision = await this.getDecision(decisionId);
        if (decision.outcome) return decision;
      }

      if (Date.now() >= deadline) {
        throw new Error(
          `CryptoKorr.waitForDecision: timed out after ${timeoutMs}ms waiting for a decision on intent ${intentId}`,
        );
      }
      await new Promise<void>((resolve) => setTimeout(resolve, interval));
    }
  }

  // --- Counterparties --------------------------------------------------

  async listCounterparties(
    args: ListCounterpartiesArgs = {},
  ): Promise<CounterpartyListResponse> {
    return this.transport.request<CounterpartyListResponse>({
      method: "GET",
      path: "/v1/counterparties",
      query: {
        q: args.q,
        active: args.active,
        limit: args.limit,
        cursor: args.cursor,
      },
    });
  }

  // --- Runtime ---------------------------------------------------------

  async getRuntimeStatus(): Promise<RuntimeStatus> {
    return this.transport.request<RuntimeStatus>({
      method: "GET",
      path: "/v1/health/deep",
      unauthenticated: true,
    });
  }

  // --- Policies --------------------------------------------------------

  async getPolicy(policyId: string): Promise<Policy> {
    return this.transport.request<Policy>({
      method: "GET",
      path: `/v1/policies/${encodeURIComponent(policyId)}`,
    });
  }
}
