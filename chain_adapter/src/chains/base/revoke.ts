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

import type { Chain, Hash } from "viem";
import type { BaseClients } from "./client.js";
import { BASE_CHAIN } from "../../config/chains.js";
import type { AdapterConfig } from "../../config/index.js";
import type { CallbackClient } from "../../callbacks/client.js";
import { nextCallbackId } from "../../callbacks/client.js";
import { ExecutionError } from "../../lib/errors.js";
import { logger } from "../../lib/logger.js";
import type { PermissionBlock } from "../../contracts/schemas.js";
import {
  buildAndSignUserOp,
  buildSentinelRevokeCallData,
  formatNonceHex,
  userOpHashesEqual,
} from "./userop.js";
import {
  CryptographicRevokeError,
  assertValidationIdConsistent,
  assertPackageVersionPinned,
} from "./uninstall_validation.js";

export interface RevokeResult {
  userOpHash: Hash;
  txHash: Hash;
  blockNumber: bigint;
  status: "success" | "reverted";
}

/**
 * Execute a delegation revoke for a smart account.
 *
 * Routes between two paths based on `permissionBlock`:
 *
 *   - **Cryptographic path (#58).** When the dispatch carries a
 *     `permission` block, the adapter MUST attempt
 *     `Kernel.uninstallValidation(bytes21,bytes,bytes)` against the
 *     smart account itself, signed by the kernel's ROOT validator
 *     EOA (`config.operatorPrivateKey`). The block is validated
 *     against `KERNEL_PERMISSION_PIN` before any chain interaction.
 *     The path FAILS CLOSED — if the operator key is missing, the
 *     blob will not deserialize, the validation_id is inconsistent,
 *     or the package version pin does not match, the adapter emits
 *     `revoke_failed` with a precise reason and never silently
 *     downgrades to sentinel.
 *
 *   - **Sentinel path (legacy).** Without a `permission` block the
 *     adapter falls back to the no-op `SimpleAccount.execute(self,
 *     0, 0x)` self-call. This still anchors the revoke attempt on
 *     chain but does NOT cryptographically disable the delegation.
 *     Phoenix continues to enforce fail-closed posture for the
 *     entire window. Used by legacy rows that predate the grant-
 *     time blob persistence (#58 hard blocker (4)) and during
 *     pre-cryptographic-grant rollout.
 *
 * `delegationId` is Phoenix's identifier for the authority record
 * being revoked — opaque to this function (just echoed into
 * callbacks). For cryptographic revokes the actual on-chain target
 * is determined by `permissionBlock.validation_id`, not
 * `delegationId`.
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
  permissionBlock?: PermissionBlock,
): Promise<RevokeResult> {
  if (permissionBlock) {
    return executeCryptographicRevoke(
      smartAccountId,
      delegationId,
      reason,
      config,
      clients,
      callbackClient,
      permissionBlock,
    );
  }

  return executeSentinelRevoke(
    smartAccountId,
    delegationId,
    reason,
    config,
    clients,
    callbackClient,
  );
}

async function executeSentinelRevoke(
  smartAccountId: string,
  delegationId: string,
  reason: string,
  config: AdapterConfig,
  clients: BaseClients,
  callbackClient: CallbackClient,
): Promise<RevokeResult> {
  // Sentinel revoke body. Anchors the revoke attempt on chain via a
  // no-op `SimpleAccount.execute(self, 0, 0x)` self-call but does
  // NOT cryptographically disable the delegation. Used as the
  // legacy fallback when the dispatch carries no `permission` block
  // (i.e. the delegation row was granted before #58's grant-time
  // blob persistence). The cryptographic path lives in
  // `executeCryptographicRevoke` below; routing happens in
  // `executeRevoke`.
  //
  // What still needs to land before this fallback can be retired
  // (see `docs/zerodev-permissions-integration.md` for the verified
  // ZeroDev model and the full hard-blocker list):
  //
  //   1. Persist the serialized plugin blob (or raw policy + signer
  //      reconstruction params) at grant-time so Phoenix can
  //      include a `permission` block in the revoke dispatch and
  //      the adapter takes the cryptographic path.
  //   2. Provision a per-account sudo signer (#58 hard blocker (2))
  //      and supply it via `config.operatorPrivateKey`.
  //
  // Both gates are real today: the schema migration for (1) is in
  // this PR, and (2) is plumbed through `AdapterConfig`. Cryptographic
  // revoke runs the moment a `granted` callback populates the
  // artifact columns AND a real operator key is provisioned.

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

/**
 * Cryptographic revoke (#58). Reconstructs the ZeroDev permission
 * plugin from `permissionBlock.blob`, builds a sudo-only kernel
 * account at `clients.smartAccountAddress` signed by
 * `config.operatorPrivateKey`, and dispatches
 * `Kernel.uninstallValidation(...)` through the SDK's
 * `uninstallPlugin` action. The SDK handles the kernel-v3 nonce-key
 * encoding (sudo bit), the ERC-7579 outer execute envelope, and
 * UserOp signing under the operator EOA — that orchestration is the
 * audited contract surface we lean on rather than re-deriving it
 * locally.
 *
 * Pre-broadcast guards (in order):
 *
 *   1. `operatorPrivateKey` MUST be set. Without it the kernel's
 *      `onlyEntryPointOrSelfOrRoot` guard rejects the call; failing
 *      closed at this boundary is the contract this branch enforces.
 *   2. `permissionBlock.validation_id` MUST equal
 *      `0x02 ‖ rightPad(permissionBlock.permission_id, 20)`.
 *      Caught by `assertValidationIdConsistent`.
 *   3. `permissionBlock.package_version` MUST match
 *      `KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion`.
 *      Caught by `assertPackageVersionPinned`.
 *
 * Failures of any guard, the deserialization round-trip, or the
 * UserOp submission emit a terminal `state=revoke_failed` callback
 * with a precise reason code and throw `ExecutionError`. There is
 * NO silent fallback to the sentinel path: if the dispatch carries
 * a `permission` block, Phoenix has decided the revoke must be
 * cryptographic, and we either honor that or fail loudly.
 *
 * Test coverage today exercises every fail-closed branch via mocks
 * (operator-key-missing, validation_id mismatch, package version
 * pin mismatch, blob deserialization failure). The successful
 * broadcast path is reachable only against a real bundler with a
 * real operator key — that path is verified end-to-end in operator
 * runbooks, not in unit tests.
 */
async function executeCryptographicRevoke(
  smartAccountId: string,
  delegationId: string,
  reason: string,
  config: AdapterConfig,
  clients: BaseClients,
  callbackClient: CallbackClient,
  permissionBlock: PermissionBlock,
): Promise<RevokeResult> {
  // Guard 1: operator key must be configured. Without it the kernel's
  // `onlyEntryPointOrSelfOrRoot` guard would reject any UserOp built
  // from a sudo signer we do not control. We refuse BEFORE touching
  // the chain so an operator who forgot to provision the key in
  // staging gets a clear callback rather than an opaque
  // `bundler_rejected: AA24 signature error`.
  if (!config.operatorPrivateKey || !config.operatorAddress) {
    const message =
      "Cryptographic revoke requested (permission block present) but OPERATOR_PRIVATE_KEY / OPERATOR_ADDRESS is not configured; refusing to fall back to sentinel.";
    logger.error(message, {
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "delegation.state_changed",
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
      state: "revoke_failed",
      reason: "operator_key_missing",
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError("operator_key_missing", message);
  }

  // Guards 2 + 3: pin checks. Throw `CryptographicRevokeError` with
  // a specific code; we map that onto the callback `reason` below.
  try {
    assertValidationIdConsistent(permissionBlock);
    assertPackageVersionPinned(permissionBlock);
  } catch (err) {
    const code =
      err instanceof CryptographicRevokeError
        ? err.code
        : "permission_deserialization_failed";
    const message = err instanceof Error ? err.message : String(err);
    logger.error("Cryptographic revoke pin guard failed", {
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
      code,
      error: message,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "delegation.state_changed",
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
      state: "revoke_failed",
      reason: code,
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(code, message);
  }

  logger.info("Executing Base delegation revoke (cryptographic UserOp)", {
    smart_account_id: smartAccountId,
    delegation_id: delegationId,
    permission_id: permissionBlock.permission_id,
    validation_id: permissionBlock.validation_id,
    chain_id: config.baseChainId,
    smart_account: clients.smartAccountAddress,
  });

  // Lazy import: keeps the heavier account-client orchestration out
  // of the sentinel hot path. These are runtime dependencies because
  // the cryptographic path imports them in production when a dispatch
  // carries a `permission` block.
  let userOpHash: Hash;
  let txHash: Hash;
  let blockNumber: bigint;
  try {
    const sdk = await import("@zerodev/sdk");
    const sdkConstants = await import("@zerodev/sdk/constants");
    const ecdsaValidator = await import("@zerodev/ecdsa-validator");
    const sdkActions = await import("@zerodev/sdk/actions");
    const permissions = await import("@zerodev/permissions");
    const viemAccounts = await import("viem/accounts");
    const viem = await import("viem");

    const entryPoint = sdkConstants.getEntryPoint("0.7");
    const kernelVersion = sdkConstants.KERNEL_V3_1;

    // SECRET: the kernel root EOA. Used to sign the UserOp; never
    // logged or written into errors. Operator-key validation in
    // `loadConfig` already refused placeholders + role conflation.
    const operatorAccount = viemAccounts.privateKeyToAccount(
      config.operatorPrivateKey,
    );

    // Build the sudo ECDSA validator from the operator EOA. This is
    // the same validator type `provision-kernel.ts` deploys with —
    // the kernel's `rootValidator` slot pins the corresponding
    // address at provisioning time, so this binding is stable.
    const sudoValidator = await ecdsaValidator.signerToEcdsaValidator(
      // viem's PublicClient and ZeroDev's expected Client diverged
      // across viem minor versions; the SDK only invokes JSON-RPC
      // methods both share. Cast at the boundary.
      clients.publicClient as never,
      {
        signer: operatorAccount,
        entryPoint,
        kernelVersion,
      },
    );

    // Reconstruct the regular permission plugin from the persisted
    // blob. `deserializePermissionAccount` builds a kernel account
    // whose `kernelPluginManager.regularValidator` IS the original
    // permission plugin. We extract that handle to feed into
    // `uninstallPlugin`; the account itself is discarded because
    // `uninstallPlugin` requires a sudo-context kernel client.
    const permissionAccount = await permissions.deserializePermissionAccount(
      clients.publicClient as never,
      entryPoint,
      kernelVersion,
      permissionBlock.blob,
    );
    const permissionPlugin = (
      permissionAccount as unknown as {
        kernelPluginManager: {
          regularValidator?: {
            validatorType?: string;
          };
        };
      }
    ).kernelPluginManager.regularValidator;
    if (!permissionPlugin) {
      throw new CryptographicRevokeError(
        "permission_deserialization_failed",
        "deserialized account does not carry a regular permission validator",
      );
    }

    // Build the SUDO-only kernel account at the same address. The
    // SDK's `uninstallPlugin` requires the active validator be sudo
    // because the kernel's `onlyEntryPointOrSelfOrRoot` guard on
    // `uninstallValidation` only accepts root authority. We
    // explicitly omit `regular` so `getNonceKey` returns the SUDO
    // encoding (see `toKernelPluginManager.ts` `activeValidatorMode:
    // sudo && !regular ? "sudo" : "regular"`).
    const sudoAccount = await sdk.createKernelAccount(
      clients.publicClient as never,
      {
        entryPoint,
        kernelVersion,
        plugins: { sudo: sudoValidator },
        address: clients.smartAccountAddress,
      },
    );

    const kernelClient = sdk.createKernelAccountClient({
      account: sudoAccount,
      // The SDK accepts viem's `Chain` here. Reuse the public
      // client's chain so a chain-id mismatch surfaces as a clean
      // viem error rather than a bundler `wrong_chain` rejection.
      chain: (clients.publicClient as { chain?: Chain }).chain,
      bundlerTransport: viem.http(config.bundlerRpcUrl),
      client: clients.publicClient as never,
    });

    // Submit. Returns the canonical user-op hash; receipt polling
    // happens after.
    userOpHash = (await sdkActions.uninstallPlugin(kernelClient as never, {
      plugin: permissionPlugin as never,
    })) as Hash;

    const receipt = await kernelClient.waitForUserOperationReceipt({
      hash: userOpHash,
    });

    if (!receipt.success) {
      const revertReason = receipt.reason ?? "uninstall_validation_reverted";

      logger.warn("Cryptographic revoke UserOp reverted", {
        smart_account_id: smartAccountId,
        userOpHash,
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
            hash: receipt.receipt.transactionHash as Hash,
            block_number: Number(receipt.receipt.blockNumber as bigint),
            bundler: bundlerLabel(),
            status: "reverted",
          },
        ],
        emitted_at: new Date().toISOString(),
      });

      throw new ExecutionError(
        "uninstall_validation_reverted",
        `uninstallValidation reverted in UserOp ${userOpHash}: ${revertReason}`,
      );
    }

    txHash = receipt.receipt.transactionHash as Hash;
    blockNumber = receipt.receipt.blockNumber as bigint;
  } catch (err) {
    if (err instanceof ExecutionError) throw err;

    const message = err instanceof Error ? err.message : String(err);
    const code =
      err instanceof CryptographicRevokeError
        ? err.code
        : "cryptographic_revoke_failed";

    logger.error("Cryptographic revoke failed", {
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
      code,
      error: message,
    });

    await callbackClient.send({
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "delegation.state_changed",
      smart_account_id: smartAccountId,
      delegation_id: delegationId,
      state: "revoke_failed",
      reason: code,
      emitted_at: new Date().toISOString(),
    });

    throw new ExecutionError(code, message);
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
        bundler: bundlerLabel(),
        block_number: Number(blockNumber),
        status: "success",
      },
    ],
    emitted_at: new Date().toISOString(),
  });

  logger.info("Cryptographic revoke confirmed on-chain", {
    smart_account_id: smartAccountId,
    delegation_id: delegationId,
    userOpHash,
    txHash,
    blockNumber: Number(blockNumber),
  });

  return { userOpHash, txHash, blockNumber, status: "success" };
}
