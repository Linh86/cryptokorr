/**
 * Operator-scoped surfaces. Agents calling these with an
 * `agent`-role API key get `403 insufficient_role`. The SDK
 * exposes them under a separate `client.operator` namespace so
 * accidental misuse from an agent context is loud.
 */

import type { Transport } from "./transport.js";
import type { ApprovalActionResult, ApprovalQueueResponse } from "./types.js";

export interface ApprovalActionArgs {
  actorId: string;
  reason?: string;
  idempotencyKey?: string;
}

export interface PauseRuntimeArgs {
  reason?: string;
  idempotencyKey?: string;
}

export interface ResumeRuntimeArgs {
  idempotencyKey?: string;
}

export class OperatorClient {
  constructor(private readonly transport: Transport) {}

  async listPendingApprovals(): Promise<ApprovalQueueResponse> {
    return this.transport.request<ApprovalQueueResponse>({
      method: "GET",
      path: "/v1/approvals",
    });
  }

  async approveDecision(
    decisionId: string,
    args: ApprovalActionArgs,
  ): Promise<ApprovalActionResult> {
    const body = {
      actorId: args.actorId,
      ...(args.reason !== undefined && { reason: args.reason }),
    };
    const opts: Parameters<Transport["request"]>[0] = {
      method: "POST",
      path: `/v1/approvals/${encodeURIComponent(decisionId)}/approve`,
      body,
    };
    if (args.idempotencyKey !== undefined) opts.idempotencyKey = args.idempotencyKey;
    return this.transport.request<ApprovalActionResult>(opts);
  }

  async rejectDecision(
    decisionId: string,
    args: ApprovalActionArgs,
  ): Promise<ApprovalActionResult> {
    const body = {
      actorId: args.actorId,
      ...(args.reason !== undefined && { reason: args.reason }),
    };
    const opts: Parameters<Transport["request"]>[0] = {
      method: "POST",
      path: `/v1/approvals/${encodeURIComponent(decisionId)}/reject`,
      body,
    };
    if (args.idempotencyKey !== undefined) opts.idempotencyKey = args.idempotencyKey;
    return this.transport.request<ApprovalActionResult>(opts);
  }

  async pauseRuntime(args: PauseRuntimeArgs = {}): Promise<unknown> {
    const body =
      args.reason !== undefined ? { reason: args.reason } : ({} as Record<string, unknown>);
    const opts: Parameters<Transport["request"]>[0] = {
      method: "POST",
      path: "/v1/security/pause",
      body,
    };
    if (args.idempotencyKey !== undefined) opts.idempotencyKey = args.idempotencyKey;
    return this.transport.request<unknown>(opts);
  }

  async resumeRuntime(args: ResumeRuntimeArgs = {}): Promise<unknown> {
    const opts: Parameters<Transport["request"]>[0] = {
      method: "POST",
      path: "/v1/security/resume",
      body: {},
    };
    if (args.idempotencyKey !== undefined) opts.idempotencyKey = args.idempotencyKey;
    return this.transport.request<unknown>(opts);
  }
}
