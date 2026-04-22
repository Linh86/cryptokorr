/**
 * Transfer dispatch handler.
 *
 * Validates the incoming dispatch payload, checks chain + asset support,
 * and delegates to the Base USDC transfer execution path.
 */

import {
  DispatchTransferSchema,
  type DispatchTransfer,
} from "../contracts/schemas.js";
import { isSupportedChain } from "../config/chains.js";
import { isSupportedAsset } from "../config/assets.js";
import { UnsupportedError, ValidationError } from "../lib/errors.js";
import { logger } from "../lib/logger.js";
import type { CallbackClient } from "../callbacks/client.js";
import type { BaseClients } from "../chains/base/client.js";
import { executeTransfer } from "../chains/base/transfer.js";

export interface TransferDeps {
  callbackClient: CallbackClient;
  baseClients: BaseClients;
  usdcAddress: `0x${string}`;
}

export interface TransferDispatchResult {
  accepted: true;
  execution_plan_id: string;
}

/**
 * Handle POST /dispatch/transfer.
 *
 * Returns a result after the transfer is fully confirmed or fails.
 * In production this would be made async — Phoenix enqueues and the
 * adapter processes in the background. For v0.1 the synchronous flow
 * is correct for demonstrating the full callback lifecycle.
 */
export async function handleTransferDispatch(
  body: unknown,
  deps: TransferDeps,
): Promise<TransferDispatchResult> {
  // 1. Validate request shape
  const parsed = DispatchTransferSchema.safeParse(body);
  if (!parsed.success) {
    throw new ValidationError(
      "Invalid transfer dispatch payload",
      parsed.error.issues,
    );
  }

  const dispatch: DispatchTransfer = parsed.data;

  // 2. Check chain support
  if (!isSupportedChain(dispatch.chain)) {
    throw new UnsupportedError(`Chain "${dispatch.chain}" is not supported`);
  }

  // 3. Check asset support
  if (!isSupportedAsset(dispatch.asset)) {
    throw new UnsupportedError(`Asset "${dispatch.asset}" is not supported`);
  }

  logger.info("Transfer dispatch accepted", {
    execution_plan_id: dispatch.execution_plan_id,
    chain: dispatch.chain,
    asset: dispatch.asset,
    amount: dispatch.amount,
    target: dispatch.target.address,
  });

  // 4. Execute
  await executeTransfer(
    dispatch,
    deps.baseClients,
    deps.callbackClient,
    deps.usdcAddress,
  );

  return {
    accepted: true,
    execution_plan_id: dispatch.execution_plan_id,
  };
}
