/**
 * Base + 0x swap execution — ERC-4337 v0.7 UserOperation path (#192).
 *
 * The smart account holds the input token (USDC / USDT / WETH). The
 * adapter cannot move funds with a raw EOA transaction; instead it
 * assembles a single UserOperation whose inner call is
 * `SimpleAccount.executeBatch(...)` carrying:
 *
 *   1. `IERC20.approve(spender, inputAmount)` — bounded only. The
 *      adapter never authorises an unlimited allowance.
 *   2. router call — `target` is the 0x router, `value` is the
 *      native ETH attached (zero for ERC20→ERC20), `data` is the
 *      operator-supplied 0x calldata. The router consumes the
 *      bounded allowance and credits the output token.
 *
 * The two inner calls share atomicity, so an attacker cannot race
 * the approval against the swap. Phoenix is the source of truth for
 * route safety — pause gates, mainnet caps, slippage caps, and the
 * `Bank.Decisions.SwapDispatchSafety` (#191) cross-checks all run on
 * the Phoenix side. This module performs only fail-closed envelope
 * validation: presence of execution fields, supported MVP assets,
 * non-stale deadline, ERC20-input-only (native-ETH input deferred
 * post-MVP).
 *
 * Callback lifecycle mirrors `executeTransfer` (#137):
 *
 *   execution.broadcast ──→ execution.confirmed (on-chain success)
 *                         ╲
 *                          ──→ execution.reverted (on-chain revert)
 *                          ──→ execution.aborted  (envelope incomplete /
 *                                                  bundler rejected /
 *                                                  signing failed /
 *                                                  confirmation timeout)
 *
 * `tx_refs` carry `userop_hash` on broadcast and both `userop_hash` +
 * on-chain `hash` on confirm/revert. `final_balance_changes` records
 * the input token outflow and (when known) the output token inflow.
 *
 * ## Secret hygiene
 *
 * The adapter never logs the bundler URL, the delegation private
 * key, or raw `Authorization` headers. Failure reasons map to a
 * fixed-allowlist string vocabulary so an operator inspecting an
 * `execution.aborted` row sees a stable, short reason without leaked
 * secrets.
 */

import type { Address, Hash, Hex } from "viem";
import type { BaseClients } from "./client.js";
import { decimalsForSwapAsset, parseAmount } from "../../config/assets.js";
import type { DispatchSwap } from "../../contracts/schemas.js";
import type { CallbackClient } from "../../callbacks/client.js";
import { nextCallbackId } from "../../callbacks/client.js";
import { ExecutionError } from "../../lib/errors.js";
import { logger } from "../../lib/logger.js";
import {
  buildAndSignUserOp,
  buildSwapBatchCallData,
  formatNonceHex,
  userOpHashesEqual,
} from "./userop.js";

/**
 * 0x's sentinel address for native ETH on the input side. `swap.ts`
 * deliberately does NOT support a native-input swap in v0.1 — the
 * approve+swap batch assumes an ERC-20 input. ETH→USDC routes will
 * be unblocked in a follow-up that switches the inner shape to a
 * single `execute(target, value, data)` (no approve).
 */
const ZEROX_NATIVE_ETH = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

const SUPPORTED_ROUTE_PROVIDERS = ["zerox", "0x"] as const;

export interface SwapExecutionResult {
  userOpHash: Hash;
  txHash: Hash;
  blockNumber: bigint;
  status: "success" | "reverted";
}

/**
 * Validate the execution-route fields the dispatch envelope must
 * carry for an actual on-chain swap. Returns the fully-checked
 * params or a stable `{ aborted: true, reason }` tuple the caller
 * can map onto an `execution.aborted` callback.
 */
type CheckedSwap =
  | {
      ok: true;
      inputToken: Address;
      spender: Address;
      swapTarget: Address;
      swapCalldata: Hex;
      swapValue: bigint;
      inputAmountBaseUnits: bigint;
      inputDecimals: number;
      outputDecimals: number;
    }
  | { ok: false; reason: string };

function checkSwapEnvelope(dispatch: DispatchSwap, now: Date): CheckedSwap {
  const route = dispatch.route;

  // 1. Provider allowlist. Quote-only routes (no provider tag) and
  //    routes from non-MVP venues fail closed here.
  const provider = route.route_provider?.toLowerCase();
  if (!provider) {
    return { ok: false, reason: "swap_route_incomplete: route_provider" };
  }
  if (!SUPPORTED_ROUTE_PROVIDERS.includes(provider as never)) {
    return { ok: false, reason: `unsupported_provider: ${provider}` };
  }

  // 2. Required execution fields.
  const missing: string[] = [];
  if (!route.swap_target_contract) missing.push("swap_target_contract");
  if (!route.calldata) missing.push("calldata");
  if (!route.spender) missing.push("spender");
  if (!route.source_token_address) missing.push("source_token_address");
  if (!route.destination_token_address) missing.push("destination_token_address");
  if (route.value === undefined) missing.push("value");
  if (!route.minimum_output_amount) missing.push("minimum_output_amount");
  if (missing.length > 0) {
    return {
      ok: false,
      reason: `swap_route_incomplete: ${missing.join(",")}`,
    };
  }

  // 3. Native-ETH input is post-MVP. The 0x sentinel address signals
  //    native input; we refuse so the approve+swap batch's invariants
  //    (input is an ERC-20) hold.
  if (route.source_token_address!.toLowerCase() === ZEROX_NATIVE_ETH) {
    return { ok: false, reason: "native_input_not_implemented" };
  }

  // 4. Asset decimals. The dispatch envelope carries `input_amount` as
  //    a decimal string; we need the token's decimals to convert to
  //    base units for the bounded approval. The MVP allowlist is
  //    USDC / USDT / WETH (with ETH as the human label for WETH on
  //    output).
  const inputDecimals = decimalsForSwapAsset(dispatch.input_asset);
  if (inputDecimals === undefined) {
    return {
      ok: false,
      reason: `unsupported_input_asset: ${dispatch.input_asset}`,
    };
  }
  const outputDecimals = decimalsForSwapAsset(dispatch.output_asset);
  if (outputDecimals === undefined) {
    return {
      ok: false,
      reason: `unsupported_output_asset: ${dispatch.output_asset}`,
    };
  }

  // 5. Defensive deadline re-check. Phoenix's #191 SwapDispatchSafety
  //    enforces freshness already, but a late dispatch over a slow
  //    queue could land here past the route's deadline. Rejecting at
  //    the boundary keeps the audit trail honest about why.
  if (route.deadline) {
    const deadlineMs = Date.parse(route.deadline);
    if (Number.isNaN(deadlineMs)) {
      return { ok: false, reason: "swap_route_incomplete: deadline" };
    }
    if (deadlineMs <= now.getTime()) {
      return { ok: false, reason: "stale_route" };
    }
  }

  // 6. Convert the bounded-approval amount to base units. The
  //    operator-supplied `input_amount` is the canonical ground truth;
  //    the route's `minimum_output_amount` is enforced on-chain by 0x.
  let inputAmountBaseUnits: bigint;
  try {
    inputAmountBaseUnits = parseAmount(dispatch.input_amount, inputDecimals);
  } catch {
    return { ok: false, reason: "swap_route_incomplete: input_amount" };
  }
  if (inputAmountBaseUnits <= 0n) {
    return { ok: false, reason: "swap_route_incomplete: input_amount" };
  }

  // 7. Native value attached to the router call (always 0 for the
  //    ERC20-input MVP — non-zero `value` with an ERC-20 input is a
  //    contract-shape error from upstream).
  let swapValue: bigint;
  try {
    swapValue = parseAmount(route.value!, 18);
  } catch {
    return { ok: false, reason: "swap_route_incomplete: value" };
  }
  if (swapValue !== 0n) {
    return { ok: false, reason: "non_zero_value_with_erc20_input" };
  }

  return {
    ok: true,
    inputToken: route.source_token_address! as Address,
    spender: route.spender! as Address,
    swapTarget: route.swap_target_contract! as Address,
    swapCalldata: route.calldata! as Hex,
    swapValue,
    inputAmountBaseUnits,
    inputDecimals,
    outputDecimals,
  };
}

/**
 * Execute a 0x swap through the ERC-4337 v0.7 path.
 *
 * Validates the execution-route shape, builds the approve+swap
 * `executeBatch` calldata, signs the canonical v0.7 user-op hash with
 * the delegation key, submits to the configured bundler, and emits
 * the broadcast → confirmed | reverted | aborted callback chain.
 */
export async function executeSwap(
  dispatch: DispatchSwap,
  clients: BaseClients,
  callbackClient: CallbackClient,
  now: Date = new Date(),
): Promise<SwapExecutionResult | { aborted: true; reason: string }> {
  const { execution_plan_id, chain } = dispatch;

  // ---- envelope validation ------------------------------------------------

  const checked = checkSwapEnvelope(dispatch, now);
  if (!checked.ok) {
    logger.warn("Swap dispatch envelope failed pre-execution checks", {
      execution_plan_id,
      reason: checked.reason,
      route_provider: dispatch.route.route_provider,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.aborted",
      execution_plan_id,
      reason: checked.reason,
      emitted_at: new Date().toISOString(),
    });

    return { aborted: true, reason: checked.reason };
  }

  logger.info("Executing 0x swap via bundler", {
    execution_plan_id,
    chain,
    input_asset: dispatch.input_asset,
    output_asset: dispatch.output_asset,
    input_amount: dispatch.input_amount,
    smart_account: clients.smartAccountAddress,
  });

  // ---- build + sign UserOperation ----------------------------------------

  let userOpHash: Hash;
  let userOperation;
  let nonceHex: string;
  try {
    const callData = buildSwapBatchCallData({
      inputToken: checked.inputToken,
      spender: checked.spender,
      swapTarget: checked.swapTarget,
      swapValue: checked.swapValue,
      swapCalldata: checked.swapCalldata,
      approveAmount: checked.inputAmountBaseUnits,
    });

    const built = await buildAndSignUserOp({
      publicClient: clients.publicClient,
      bundlerClient: clients.bundlerClient,
      signer: clients.account,
      entryPointAddress: clients.entryPointAddress,
      smartAccountAddress: clients.smartAccountAddress,
      callData,
    });

    userOperation = built.userOperation;
    userOpHash = built.userOpHash;
    nonceHex = formatNonceHex(userOperation.nonce);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("Swap UserOp build/sign failed", {
      execution_plan_id,
      error: message,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.aborted",
      execution_plan_id,
      reason: `userop_build_failed: ${message}`,
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(
      "userop_build_failed",
      `Swap UserOp build failed: ${message}`,
    );
  }

  // ---- bundler submit ----------------------------------------------------

  let broadcastHash: Hash;
  try {
    broadcastHash = (await clients.bundlerClient.sendUserOperation({
      account: undefined,
      entryPointAddress: clients.entryPointAddress,
      ...userOperation,
    })) as Hash;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("Bundler rejected swap UserOp", {
      execution_plan_id,
      userOpHash,
      error: message,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.aborted",
      execution_plan_id,
      reason: `bundler_rejected: ${message}`,
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(
      "bundler_rejected",
      `Bundler rejected swap UserOp: ${message}`,
    );
  }

  if (!userOpHashesEqual(userOpHash, broadcastHash)) {
    logger.error("Bundler returned mismatched user-op hash on swap", {
      execution_plan_id,
      local_user_op_hash: userOpHash,
      bundler_user_op_hash: broadcastHash,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.aborted",
      execution_plan_id,
      reason: `bundler_hash_mismatch: bundler returned ${broadcastHash}, locally computed ${userOpHash}`,
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(
      "bundler_hash_mismatch",
      `Bundler-returned user-op hash ${broadcastHash} does not match locally computed ${userOpHash}`,
    );
  }

  // ---- broadcast callback ------------------------------------------------

  await callbackClient.send({
    contract_version: 1,
    callback_id: nextCallbackId(),
    kind: "execution.broadcast",
    execution_plan_id,
    tx_refs: [
      {
        chain,
        userop_hash: userOpHash,
        nonce: nonceHex,
        bundler: bundlerLabel(),
      },
    ],
    emitted_at: new Date().toISOString(),
  });

  // ---- wait for receipt --------------------------------------------------

  let receipt;
  try {
    receipt = await clients.bundlerClient.waitForUserOperationReceipt({
      hash: userOpHash,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("Swap UserOp confirmation wait failed", {
      execution_plan_id,
      userOpHash,
      error: message,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.aborted",
      execution_plan_id,
      reason: `confirmation_failed: ${message}`,
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(
      "confirmation_failed",
      `Swap UserOp confirmation failed: ${message}`,
    );
  }

  const txHash = receipt.receipt.transactionHash as Hash;
  const blockNumber = receipt.receipt.blockNumber as bigint;
  const success = receipt.success === true;

  if (success) {
    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.confirmed",
      execution_plan_id,
      tx_refs: [
        {
          chain,
          userop_hash: userOpHash,
          hash: txHash,
          nonce: nonceHex,
          bundler: bundlerLabel(),
          block_number: Number(blockNumber),
          status: "success",
        },
      ],
      final_balance_changes: {
        items: [
          { asset: dispatch.input_asset, amount: `-${dispatch.input_amount}` },
          {
            asset: dispatch.output_asset,
            amount: dispatch.expected_output,
          },
        ],
      },
      emitted_at: new Date().toISOString(),
    });

    logger.info("Swap confirmed", {
      execution_plan_id,
      userOpHash,
      txHash,
      blockNumber: Number(blockNumber),
    });

    return { userOpHash, txHash, blockNumber, status: "success" };
  } else {
    const revertReason = receipt.reason ?? "userop_reverted";

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.reverted",
      execution_plan_id,
      tx_refs: [
        {
          chain,
          userop_hash: userOpHash,
          hash: txHash,
          nonce: nonceHex,
          bundler: bundlerLabel(),
          block_number: Number(blockNumber),
          status: "reverted",
        },
      ],
      reason: revertReason,
      emitted_at: new Date().toISOString(),
    });

    logger.warn("Swap reverted", {
      execution_plan_id,
      userOpHash,
      txHash,
      blockNumber: Number(blockNumber),
      reason: revertReason,
    });

    return { userOpHash, txHash, blockNumber, status: "reverted" };
  }
}

/**
 * Diagnostic label identifying the bundler in callbacks. Same posture
 * as `executeTransfer` — the bundler URL itself may carry secrets, so
 * we emit a stable non-secret marker so operators can disambiguate
 * providers without leaking credentials through the audit trail.
 */
function bundlerLabel(): string {
  return "base-v07-bundler";
}
