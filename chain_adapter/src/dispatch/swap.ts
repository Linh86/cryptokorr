/**
 * Swap dispatch handler — scaffolded safe boundary.
 *
 * The swap execution path is intentionally not wired to a real DEX
 * router in v0.1. The handler validates the request shape, checks
 * chain support, and explicitly fails with a clear reason.
 *
 * This is not a fake success. Phoenix receives an execution.aborted
 * callback so the intent moves to a blocked state with an auditable
 * explanation.
 */

import {
  DispatchSwapSchema,
  type DispatchSwap,
} from "../contracts/schemas.js";
import { isSupportedChain } from "../config/chains.js";
import { ValidationError, UnsupportedError } from "../lib/errors.js";
import { logger } from "../lib/logger.js";
import type { CallbackClient } from "../callbacks/client.js";
import { nextCallbackId } from "../callbacks/client.js";

export interface SwapDeps {
  callbackClient: CallbackClient;
}

export interface SwapDispatchResult {
  accepted: true;
  execution_plan_id: string;
  status: "aborted";
  reason: string;
}

/**
 * Handle POST /dispatch/swap.
 *
 * Validates, then aborts with an explicit reason.
 * The callback to Phoenix is real — the swap execution is not.
 */
export async function handleSwapDispatch(
  body: unknown,
  deps: SwapDeps,
): Promise<SwapDispatchResult> {
  // 1. Validate request shape
  const parsed = DispatchSwapSchema.safeParse(body);
  if (!parsed.success) {
    throw new ValidationError(
      "Invalid swap dispatch payload",
      parsed.error.issues,
    );
  }

  const dispatch: DispatchSwap = parsed.data;

  // 2. Check chain support
  if (!isSupportedChain(dispatch.chain)) {
    throw new UnsupportedError(`Chain "${dispatch.chain}" is not supported`);
  }

  const reason = "swap_not_implemented: swap execution is scaffolded but not wired to a router in v0.1";

  logger.warn("Swap dispatch accepted but aborting — not implemented", {
    execution_plan_id: dispatch.execution_plan_id,
    chain: dispatch.chain,
    input_asset: dispatch.input_asset,
    output_asset: dispatch.output_asset,
    venue: dispatch.route.venue,
    reason,
  });

  // 3. Send abort callback to Phoenix — this is real and auditable
  await deps.callbackClient.send({
    contract_version: 1,
    callback_id: nextCallbackId(),
    kind: "execution.aborted",
    execution_plan_id: dispatch.execution_plan_id,
    reason,
    emitted_at: new Date().toISOString(),
  });

  return {
    accepted: true,
    execution_plan_id: dispatch.execution_plan_id,
    status: "aborted",
    reason,
  };
}
