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
 *   2. **Adapter env scaffolding** — LANDED in #57:
 *      `PERMISSION_VALIDATOR_ADDRESS` env key + the strict accessor
 *      `requirePermissionValidatorAddress(config)` so the live revoke
 *      cannot silently degrade to a sentinel after #58 ships.
 *   3. **Mapping convention** — LANDED in #57: the
 *      `delegation_id` ↔ `permissionId` round trip in
 *      `./permission_validator.ts`, plus the verifiable ERC-7579
 *      outer wrap in `./erc7579.ts`.
 *   4. **Validator interface pin** — STILL PENDING for #58: the
 *      specific Permission Validator deployment on Base, its
 *      disable function name + selector, and a tripwire test pinning
 *      that fragment. Deferred from #57 because pinning a name like
 *      `disablePermission(bytes32)` from a plausible reference
 *      implementation — without verifying it against the actual
 *      bytecode of a deployment we will use — would surface as a
 *      silent on-chain revert at the first real revoke.
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
 *     swaps — from the SimpleAccount-shaped sentinel envelope to the
 *     ERC-7579 envelope wrapping a verified Permission Validator
 *     disable body. Both the outer execute selector AND the inner
 *     body change in that swap; see the `TODO(#58)` block below for
 *     the exact replacement.
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
import { KERNEL_PERMISSION_VALIDATOR_PIN } from "./permission_validator.js";
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
 * callbacks) until #58 wires the real ERC-7579 disable, at which
 * point `permissionIdFromDelegationId` parses it into `bytes32
 * permissionId` and the inner call encodes against the Permission
 * Validator.
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
  // TODO(#58): Replace the sentinel call below with the real
  // permission-disable call. The remaining swap has exactly two
  // external prereqs — each tracked separately so the prerequisites
  // do not silently bundle.
  //
  // What #57 leaves behind, verified:
  //
  //   - the `delegation_id` ↔ `permissionId` mapping helpers in
  //     `./permission_validator.ts` (mapping convention is our design
  //     choice and verifiable today),
  //   - the strict env accessor `requirePermissionValidatorAddress`
  //     in `../../config/index.ts` so the live revoke cannot silently
  //     degrade to a sentinel if the env var is forgotten on a
  //     Kernel-provisioned deploy,
  //   - the verifiable ERC-7579 outer wrap
  //     `buildErc7579ExecuteCallData` in `./erc7579.ts`, pinned
  //     against EIP-7579's `execute(bytes32,bytes)` selector
  //     `0xe9ae5c53`.
  //
  // What subsequent plumbing has added:
  //
  //   - `delegationId` is a parameter sourced from the Phoenix
  //     dispatch payload (`DispatchRevokeDelegationSchema`). Phoenix
  //     populates it from the `delegations` projection row.
  //   - `config` is a parameter (this function), threaded via
  //     `RevokeDeps` from `buildApp` → `handleRevokeDispatch`. The
  //     eventual real path reads
  //     `requirePermissionValidatorAddress(config)` and compares it
  //     against the live-pinned
  //     `KERNEL_PERMISSION_VALIDATOR_PIN.address` at startup via the
  //     bytecode tripwire.
  //   - `KERNEL_PERMISSION_VALIDATOR_PIN` is exported from
  //     `./permission_validator.ts` and remains `null` until #83
  //     lands a `VerifiedPermissionValidator` sourced from a
  //     verified deployment artifact. The sentinel path is the only
  //     state where the pin is `null`; once non-null, the runtime
  //     routes the real body instead.
  //
  // What still needs to land before #58 closes:
  //
  //   1. Provision a Kernel v3 / ERC-7579 deployment on Base and
  //      install a Permission Validator against it. Tracked in #84.
  //      Runbook: `docs/provisioning-kernel-v3.md`.
  //      Templates: `scripts/provision-kernel.ts` +
  //      `scripts/verify-installed-validator.ts`. Until #84 lands
  //      against a real deployment, the outer envelope here is
  //      correctly the SimpleAccount one
  //      (`buildSentinelRevokeCallData`).
  //   2. Verify the Permission Validator deployment artifact and pin
  //      its disable function name + selector against a concrete
  //      artifact (verified contract / canonical audited package /
  //      vendor-published deployment manifest). Add a tripwire test
  //      pinning that fragment. Tracked in #83. The chain-side
  //      handoff format is the receipt emitted by
  //      `scripts/verify-installed-validator.ts`; the full pin
  //      contract is documented on `VerifiedPermissionValidator` in
  //      `./permission_validator.ts`.
  //
  // When #83 populates `KERNEL_PERMISSION_VALIDATOR_PIN`, the swap
  // here fits into a narrow guard — no further signature changes
  // needed:
  //
  //     if (KERNEL_PERMISSION_VALIDATOR_PIN !== null) {
  //       const pin = KERNEL_PERMISSION_VALIDATOR_PIN;
  //       const validatorAddress = requirePermissionValidatorAddress(config);
  //       // pin.address === validatorAddress enforced at startup
  //       const permissionId = permissionIdFromDelegationId(delegationId);
  //       const innerBody = encodeFunctionData({
  //         abi: [pin.disableFunction],
  //         functionName: pin.disableFunction.name,
  //         args: [permissionId],
  //       });
  //       const callData = buildErc7579ExecuteCallData(
  //         pin.address, 0n, innerBody,
  //       );
  //       // sign + submit + callback is unchanged from here down.
  //     }
  //
  // Updating `test/base-revoke-sentinel-pin.test.ts` to pin the new
  // outer wrap is the last step in the #58 PR.

  // Operational warning: the env var is set but the pin has not
  // landed yet, so the runtime is straddling the transition. This
  // shouldn't occur in production because the pin + env typically
  // land together, but the asymmetric state is visible here so an
  // operator who points the adapter at a Kernel-provisioned account
  // before #83 ships gets a clear signal that the revoke is still
  // sentinel-anchored, not cryptographic.
  if (
    config.permissionValidatorAddress !== undefined &&
    KERNEL_PERMISSION_VALIDATOR_PIN === null
  ) {
    logger.warn(
      "PERMISSION_VALIDATOR_ADDRESS is set but KERNEL_PERMISSION_VALIDATOR_PIN is not yet landed (#83); still using sentinel revoke body",
      {
        smart_account_id: smartAccountId,
        permission_validator_address: config.permissionValidatorAddress,
      },
    );
  }

  const sentinelCallData = buildSentinelRevokeCallData(
    clients.smartAccountAddress,
  );

  logger.info("Executing Base delegation revoke (sentinel UserOp)", {
    smart_account_id: smartAccountId,
    delegation_id: delegationId,
    reason,
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
