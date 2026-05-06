/**
 * Swap dispatch handler — 0x Base Sepolia execution path (#192).
 *
 * Validates the dispatch envelope, checks chain support, and delegates
 * to `executeSwap` for the approve+swap UserOperation. When the
 * envelope's execution-route fields (target / calldata / spender /
 * value / source+destination token addresses / minimum_output_amount)
 * are missing, the handler fails closed with `swap_route_incomplete`.
 *
 * The synchronous response is `202 accepted` with `status: "executing"`
 * once the broadcast callback has fired. Phoenix anchors progress on
 * the callback chain (broadcast → confirmed | reverted | aborted),
 * so a network blip between the adapter and Phoenix never strands
 * the on-chain operation.
 *
 * This module makes no policy decisions beyond shape validation.
 * Phoenix's `Bank.Decisions.SwapDispatchSafety` (#191) enforces
 * pause gates, mainnet caps, slippage caps, and route-vs-intent
 * cross-checks; the adapter trusts those have already cleared.
 */

import {
  DispatchSwapSchema,
  type DispatchSwap,
} from "../contracts/schemas.js";
import { isSupportedChain, isSupportedSwapChain } from "../config/chains.js";
import { ValidationError, UnsupportedError } from "../lib/errors.js";
import { logger } from "../lib/logger.js";
import type { CallbackClient } from "../callbacks/client.js";
import type { BaseClients } from "../chains/base/client.js";
import { executeSwap } from "../chains/base/swap.js";

export interface SwapDeps {
  callbackClient: CallbackClient;
  /**
   * Optional. When unset (test/dev mode without a configured chain
   * client), every dispatch fails closed with `chain_clients_unavailable`
   * so Phoenix sees a structured abort instead of a 500.
   */
  baseClients: BaseClients | null;
}

export interface SwapDispatchResult {
  accepted: true;
  execution_plan_id: string;
  status: "executing" | "aborted" | "confirmed" | "reverted";
  reason?: string;
}

export async function handleSwapDispatch(
  body: unknown,
  deps: SwapDeps,
): Promise<SwapDispatchResult> {
  // 1. Validate request shape.
  const parsed = DispatchSwapSchema.safeParse(body);
  if (!parsed.success) {
    throw new ValidationError(
      "Invalid swap dispatch payload",
      parsed.error.issues,
    );
  }

  const dispatch: DispatchSwap = parsed.data;

  // 2. Check chain support. The generic guard rejects truly unknown
  //    chains (e.g. `"ethereum"`) at the adapter boundary; the
  //    swap-specific guard then narrows the allowlist to Base
  //    Sepolia only — the MVP plan keeps live swap dispatch on
  //    testnet, mainnet swap is post-MVP. A `chain: "base"` envelope
  //    therefore fails closed with `unsupported_swap_chain` rather
  //    than silently broadcasting a mainnet swap UserOperation.
  if (!isSupportedChain(dispatch.chain)) {
    throw new UnsupportedError(`Chain "${dispatch.chain}" is not supported`);
  }

  if (!isSupportedSwapChain(dispatch.chain)) {
    throw new UnsupportedError(
      `Chain "${dispatch.chain}" is not supported for swap dispatch (MVP is Base Sepolia only)`,
    );
  }

  logger.info("Swap dispatch accepted, executing via 0x batch", {
    execution_plan_id: dispatch.execution_plan_id,
    chain: dispatch.chain,
    input_asset: dispatch.input_asset,
    output_asset: dispatch.output_asset,
    venue: dispatch.route.venue,
    route_provider: dispatch.route.route_provider,
  });

  // 3. Refuse if no chain clients configured. Test/dev deployments
  //    that pass `baseClients: null` deserve a structured abort
  //    instead of a 500 mid-request, so Phoenix's audit trail
  //    captures a concrete reason.
  if (!deps.baseClients) {
    return await abort(deps.callbackClient, dispatch, "chain_clients_unavailable");
  }

  // 4. Execute. `executeSwap` is responsible for the broadcast →
  //    confirmed | reverted | aborted callback chain.
  const result = await executeSwap(
    dispatch,
    deps.baseClients,
    deps.callbackClient,
  );

  if ("aborted" in result) {
    return {
      accepted: true,
      execution_plan_id: dispatch.execution_plan_id,
      status: "aborted",
      reason: result.reason,
    };
  }

  return {
    accepted: true,
    execution_plan_id: dispatch.execution_plan_id,
    status: result.status === "success" ? "confirmed" : "reverted",
  };
}

async function abort(
  callbackClient: CallbackClient,
  dispatch: DispatchSwap,
  reason: string,
): Promise<SwapDispatchResult> {
  // Lazy import keeps the synchronous abort branch's surface tiny —
  // most paths hit `executeSwap` and never reach this fallback.
  const { nextCallbackId } = await import("../callbacks/client.js");

  await callbackClient.send({
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
