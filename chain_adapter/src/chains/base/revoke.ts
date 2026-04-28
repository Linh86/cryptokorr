/**
 * Base delegation revoke execution — ERC-4337 v0.7 path, sentinel body.
 *
 * **#31 is still open.** This path is a SENTINEL, not a cryptographic
 * revoke. It anchors the revoke attempt on chain and exercises the
 * full AA plumbing, but it does not disable the delegation key at the
 * contract level.
 *
 * Several concrete prereqs are missing before this can become a real
 * revoke. The architectural decision behind them lives in the Phoenix
 * repo at `docs/smart-account-and-revoke-design.md` (GitHub #56):
 *
 *   1. **Smart-account implementation** — DECIDED in #56: Kernel v3
 *      (ERC-7579) modular account on Base. v0.1 still ships the
 *      SimpleAccount-shaped `execute(address,uint256,bytes)` ABI
 *      envelope (selector `0xb61d27f6`); ERC-7579 accounts dispatch
 *      on a structurally different `execute(bytes32,bytes)` envelope
 *      (selector `0xe9ae5c53`, see `./erc7579.ts`). The delegation
 *      key IS the SimpleAccount owner today, so there is no separate
 *      authority to disable until provisioning moves to Kernel.
 *   2. **ERC-7579 outer wrap** — LANDED in #57: the verifiable
 *      `execute(bytes32 mode, bytes executionCalldata)` envelope
 *      pin in `./erc7579.ts`.
 *   3. **ZeroDev SDK integration + cryptographic revoke wiring** —
 *      DEFERRED. The earlier plan around a single
 *      `PERMISSION_VALIDATOR_ADDRESS` env, a strict accessor, a
 *      66-char `permissionId` mapping, and a single
 *      `disablePermission(bytes32)` ABI fragment was wrong-model
 *      against `@zerodev/permissions@5.6.3`. See
 *      `docs/zerodev-permissions-integration.md` for the corrected
 *      architecture (CREATE2 signer + policy modules, 4-byte
 *      `permissionId`, kernel-account `uninstallValidation`) and
 *      the hard-blocker list.
 *
 * What this path does in v0.1:
 *
 *   - Builds a UserOperation whose inner call is
 *     `SimpleAccount.execute(self, 0, 0x)` — a no-op self-call with
 *     zero value and zero calldata. See
 *     `buildSentinelRevokeCallData` in `userop.ts`.
 *   - Signs it with the delegation key, same as any other user-op.
 *   - Submits via the bundler, waits for receipt.
 *   - Treats confirmation as an on-chain *anchor* of the revoke
 *     intent, not as a cryptographic disablement of the key.
 *
 * Why still route through the AA path even though it's a sentinel:
 *
 *   - The callback surface for revoke is now identical to transfer —
 *     same `userop_hash`, `bundler`, `nonce` on broadcast; same
 *     `hash` + `block_number` on terminal callback. Phoenix's audit
 *     chain shows a consistent AA lifecycle across every execution.
 *   - The exact failure branches that a real cryptographic revoke
 *     will surface (bundler_rejected, confirmation_failed, userop
 *     reverted) are already exercised end-to-end. When #31 lands,
 *     the AA pipeline outside `callData` (build, sign, submit, wait,
 *     callback emission) is unchanged; only the `callData` itself
 *     swaps — from the SimpleAccount-shaped sentinel envelope to
 *     the ERC-7579 envelope wrapping a kernel-account
 *     `uninstallValidation(bytes21,bytes,bytes)` call. There is no
 *     separate validator address to target. Both the outer execute
 *     selector AND the inner body change in that swap; see the
 *     `TODO(#58)` block below + the integration doc for the exact
 *     replacement.
 *
 * What it does NOT buy us:
 *
 *   - Cryptographic revocation of the delegation at the contract
 *     level. The delegation key can still sign another user-op until
 *     the permission module is wired up; Phoenix enforces fail-closed
 *     on its side for the whole window. Phoenix treats the
 *     adapter-reported `revoked` state as "on-chain anchored, trust
 *     downgraded" — NOT as "cryptographically impossible".
 *
 * Phoenix-side lifecycle observed on a successful run:
 *
 *   granted ──revoking (pre-send) ──revoked (post-confirm)
 *
 * On any failure branch (bundler rejection, confirmation timeout,
 * user-op revert) the adapter emits `state=revoke_failed` with a
 * diagnostic `reason` — NEVER `revoked`. Phoenix treats
 * `revoke_failed` as non-terminal, non-executable, and retryable.
 */

import type { Hash } from "viem";
import type { BaseClients } from "./client.js";
import { BASE_CHAIN } from "../../config/chains.js";
import type { AdapterConfig } from "../../config/index.js";
import type { CallbackClient } from "../../callbacks/client.js";
import { nextCallbackId } from "../../callbacks/client.js";
import { ExecutionError } from "../../lib/errors.js";
import { logger } from "../../lib/logger.js";
import {
  buildAndSignUserOp,
  buildSentinelRevokeCallData,
  formatNonceHex,
  userOpHashesEqual,
} from "./userop.js";

export interface RevokeResult {
  userOpHash: Hash;
  txHash: Hash;
  blockNumber: bigint;
  status: "success" | "reverted";
}

/**
 * Execute the sentinel revoke UserOp for a smart account.
 *
 * `delegationId` is Phoenix's identifier for the authority record
 * being revoked — opaque to this function (just echoed into
 * callbacks). The eventual cryptographic revoke (see TODO(#58)
 * below) will be a `Kernel.uninstallValidation(...)` call ON the
 * smart account itself, NOT on a separate Permission Validator
 * contract; an earlier version of this file pretended such a
 * contract existed.
 *
 * Emits callbacks on every terminal transition; throws
 * `ExecutionError` on failure after emitting the terminal
 * `revoke_failed` callback.
 */
export async function executeRevoke(
  smartAccountId: string,
  delegationId: string,
  reason: string,
  config: AdapterConfig,
  clients: BaseClients,
  callbackClient: CallbackClient,
): Promise<RevokeResult> {
  // TODO(#58): Replace the sentinel call below with a real
  // ZeroDev kernel permission revoke. An earlier version of this
  // block described the swap as "wrap the validator's
  // disablePermission(bytes32) in the ERC-7579 envelope" — that
  // model was wrong. The actual on-chain entry point is
  // `Kernel.uninstallValidation(bytes21 vId, bytes deinitData,
  // bytes hookDeinitData)` called ON the smart account itself, not
  // on a separate "Permission Validator" contract.
  //
  // What still survives from earlier work:
  //   - `delegationId` is a parameter sourced from the Phoenix
  //     dispatch payload (`DispatchRevokeDelegationSchema`). Its
  //     opaque-string semantics are stable; only the FORMAT (4-byte
  //     `permissionId` vs 21-byte `validationId` vs serialized
  //     plugin blob) is part of the redesign.
  //   - `config` is threaded via `RevokeDeps` and is here for the
  //     eventual SDK + sudo-signer wiring.
  //   - The ERC-7579 outer-execute envelope pin in `./erc7579.ts`
  //     is independent of the permission model and still applies.
  //
  // What still needs to land before #58 closes (see
  // `docs/zerodev-permissions-integration.md` for the full,
  // verified ZeroDev model and the hard blockers list):
  //
  //   1. Add `@zerodev/sdk` + `@zerodev/permissions` as runtime
  //      deps in `chain_adapter/package.json`. Currently absent.
  //   2. Establish a per-kernel-account sudo signer the adapter
  //      can use to sign `uninstallValidation` UserOps. The
  //      sentinel-era delegation signer is NOT sufficient.
  //   3. Wire a bundler RPC + paymaster (or native funding) for
  //      the revoke UserOp.
  //   4. Persist the serialized plugin blob (or raw policy + signer
  //      reconstruction params) at grant-time so the adapter can
  //      rebuild the plugin and produce the multi-policy
  //      `deinitData` payload at revoke-time.
  //   5. Pin the canonical `@zerodev/permissions` package version +
  //      signer/policy module addresses (#83 — re-scoped on top
  //      of the new `KernelPermissionPin` slot in
  //      `./permission_validator.ts`).
  //   6. Decide the on-the-wire shape of `delegation_id`
  //      (4-byte permissionId vs 21-byte validationId vs blob).
  //      Phoenix's column is opaque, but the adapter and Phoenix
  //      must agree.
  //
  // Until those land, this function stays on the sentinel body
  // below. That body anchors the revoke attempt on chain but does
  // NOT cryptographically disable the delegation (#31 stays open).

  const sentinelCallData = buildSentinelRevokeCallData(
    clients.smartAccountAddress,
  );

  logger.info("Executing Base delegation revoke (sentinel UserOp)", {
    smart_account_id: smartAccountId,
    delegation_id: delegationId,
    reason,
    chain_id: config.baseChainId,
    smart_account: clients.smartAccountAddress,
  });

  // 1. Build + sign the sentinel user-op.
  let userOpHash: Hash;
  let userOperation;
  let nonceHex: string;
  try {
    const built = await buildAndSignUserOp({
      publicClient: clients.publicClient,
      bundlerClient: clients.bundlerClient,
      signer: clients.account,
      entryPointAddress: clients.entryPointAddress,
      smartAccountAddress: clients.smartAccountAddress,
      callData: sentinelCallData,
    });

    userOperation = built.userOperation;
    userOpHash = built.userOpHash;
    nonceHex = formatNonceHex(userOperation.nonce);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("Revoke UserOp build/sign failed", {
      smart_account_id: smartAccountId,
      error: message,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "delegation.state_changed",
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
      state: "revoke_failed",
      reason: `userop_build_failed: ${message}`,
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(
      "userop_build_failed",
      `Revoke UserOp build failed: ${message}`,
    );
  }

  // 2. Submit to bundler. The bundler returns its own user-op hash;
  // by EIP-4337 it MUST equal the locally-computed canonical hash.
  // We verify equality and keep the LOCAL hash as authoritative for
  // callbacks (see note in `transfer.ts`). On mismatch we fail
  // closed BEFORE emitting any terminal callback so Phoenix never
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
    logger.error("Bundler rejected revoke UserOp", {
      smart_account_id: smartAccountId,
      userOpHash,
      error: message,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "delegation.state_changed",
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
      state: "revoke_failed",
      reason: `bundler_rejected: ${message}`,
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(
      "bundler_rejected",
      `Bundler rejected revoke UserOp: ${message}`,
    );
  }

  if (!userOpHashesEqual(userOpHash, broadcastHash)) {
    logger.error("Bundler returned mismatched revoke user-op hash", {
      smart_account_id: smartAccountId,
      local_user_op_hash: userOpHash,
      bundler_user_op_hash: broadcastHash,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "delegation.state_changed",
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
      state: "revoke_failed",
      reason: `bundler_hash_mismatch: bundler returned ${broadcastHash}, locally computed ${userOpHash}`,
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(
      "bundler_hash_mismatch",
      `Bundler-returned user-op hash ${broadcastHash} does not match locally computed ${userOpHash}`,
    );
  }

  logger.info("Revoke UserOp accepted by bundler", {
    smart_account_id: smartAccountId,
    userOpHash,
    nonce: nonceHex,
  });

  // 3. Wait for bundler receipt.
  let receipt;
  try {
    receipt = await clients.bundlerClient.waitForUserOperationReceipt({
      hash: userOpHash,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("Revoke UserOp confirmation wait failed", {
      smart_account_id: smartAccountId,
      userOpHash,
      error: message,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "delegation.state_changed",
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
      state: "revoke_failed",
      reason: `confirmation_failed: ${message}`,
      tx_refs: [
        {
          chain: BASE_CHAIN.name,
          userop_hash: userOpHash,
          nonce: nonceHex,
          bundler: bundlerLabel(),
          status: "unknown",
        },
      ],
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(
      "confirmation_failed",
      `Revoke UserOp confirmation failed: ${message}`,
    );
  }

  const txHash = receipt.receipt.transactionHash as Hash;
  const blockNumber = receipt.receipt.blockNumber as bigint;
  const success = receipt.success === true;

  if (!success) {
    const revertReason = receipt.reason ?? "sentinel_reverted";

    logger.warn("Revoke UserOp reverted", {
      smart_account_id: smartAccountId,
      userOpHash,
      txHash,
      blockNumber: Number(blockNumber),
      reason: revertReason,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "delegation.state_changed",
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
      state: "revoke_failed",
      reason: revertReason,
      tx_refs: [
        {
          chain: BASE_CHAIN.name,
          userop_hash: userOpHash,
          hash: txHash,
          nonce: nonceHex,
          bundler: bundlerLabel(),
          block_number: Number(blockNumber),
          status: "reverted",
        },
      ],
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(
      "sentinel_reverted",
      `Revoke sentinel reverted at block ${blockNumber}`,
    );
  }

  await callbackClient.send({
    contract_version: 1,
    callback_id: nextCallbackId(),
    kind: "delegation.state_changed",
    smart_account_id: smartAccountId,
    delegation_id: delegationId,
    state: "revoked",
    reason,
    tx_refs: [
      {
        chain: BASE_CHAIN.name,
        userop_hash: userOpHash,
        hash: txHash,
        nonce: nonceHex,
        bundler: bundlerLabel(),
        block_number: Number(blockNumber),
        status: "success",
      },
    ],
    emitted_at: new Date().toISOString(),
  });

  logger.info("Revoke anchored on-chain (sentinel)", {
    smart_account_id: smartAccountId,
    userOpHash,
    txHash,
    blockNumber: Number(blockNumber),
  });

  return { userOpHash, txHash, blockNumber, status: "success" };
}

function bundlerLabel(): string {
  return "base-v07-bundler";
}
