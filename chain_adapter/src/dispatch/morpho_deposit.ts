/**
 * Morpho ERC-4626 USDC deposit dispatch handler (#206).
 *
 * Validates the Phoenix-supplied dispatch envelope, checks chain +
 * asset support, and delegates to `executeMorphoDeposit` for the
 * approve+deposit UserOperation. The adapter builds calldata
 * itself from `vault_address` + `amount` + `receiver`; Phoenix
 * never supplies adapter calldata, and this handler deliberately
 * accepts no `calldata` field on the wire.
 *
 * Pre-dispatch safety (vault allowlist, snapshot freshness +
 * material drift, mainnet eligibility, pause gates) is the
 * Phoenix caller's responsibility — see
 * `Bank.Decisions.MorphoDispatchSafety`. The adapter trusts those
 * have already cleared and re-checks only the structural
 * invariants here:
 *
 *   1. Schema (zod) validates the envelope shape.
 *   2. `isSupportedChain` admits Base mainnet + Base Sepolia.
 *   3. `isSupportedMorphoDepositChain` narrows to Base Sepolia
 *      only — `chain: "base"` fails closed even though
 *      `isSupportedChain` would admit it for legacy paths.
 *   4. `isSupportedAsset` narrows to USDC.
 *
 * The synchronous response is `202 accepted` once the broadcast
 * callback has fired. Phoenix anchors progress on the callback
 * chain (broadcast → confirmed | reverted | aborted), so a
 * network blip between the adapter and Phoenix never strands the
 * on-chain deposit.
 *
 * This module makes no policy decisions beyond shape + structural
 * validation. It also carries no withdraw / redeem path —
 * withdraw is operator-only and never agent-initiated, and the
 * adapter exposes no route for it.
 */

import {
  DispatchMorphoDepositSchema,
  type DispatchMorphoDeposit,
} from "../contracts/schemas.js";
import {
  isSupportedChain,
  isSupportedMorphoDepositChain,
} from "../config/chains.js";
import { isSupportedAsset } from "../config/assets.js";
import { ValidationError, UnsupportedError } from "../lib/errors.js";
import { logger } from "../lib/logger.js";
import type { CallbackClient } from "../callbacks/client.js";
import type { BaseClients } from "../chains/base/client.js";
import { executeMorphoDeposit } from "../chains/base/morpho_deposit.js";

export interface MorphoDepositDeps {
  callbackClient: CallbackClient;
  /**
   * Optional. When unset (test/dev mode without a configured
   * chain client), every dispatch fails closed with
   * `chain_clients_unavailable` so Phoenix sees a structured abort
   * via the callback channel rather than a 500 mid-request.
   */
  baseClients: BaseClients | null;
  usdcAddress: `0x${string}`;
}

export interface MorphoDepositDispatchResult {
  accepted: true;
  execution_plan_id: string;
  status: "executing" | "aborted" | "confirmed" | "reverted";
  reason?: string;
}

export async function handleMorphoDepositDispatch(
  body: unknown,
  deps: MorphoDepositDeps,
): Promise<MorphoDepositDispatchResult> {
  // 1. Validate request shape.
  const parsed = DispatchMorphoDepositSchema.safeParse(body);
  if (!parsed.success) {
    throw new ValidationError(
      "Invalid morpho_deposit dispatch payload",
      parsed.error.issues,
    );
  }

  const dispatch: DispatchMorphoDeposit = parsed.data;

  // 2. Generic chain support — rejects `"ethereum"` and friends
  //    at the adapter boundary.
  if (!isSupportedChain(dispatch.chain)) {
    throw new UnsupportedError(`Chain "${dispatch.chain}" is not supported`);
  }

  // 3. Morpho-specific narrowing — Base Sepolia only in v0.1.
  //    `chain: "base"` (mainnet) reaches a 422 at the adapter even
  //    though the Phoenix boundary gate already rejects it; belt
  //    and suspenders so a future controller bug cannot silently
  //    broadcast a mainnet Morpho deposit.
  if (!isSupportedMorphoDepositChain(dispatch.chain)) {
    throw new UnsupportedError(
      `Chain "${dispatch.chain}" is not supported for morpho_deposit dispatch (MVP is Base Sepolia only)`,
    );
  }

  // 4. Single-asset MVP.
  if (!isSupportedAsset(dispatch.asset)) {
    throw new UnsupportedError(`Asset "${dispatch.asset}" is not supported`);
  }

  logger.info("Morpho deposit dispatch accepted", {
    execution_plan_id: dispatch.execution_plan_id,
    chain: dispatch.chain,
    asset: dispatch.asset,
    amount: dispatch.amount,
    vault_address: dispatch.vault_address,
    receiver: dispatch.receiver,
    snapshot_id: dispatch.snapshot_id,
    policy_rule_ids: dispatch.policy_rule_ids,
  });

  // 5. Refuse if no chain clients are configured. Test / dev
  //    deployments that pass `baseClients: null` deserve a
  //    structured abort instead of a 500 mid-request, so Phoenix's
  //    audit trail captures a concrete reason.
  if (!deps.baseClients) {
    return await abort(deps.callbackClient, dispatch, "chain_clients_unavailable");
  }

  // 6. Execute. `executeMorphoDeposit` is responsible for the
  //    broadcast → confirmed | reverted | aborted callback chain.
  const result = await executeMorphoDeposit(
    dispatch,
    deps.baseClients,
    deps.callbackClient,
    deps.usdcAddress,
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
  dispatch: DispatchMorphoDeposit,
  reason: string,
): Promise<MorphoDepositDispatchResult> {
  // Lazy import keeps the synchronous abort branch's surface tiny.
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
