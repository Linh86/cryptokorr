/**
 * UserOperation builder and signer for ERC-4337 v0.7.
 *
 * The adapter owns a single deployed smart account in v0.1 and signs
 * UserOperations with a delegation key. The signer's authority is
 * enforced by the smart account's validation function (a module/hook
 * in most implementations) — the adapter does not need to know the
 * internals; it just submits a signature over the canonical v0.7
 * user-op hash.
 *
 * This module is deliberately narrow:
 *
 *   - `buildTransferCallData` wraps an ERC-20 `transfer(...)` call in
 *     `SimpleAccount.execute(target, value, innerCalldata)`.
 *   - `buildExecuteCallData` is the generic form (used by the revoke
 *     sentinel).
 *   - `buildAndSignUserOp` prepares a full v0.7 UserOperation: pulls a
 *     fresh nonce from the EntryPoint, sets fee fields from the chain,
 *     has the bundler estimate the three gas limits, then signs the
 *     canonical user-op hash with the delegation key.
 *
 * No paymaster wiring in v0.1. Account is assumed deployed (no
 * factory/initCode). Those extensions fit cleanly here without
 * changing callers.
 */

import {
  encodeFunctionData,
  type Address,
  type Hex,
} from "viem";
import {
  entryPoint07Abi,
  getUserOperationHash,
  type UserOperation,
} from "viem/account-abstraction";
import type { PrivateKeyAccount } from "viem/accounts";
import { ERC20_TRANSFER_ABI } from "./usdc.js";
import { SIMPLE_ACCOUNT_EXECUTE_ABI } from "./entrypoint.js";
import type { BundlerClient } from "./bundler.js";

/**
 * Structural minimum of the viem `PublicClient` features this module
 * needs. Widened from `PublicClient` so callers with chain-specific
 * client types (Base has a `deposit` tx type, etc.) don't need to
 * fight generic parameters — the builder touches only these three
 * methods.
 */
type UserOpPublicClient = {
  chain: { id: number } | null;
  readContract: (args: {
    address: Address;
    abi: typeof entryPoint07Abi;
    functionName: "getNonce";
    args: readonly [Address, bigint];
  }) => Promise<bigint>;
  estimateFeesPerGas: () => Promise<{
    maxFeePerGas: bigint;
    maxPriorityFeePerGas: bigint;
  }>;
};

/** Encode `IERC20.transfer(to, amount)` — the inner call. */
export function encodeErc20Transfer(
  to: Address,
  amount: bigint,
): Hex {
  return encodeFunctionData({
    abi: ERC20_TRANSFER_ABI,
    functionName: "transfer",
    args: [to, amount],
  });
}

/**
 * Wrap an inner (target, value, data) call into
 * `SimpleAccount.execute(...)` calldata that the smart account's
 * EntryPoint-triggered execution will dispatch.
 */
export function buildExecuteCallData(
  target: Address,
  value: bigint,
  innerCallData: Hex,
): Hex {
  return encodeFunctionData({
    abi: SIMPLE_ACCOUNT_EXECUTE_ABI,
    functionName: "execute",
    args: [target, value, innerCallData],
  });
}

/**
 * Convenience: build a UserOperation `callData` that executes an
 * ERC-20 transfer from the smart account.
 */
export function buildTransferCallData(
  tokenAddress: Address,
  to: Address,
  amount: bigint,
): Hex {
  return buildExecuteCallData(tokenAddress, 0n, encodeErc20Transfer(to, amount));
}

/**
 * Build the SENTINEL inner calldata for a delegation revoke.
 *
 * In v0.1 the adapter has no permission-module ABI to call, so the
 * "revoke" user-op carries a no-op self-call: `execute(self, 0, 0x)`.
 * This is a real on-chain anchor (real user-op hash, real receipt,
 * real failure modes) but it does NOT cryptographically disable the
 * delegation key at the contract level.
 *
 * Phoenix issue #31 stays open until the prereqs in #56/#57/#58
 * land. The architectural decision is recorded in the Phoenix repo at
 * `docs/smart-account-and-revoke-design.md` (GitHub #56):
 *
 *   1. Smart-account implementation — DECIDED in #56: Kernel v3
 *      (ERC-7579) modular account on Base. SimpleAccount has no
 *      module system and the signing key IS the owner, so a real
 *      revoke is structurally impossible against it; Kernel's
 *      Permission Validator pattern gives us a per-delegation
 *      `bytes32 permissionId` we can disable independently.
 *   2. Adapter env scaffolding + mapping convention + verifiable
 *      ERC-7579 outer wrap — LANDED in #57. See
 *      `permission_validator.ts`, `erc7579.ts`, and the strict
 *      accessor `requirePermissionValidatorAddress` in `config/index.ts`.
 *   3. Permission Validator address + verified disable ABI fragment
 *      + the swap in `executeRevoke` — PENDING for #58. The validator
 *      interface was deliberately not pinned at #57 because doing so
 *      from a plausible reference name (without verifying it against
 *      the bytecode of an actual deployment) would surface as a silent
 *      on-chain revert at the first real revoke.
 *
 * When #58 lands, this function body is replaced. The replacement
 * uses a different OUTER envelope as well as a different inner body:
 *
 *     // Outer: ERC-7579, not SimpleAccount.
 *     buildErc7579ExecuteCallData(
 *       PERMISSION_VALIDATOR_ADDRESS,
 *       0n,
 *       encodeFunctionData({
 *         abi: KERNEL_PERMISSION_VALIDATOR_ABI, // pinned at #58 time
 *         functionName: KERNEL_PERMISSION_DISABLE_FUNCTION,
 *         args: [permissionId],
 *       }),
 *     )
 *
 * The callback shape, idempotency, AA pipeline, and Phoenix state
 * machine all stay the same. The tripwire test
 * `test/base-revoke-sentinel-pin.test.ts` exists specifically to
 * fail loudly if anyone substitutes a different inner call without
 * also updating the contract docs and closing #31.
 */
export function buildSentinelRevokeCallData(
  smartAccountAddress: Address,
): Hex {
  return buildExecuteCallData(smartAccountAddress, 0n, "0x" as Hex);
}

export interface BuildUserOpParams {
  publicClient: UserOpPublicClient;
  bundlerClient: BundlerClient;
  signer: PrivateKeyAccount;
  entryPointAddress: Address;
  smartAccountAddress: Address;
  callData: Hex;
  /** Optional nonce key for AA 2D nonces. Defaults to 0 (serial nonces). */
  nonceKey?: bigint;
}

export interface BuildUserOpResult {
  userOperation: UserOperation<"0.7">;
  userOpHash: Hex;
}

/**
 * Build + sign a v0.7 UserOperation end-to-end. Pulls the nonce from
 * the EntryPoint, fee fields from the chain, and estimated gas limits
 * from the bundler; the delegation key signs the canonical
 * `getUserOperationHash` result.
 *
 * In v0.1 there is no paymaster and the smart account is already
 * deployed, so factory/initCode fields stay unset.
 */
export async function buildAndSignUserOp(
  params: BuildUserOpParams,
): Promise<BuildUserOpResult> {
  const {
    publicClient,
    bundlerClient,
    signer,
    entryPointAddress,
    smartAccountAddress,
    callData,
    nonceKey = 0n,
  } = params;

  const nonce = await publicClient.readContract({
    address: entryPointAddress,
    abi: entryPoint07Abi,
    functionName: "getNonce",
    args: [smartAccountAddress, nonceKey],
  });

  const fees = await publicClient.estimateFeesPerGas();
  const maxFeePerGas = fees.maxFeePerGas;
  const maxPriorityFeePerGas = fees.maxPriorityFeePerGas;

  // Pre-signature user-op with zeroed gas limits — the bundler fills
  // these in via `eth_estimateUserOperationGas`. Signature is a
  // throwaway value during estimation; the final signature is produced
  // after estimation, so the signed operation reflects the real gas
  // fields the bundler will enforce.
  const estimation = await bundlerClient.estimateUserOperationGas({
    account: undefined,
    entryPointAddress,
    sender: smartAccountAddress,
    nonce,
    callData,
    callGasLimit: 0n,
    verificationGasLimit: 0n,
    preVerificationGas: 0n,
    maxFeePerGas,
    maxPriorityFeePerGas,
    signature:
      "0xfffffffffffffffffffffffffffffff0000000000000000000000000000000007aa8b5bef47cfe4f89ac9a2bce0cfc5ea94e5d5d9ccba0edd0c6d5e34a85a7d61b" as Hex,
  });

  const unsigned: UserOperation<"0.7"> = {
    sender: smartAccountAddress,
    nonce,
    callData,
    callGasLimit: estimation.callGasLimit,
    verificationGasLimit: estimation.verificationGasLimit,
    preVerificationGas: estimation.preVerificationGas,
    maxFeePerGas,
    maxPriorityFeePerGas,
    signature: "0x" as Hex,
  };

  const userOpHash = getUserOperationHash({
    chainId: publicClient.chain!.id,
    entryPointAddress,
    entryPointVersion: "0.7",
    userOperation: unsigned,
  });

  const signature = await signer.signMessage({
    message: { raw: userOpHash },
  });

  return {
    userOperation: { ...unsigned, signature },
    userOpHash,
  };
}

/**
 * Format a `bigint` nonce as a canonical hex string for callbacks.
 * Phoenix persists `tx_refs` as opaque strings in v0.1 — hex preserves
 * the full 256-bit nonce including the 192-bit key prefix used by
 * 2D-nonce schemes.
 */
export function formatNonceHex(nonce: bigint): Hex {
  return `0x${nonce.toString(16)}` as Hex;
}

/**
 * Compare the locally computed canonical user-op hash against what the
 * bundler returned from `eth_sendUserOperation`.
 *
 * EIP-4337 mandates that these two values are byte-for-byte equal:
 * both sides hash the same canonical fields with the same algorithm.
 * A divergence means one of:
 *
 *   - the bundler is buggy or running an incompatible EntryPoint
 *     version;
 *   - a proxy / MITM has rewritten the user-op in flight;
 *   - the bundler is silently routing to a different chain than the
 *     adapter computed the hash against.
 *
 * Any of those breaks Phoenix's audit trail: the user-op hash IS the
 * identity that the control tower, the bundler RPC, and the operator
 * use to look up the operation later. If we adopted the bundler's
 * value blindly we would track the wrong operation. The adapter
 * therefore keeps the locally computed hash as the source of truth
 * and aborts on mismatch.
 *
 * Comparison is case-insensitive (some bundlers return checksummed
 * hex while viem produces lowercase) but otherwise byte-exact.
 */
export function userOpHashesEqual(local: Hex, bundlerReturned: Hex): boolean {
  return local.toLowerCase() === bundlerReturned.toLowerCase();
}
