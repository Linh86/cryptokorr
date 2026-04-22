/**
 * Base + USDC transfer execution — ERC-4337 v0.7 UserOperation path.
 *
 * The smart account owns the USDC. The adapter cannot move funds with
 * a raw EOA transaction; instead it assembles a UserOperation whose
 * inner call is `SimpleAccount.execute(USDC, 0, transfer(to, amount))`,
 * signs the canonical v0.7 user-op hash with the delegation key, and
 * submits to the configured bundler.
 *
 * Callback lifecycle:
 *
 *   execution.broadcast ──→ execution.confirmed (on success)
 *                         ╲
 *                          ──→ execution.reverted (on-chain revert)
 *                          ──→ execution.aborted  (bundler rejected /
 *                                                  signing failed /
 *                                                  confirmation timeout)
 *
 * tx_refs carry `userop_hash` on broadcast and both `userop_hash` +
 * `hash` (the on-chain transaction hash returned by the bundler
 * receipt) on confirm/revert. Nonce is serialized as a hex string so
 * the full 256-bit AA nonce survives Phoenix's `:array, :string`
 * persistence.
 */

import type { Hash } from "viem";
import type { BaseClients } from "./client.js";
import { USDC_DECIMALS } from "./usdc.js";
import { parseAmount } from "../../config/assets.js";
import type { DispatchTransfer } from "../../contracts/schemas.js";
import type { CallbackClient } from "../../callbacks/client.js";
import { nextCallbackId } from "../../callbacks/client.js";
import { ExecutionError } from "../../lib/errors.js";
import { logger } from "../../lib/logger.js";
import {
  buildAndSignUserOp,
  buildTransferCallData,
  formatNonceHex,
  userOpHashesEqual,
} from "./userop.js";

export interface TransferResult {
  userOpHash: Hash;
  txHash: Hash;
  blockNumber: bigint;
  status: "success" | "reverted";
}

/**
 * Execute a USDC transfer through the ERC-4337 v0.7 path.
 */
export async function executeTransfer(
  dispatch: DispatchTransfer,
  clients: BaseClients,
  callbackClient: CallbackClient,
  usdcAddress: `0x${string}`,
): Promise<TransferResult> {
  const { execution_plan_id, target, amount, chain } = dispatch;

  logger.info("Executing Base USDC transfer via bundler", {
    execution_plan_id,
    target: target.address,
    amount,
    smart_account: clients.smartAccountAddress,
  });

  const amountBaseUnits = parseAmount(amount, USDC_DECIMALS);

  // 1. Build inner calldata + sign UserOperation.
  let userOpHash: Hash;
  let userOperation;
  let nonceHex: string;
  try {
    const callData = buildTransferCallData(
      usdcAddress,
      target.address as `0x${string}`,
      amountBaseUnits,
    );

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
    logger.error("UserOp build/sign failed", {
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
      `UserOp build failed: ${message}`,
    );
  }

  // 2. Submit to bundler. The bundler returns its own user-op hash;
  // by EIP-4337 this MUST equal the hash we locally computed from the
  // same canonical fields. We verify the equality and keep the LOCAL
  // hash as the source of truth for callbacks. If the values diverge
  // the bundler is buggy, a proxy is rewriting the request, or the
  // bundler is on a different chain than we hashed for — adopting
  // its hash would make Phoenix track the wrong operation. Fail
  // closed BEFORE emitting the broadcast callback so Phoenix never
  // anchors a misleading hash.
  let broadcastHash: Hash;
  try {
    broadcastHash = (await clients.bundlerClient.sendUserOperation({
      account: undefined,
      entryPointAddress: clients.entryPointAddress,
      ...userOperation,
    })) as Hash;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("Bundler rejected UserOp", {
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
      `Bundler rejected UserOp: ${message}`,
    );
  }

  if (!userOpHashesEqual(userOpHash, broadcastHash)) {
    logger.error("Bundler returned mismatched user-op hash", {
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

  // 3. Broadcast callback — userop is in the bundler's mempool.
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
        bundler: bundlerLabel(clients),
      },
    ],
    emitted_at: new Date().toISOString(),
  });

  // 4. Wait for bundler receipt (EntryPoint-level inclusion).
  let receipt;
  try {
    receipt = await clients.bundlerClient.waitForUserOperationReceipt({
      hash: userOpHash,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("UserOp confirmation wait failed", {
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
      `UserOp confirmation failed: ${message}`,
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
          bundler: bundlerLabel(clients),
          block_number: Number(blockNumber),
          status: "success",
        },
      ],
      final_balance_changes: {
        items: [{ asset: dispatch.asset, amount: `-${dispatch.amount}` }],
      },
      emitted_at: new Date().toISOString(),
    });

    logger.info("Transfer confirmed", {
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
          bundler: bundlerLabel(clients),
          block_number: Number(blockNumber),
          status: "reverted",
        },
      ],
      reason: revertReason,
      emitted_at: new Date().toISOString(),
    });

    logger.warn("Transfer reverted", {
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
 * Diagnostic label identifying the bundler in callbacks. The bundler
 * URL itself may contain secrets (API keys); in v0.1 we emit a stable
 * non-secret marker so operators can disambiguate between providers
 * without leaking credentials through the audit trail.
 */
function bundlerLabel(_clients: BaseClients): string {
  return "base-v07-bundler";
}
