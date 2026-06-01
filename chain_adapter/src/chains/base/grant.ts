/**
 * Cryptographic GRANT executor (#58 grant flow).
 *
 * Builds a real ZeroDev `PermissionPlugin` via
 * `toPermissionValidator(...)`, installs it on the kernel account
 * by sending a regular-validator UserOp whose signature carries the
 * sudo-signed enable data for that permission validator, then calls
 * `serializePermissionAccount(account, undefined)` to produce a
 * KEYLESS plugin blob and emits a
 * `delegation.state_changed{state: "granted"}` callback whose
 * `permission` block carries everything Phoenix needs to drive a
 * later cryptographic revoke.
 *
 * ## Why keyless
 *
 * Subagent D's security review of PR #129's grant-flow follow-up
 * confirmed that `serializePermissionAccount(account,
 * sessionPrivateKey)` embeds the key VERBATIM in the base64 blob.
 * Persisting that in Phoenix would make the control plane hold a
 * signing key — a hard violation of CryptoKorr's threat model
 * (adapter-only signers). We therefore call
 * `serializePermissionAccount(account, undefined)` and ship the
 * `session_signer_address` as a separate field. At revoke-time
 * `deserializePermissionAccount` accepts an external
 * `modularSigner` whose `account.address` equals that value;
 * `getEnableData(...)` only reads the address (no signing during
 * revoke), so no private key ever needs to leave the adapter.
 *
 * ## Why the operator (sudo) key MUST be configured
 *
 * The kernel account at `config.smartAccountAddress` was
 * provisioned with the operator EOA as its root validator
 * (`provision-kernel.ts`). Any plugin install requires the sudo
 * EIP-712 signature on the enable typed data — only that EOA's
 * key produces a valid one. If `config.operatorPrivateKey` is
 * missing the grant fails closed: it emits
 * `delegation.state_changed{state: "grant_failed", reason:
 * "operator_key_missing"}` with NO `permission` block, so Phoenix
 * does not create an active delegation row.
 *
 * Errors at every other step (deserialization-shape failures,
 * RPC errors, bundler rejections, install reversion) emit a
 * `grant_failed` callback with a precise `reason`. The dispatch
 * handler is still 202 — failures are reported via callback
 * shape, not HTTP status, matching the rest of the adapter
 * contract.
 */

import {
  type Address,
  type Chain,
  type Hash,
  type Hex,
  concatHex,
  http,
  pad,
  zeroAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import type { AdapterConfig } from "../../config/index.js";
import type { CallbackClient } from "../../callbacks/client.js";
import { nextCallbackId } from "../../callbacks/client.js";
import type { BaseClients } from "./client.js";
import { logger } from "../../lib/logger.js";
import { ExecutionError } from "../../lib/errors.js";
import { KERNEL_PERMISSION_PIN } from "./permission_validator.js";

/**
 * Specific failure codes emitted via `delegation.state_changed`
 * `reason` on the `grant_failed` callback path.
 * Mapping each to a stable code lets a future operator runbook
 * match remediation steps to specific failure modes.
 */
export type GrantFailureCode =
  | "operator_key_missing"
  | "permission_install_failed"
  | "permission_serialization_failed"
  | "chain_id_mismatch";

/** Result of a successful grant. Returned for tests + logging. */
export interface GrantResult {
  permissionId: Hex;
  validationId: Hex;
  sessionSignerAddress: Address;
  installTxHash: Hash;
  installBlockNumber: bigint;
  blob: string;
}

// Permission install gas is small, but estimating it through a bundler
// can fail because viem/ZeroDev prepares the estimate with the regular
// validator's dummy stub signature. Kernel v3 validates the enable path
// strictly enough that some bundlers reject the stub before the final
// sudo-signed enable signature is attached. Supplying conservative
// limits skips that fragile estimate while still letting the bundler
// simulate + submit the final signed UserOp.
const PERMISSION_INSTALL_GAS_LIMITS = {
  callGasLimit: 500_000n,
  verificationGasLimit: 1_000_000n,
  preVerificationGas: 100_000n,
} as const;

/**
 * Execute the on-chain grant: build a permission plugin, install
 * it on the kernel account, serialize the resulting account
 * (KEYLESS), emit the granted callback. Throws `ExecutionError`
 * on any step that fails AFTER emitting a precise failure
 * callback.
 */
export async function executeGrant(args: {
  smartAccountId: string;
  chainId: number;
  account: string;
  scope: Record<string, unknown>;
  config: AdapterConfig;
  clients: BaseClients;
  callbackClient: CallbackClient;
}): Promise<GrantResult> {
  const { smartAccountId, chainId, scope, config, clients, callbackClient } =
    args;

  // Guard 1: operator key must be configured. Without it the
  // sudo-signed EIP-712 enable signature cannot be produced and
  // the kernel will refuse the install. Refuse BEFORE any RPC.
  if (!config.operatorPrivateKey || !config.operatorAddress) {
    return await emitGrantFailure({
      smartAccountId,
      callbackClient,
      reason: "operator_key_missing",
      message:
        "Cryptographic grant requested but OPERATOR_PRIVATE_KEY / OPERATOR_ADDRESS is not configured.",
    });
  }

  // Guard 2: refuse a chain mismatch up-front. The dispatch carries
  // the chain id so Phoenix can target either Base or Base Sepolia
  // independently; the adapter is configured for exactly one.
  if (chainId !== config.baseChainId) {
    return await emitGrantFailure({
      smartAccountId,
      callbackClient,
      reason: "chain_id_mismatch",
      message: `Dispatch chain_id=${chainId} does not match adapter baseChainId=${config.baseChainId}`,
    });
  }

  logger.info("Executing Base delegation grant (cryptographic install)", {
    smart_account_id: smartAccountId,
    chain_id: chainId,
    smart_account: clients.smartAccountAddress,
    scope_keys: Object.keys(scope),
  });

  // Lazy import: keeps the SDK out of the cold path for adapters
  // that never grant cryptographically. These are production
  // dependencies because both grant and cryptographic revoke load
  // them at runtime. Same pattern `executeCryptographicRevoke` uses.
  let result: GrantResult;
  try {
    const sdk = await import("@zerodev/sdk");
    const sdkConstants = await import("@zerodev/sdk/constants");
    const ecdsaValidator = await import("@zerodev/ecdsa-validator");
    const permissions = await import("@zerodev/permissions");
    const permissionsSigners = await import("@zerodev/permissions/signers");
    const permissionsPolicies = await import("@zerodev/permissions/policies");

    const entryPoint = sdkConstants.getEntryPoint("0.7");
    const kernelVersion = sdkConstants.KERNEL_V3_1;

    // SECRET: operator EOA. Used to sign the install UserOp's
    // enable typed-data. Never logged.
    const operatorAccount = privateKeyToAccount(config.operatorPrivateKey);
    const sudoValidator = await ecdsaValidator.signerToEcdsaValidator(
      clients.publicClient as never,
      {
        signer: operatorAccount,
        entryPoint,
        kernelVersion,
      },
    );

    // SECRET: runtime session-key EOA. This MUST be the configured
    // `DELEGATION_SIGNER_KEY`, not a throwaway generated key:
    // later UserOperations under the installed permission are
    // signed by the adapter's runtime delegation signer. Installing
    // the permission for a key we immediately discard would make
    // the permission impossible to use.
    const sessionAccount = privateKeyToAccount(
      config.delegationSignerKey as `0x${string}`,
    );
    const sessionSigner = await permissionsSigners.toECDSASigner({
      signer: sessionAccount,
    });

    // Build the permission plugin with a minimal sudo policy. v0.1
    // grants do not yet thread the wallet-connect `scope` into
    // ZeroDev policy parameters; that is a follow-up. The sudo
    // policy is acceptable for v0.1 because Phoenix's outer
    // policy gate (decision flow + risk checks) still enforces
    // every transfer's authorization independently of the
    // on-chain permission's scope.
    const permissionPlugin = await permissions.toPermissionValidator(
      clients.publicClient as never,
      {
        signer: sessionSigner,
        policies: [permissionsPolicies.toSudoPolicy({})],
        entryPoint,
        kernelVersion,
      },
    );

    // permissionId is bytes4 (4-byte hex, 10 chars including 0x).
    const permissionId = permissionPlugin.getIdentifier() as Hex;
    const validationId = concatHex([
      // VALIDATOR_TYPE.PERMISSION; same value `executeCryptographicRevoke`
      // pads against. Pinned in `uninstall_validation.ts`.
      "0x02",
      pad(permissionId, { size: 20, dir: "right" }),
    ]);

    // Build the account with both slots: the deployed ECDSA root
    // validator signs the enable typed-data, while the permission
    // validator is the active regular validator for the UserOp.
    // ZeroDev permissions are virtual (the plugin address is
    // zeroAddress), so do NOT try to install them through
    // `pluginMigrations` / `installModule`; the install happens through
    // the enable signature carried in the UserOp signature.
    const kernelAccount = await sdk.createKernelAccount(
      clients.publicClient as never,
      {
        entryPoint,
        kernelVersion,
        plugins: { sudo: sudoValidator, regular: permissionPlugin },
        address: clients.smartAccountAddress,
      },
    );

    const kernelClient = sdk.createKernelAccountClient({
      account: kernelAccount,
      chain: (clients.publicClient as { chain?: Chain }).chain,
      bundlerTransport: http(config.bundlerRpcUrl),
      client: clients.publicClient as never,
    });

    // Install: Kernel's permission state change happens in validation
    // when the enable signature is accepted. The execution phase still
    // needs a syntactically real call for ZeroDev's encoder, so use an
    // inert zero-value call to address(0). There is no user-level
    // target side effect.
    let userOpHash: Hash;
    let receiptTxHash: Hash;
    let receiptBlockNumber: bigint;
    try {
      userOpHash = (await kernelClient.sendUserOperation({
        callData: await kernelAccount.encodeCalls([
          {
            to: zeroAddress,
            value: 0n,
            data: "0x",
          },
        ]),
        ...PERMISSION_INSTALL_GAS_LIMITS,
      })) as Hash;

      const receipt = await kernelClient.waitForUserOperationReceipt({
        hash: userOpHash,
      });

      if (!receipt.success) {
        const reason = receipt.reason ?? "permission_install_reverted";
        return await emitGrantFailure({
          smartAccountId,
          callbackClient,
          reason: "permission_install_failed",
          message: `Install UserOp reverted: ${reason}`,
        });
      }

      receiptTxHash = receipt.receipt.transactionHash as Hash;
      receiptBlockNumber = receipt.receipt.blockNumber as bigint;
    } catch (err) {
      if (err instanceof ExecutionError) throw err;
      const message = redactGrantError(err);
      return await emitGrantFailure({
        smartAccountId,
        callbackClient,
        reason: "permission_install_failed",
        message: `Install UserOp failed: ${message}`,
      });
    }

    // KEYLESS serialization. Pass `undefined` for privateKey so the
    // session private key never crosses the wire. The public signer
    // address is sent separately as `session_signer_address`.
    let blob: string;
    try {
      blob = await permissions.serializePermissionAccount(
        kernelAccount as never,
        undefined,
      );
    } catch (err) {
      const message = redactGrantError(err);
      return await emitGrantFailure({
        smartAccountId,
        callbackClient,
        reason: "permission_serialization_failed",
        message: `serializePermissionAccount failed: ${message}`,
      });
    }

    result = {
      permissionId,
      validationId,
      sessionSignerAddress: sessionAccount.address,
      installTxHash: receiptTxHash,
      installBlockNumber: receiptBlockNumber,
      blob,
    };
  } catch (err) {
    if (err instanceof ExecutionError) throw err;
    const message = redactGrantError(err);
    return await emitGrantFailure({
      smartAccountId,
      callbackClient,
      reason: "permission_install_failed",
      message: `Grant flow failed: ${message}`,
    });
  }

  // Successful grant: emit the granted callback with the full
  // permission block. Phoenix decodes the block in
  // `Bank.Delegations.apply_callback/1`'s "granted" branch.
  await callbackClient.send({
    contract_version: 1,
    callback_id: nextCallbackId(),
    kind: "delegation.state_changed",
    smart_account_id: smartAccountId,
    delegation_id: result.permissionId,
    state: "granted",
    reason: "wallet_connect_install",
    permission: {
      blob: result.blob,
      permission_id: result.permissionId,
      validation_id: result.validationId,
      kernel_version: KERNEL_VERSION_STRING,
      package_version:
        KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion,
      session_signer_address: result.sessionSignerAddress,
      installed_at_block: Number(result.installBlockNumber),
      install_tx_hash: result.installTxHash,
    },
    emitted_at: new Date().toISOString(),
  });

  logger.info("Cryptographic grant confirmed on-chain", {
    smart_account_id: smartAccountId,
    permission_id: result.permissionId,
    validation_id: result.validationId,
    install_tx_hash: result.installTxHash,
    install_block: Number(result.installBlockNumber),
  });

  return result;
}

/**
 * Emit a failure-shaped `grant_failed` callback (no `permission`
 * block, specific `reason`) and throw `ExecutionError`. The dispatch
 * handler unwraps the error so the outer 202 is preserved — the
 * callback shape is how Phoenix learns that the grant failed
 * without losing the audit anchor. It must NOT be reported as
 * `state: "granted"` because that creates an active delegation row.
 */
async function emitGrantFailure(args: {
  smartAccountId: string;
  callbackClient: CallbackClient;
  reason: GrantFailureCode;
  message: string;
}): Promise<never> {
  logger.error("Cryptographic grant failed", {
    smart_account_id: args.smartAccountId,
    code: args.reason,
    error: args.message,
  });

  await args.callbackClient.send({
    contract_version: 1,
    callback_id: nextCallbackId(),
    kind: "delegation.state_changed",
    smart_account_id: args.smartAccountId,
    // The wire-level `delegation_id` for failed grants is a
    // synthetic placeholder — the row stays opaque on Phoenix.
    // Real grants set it to the 4-byte permissionId hex.
    delegation_id: `grant_failed_${Date.now()}`,
    state: "grant_failed",
    reason: args.reason,
    emitted_at: new Date().toISOString(),
  });

  throw new ExecutionError(args.reason, args.message);
}

/**
 * Kernel implementation version pinned for this adapter. Stays in
 * lockstep with `provision-kernel.ts`'s `PINNED_KERNEL_VERSION`.
 * Exposed as a constant string here (not the SDK enum) so the
 * granted callback's `kernel_version` field is wire-friendly.
 */
const KERNEL_VERSION_STRING = "0.3.1";

/**
 * Strip URLs from grant-flow error messages before logging /
 * emitting them. The bundler RPC URL contains an API key in many
 * provider configurations (Pimlico, Alchemy AA), and viem's HTTP
 * errors include the request URL by default. This helper is a
 * narrower copy of `scripts/redact.ts`'s `redactErrorMessage` so
 * the `src/` tree does not depend on `scripts/` (TypeScript's
 * `rootDir` excludes the latter).
 *
 * The replacement keeps the protocol + host so an operator
 * triaging a callback can still recognise the destination
 * provider, but drops everything after the host.
 */
function redactGrantError(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err);
  return raw.replace(
    /(https?:)\/\/([^/\s"]+)\/[^\s"]*/g,
    "$1//$2/<redacted>",
  );
}
