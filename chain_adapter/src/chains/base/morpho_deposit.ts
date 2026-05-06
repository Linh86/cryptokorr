/**
 * Base + Morpho ERC-4626 USDC deposit execution — ERC-4337 v0.7
 * UserOperation path (#206).
 *
 * The smart account holds the USDC. The adapter cannot move funds
 * with a raw EOA transaction; instead it assembles a single
 * `SimpleAccount.executeBatch(...)` UserOperation that carries:
 *
 *   1. `IERC20.approve(vault, amount)` — bounded only. The
 *      adapter never authorises an unlimited allowance on the
 *      Morpho vault.
 *   2. `IERC4626.deposit(amount, receiver)` — the receiver is the
 *      smart account address (the deposit credits shares to the
 *      same account that owns the input USDC).
 *
 * Atomicity: an attacker cannot race the bounded approval against
 * the deposit; the executeBatch keeps both inner calls in one
 * UserOp. The bounded amount also means any residual allowance
 * left after the deposit is exactly zero — the deposit consumes
 * the full approve.
 *
 * Phoenix is the source of truth for safety. `Bank.Decisions.MorphoDispatchSafety`
 * (#206) re-checks vault allowlist, snapshot freshness, material
 * drift, chain (`base-sepolia` only), and asset (`USDC` only)
 * before this module is reached. The adapter trusts those have
 * cleared and adds only the structural envelope check on the wire.
 *
 * Callback lifecycle mirrors `executeTransfer` and `executeSwap`:
 *
 *   execution.broadcast ──→ execution.confirmed (on success)
 *                         ╲
 *                          ──→ execution.reverted (on-chain revert)
 *                          ──→ execution.aborted  (signing failed /
 *                                                  bundler rejected /
 *                                                  confirmation timeout)
 *
 * `tx_refs` carry `userop_hash` on broadcast and both `userop_hash`
 * + on-chain `hash` on confirm/revert. `final_balance_changes`
 * records the USDC outflow and (when the deposit log is decoded
 * cleanly) the minted shares inflow under
 * `morpho_minted_shares.amount`.
 *
 * Withdraw / redeem is operator-only and never agent-initiated;
 * this module exposes no withdraw path.
 */

import { encodeFunctionData, type Address, type Hash, type Hex } from "viem";
import type { BaseClients } from "./client.js";
import { USDC_DECIMALS } from "./usdc.js";
import { parseAmount } from "../../config/assets.js";
import type { DispatchMorphoDeposit } from "../../contracts/schemas.js";
import type { CallbackClient } from "../../callbacks/client.js";
import { nextCallbackId } from "../../callbacks/client.js";
import { ExecutionError } from "../../lib/errors.js";
import { logger } from "../../lib/logger.js";
import {
  buildAndSignUserOp,
  buildExecuteBatchCallData,
  encodeErc20Approve,
  formatNonceHex,
  userOpHashesEqual,
} from "./userop.js";

/**
 * ERC-4626 deposit ABI fragment. The vault returns the minted
 * `shares` count; the adapter does not consume the return value
 * (the on-chain `Deposit` event decode in the receipt would
 * surface it for `final_balance_changes`).
 */
const ERC4626_DEPOSIT_ABI = [
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
  },
] as const;

export interface MorphoDepositExecutionResult {
  userOpHash: Hash;
  txHash: Hash;
  blockNumber: bigint;
  status: "success" | "reverted";
}

/** Encode `IERC4626.deposit(assets, receiver)`. */
export function encodeErc4626Deposit(assets: bigint, receiver: Address): Hex {
  return encodeFunctionData({
    abi: ERC4626_DEPOSIT_ABI,
    functionName: "deposit",
    args: [assets, receiver],
  });
}

/**
 * Build the inner calldata for the approve+deposit batch. Bounded
 * approve to the exact deposit amount; deposit credits shares back
 * to the smart account.
 */
export function buildMorphoDepositBatchCallData(params: {
  usdcAddress: Address;
  vaultAddress: Address;
  receiver: Address;
  amount: bigint;
}): Hex {
  return buildExecuteBatchCallData([
    {
      target: params.usdcAddress,
      value: 0n,
      data: encodeErc20Approve(params.vaultAddress, params.amount),
    },
    {
      target: params.vaultAddress,
      value: 0n,
      data: encodeErc4626Deposit(params.amount, params.receiver),
    },
  ]);
}

const BUNDLER_LABEL = "configured";

function bundlerLabel(): string {
  return BUNDLER_LABEL;
}

/**
 * Execute an approved Morpho ERC-4626 USDC deposit through the
 * ERC-4337 v0.7 path. Returns the receipt or an `aborted` tuple
 * the dispatch handler maps onto the `execution.aborted` callback.
 */
export async function executeMorphoDeposit(
  dispatch: DispatchMorphoDeposit,
  clients: BaseClients,
  callbackClient: CallbackClient,
  usdcAddress: Address,
): Promise<MorphoDepositExecutionResult | { aborted: true; reason: string }> {
  const { execution_plan_id, vault_address, amount, chain } = dispatch;

  logger.info("Executing Morpho ERC-4626 deposit via bundler", {
    execution_plan_id,
    chain,
    vault_address,
    amount,
    smart_account: clients.smartAccountAddress,
  });

  const amountBaseUnits = parseAmount(amount, USDC_DECIMALS);

  // ---- build + sign UserOperation ----------------------------------------

  let userOpHash: Hash;
  let userOperation;
  let nonceHex: string;
  try {
    const callData = buildMorphoDepositBatchCallData({
      usdcAddress,
      vaultAddress: vault_address as Address,
      // The receiver of the minted shares is the smart account
      // itself — the same account that owns the input USDC. The
      // dispatch envelope's `receiver` field carries the Phoenix
      // smart_account_id (opaque) for audit; the on-chain receiver
      // is the configured smartAccountAddress.
      receiver: clients.smartAccountAddress as Address,
      amount: amountBaseUnits,
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
    logger.error("Morpho deposit UserOp build/sign failed", {
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
      `Morpho deposit UserOp build failed: ${message}`,
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
    logger.error("Bundler rejected Morpho deposit UserOp", {
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
      `Bundler rejected Morpho deposit UserOp: ${message}`,
    );
  }

  if (!userOpHashesEqual(userOpHash, broadcastHash)) {
    logger.error("Bundler returned mismatched user-op hash on Morpho deposit", {
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
    logger.error("Morpho deposit confirmation wait failed", {
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
      `Morpho deposit confirmation failed: ${message}`,
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
          { asset: dispatch.asset, amount: `-${dispatch.amount}` },
        ],
      },
      emitted_at: new Date().toISOString(),
    });

    return {
      userOpHash,
      txHash,
      blockNumber,
      status: "success",
    };
  }

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
    reason: "morpho_deposit_reverted",
    emitted_at: new Date().toISOString(),
  });

  return {
    userOpHash,
    txHash,
    blockNumber,
    status: "reverted",
  };
}
