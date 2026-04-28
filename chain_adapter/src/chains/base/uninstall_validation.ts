/**
 * Cryptographic revoke encoder + executor (#58).
 *
 * This module owns the swap from the sentinel
 * `SimpleAccount.execute(self, 0, 0x)` no-op self-call to a real
 * `Kernel.uninstallValidation(bytes21 vId, bytes deinitData, bytes
 * hookDeinitData)` call. It is split into two layers:
 *
 *   - **`encodeUninstallValidationCallData`** — pure encoder. Given
 *     a 21-byte `validationId`, the deinitData blob, and an optional
 *     hookDeinitData, produces the inner ABI-encoded call to
 *     `uninstallValidation(...)`. No RPC, no secrets, no SDK
 *     dependency. Unit-testable in isolation.
 *
 *   - **`buildCryptographicRevokeCallData`** — runtime path. Takes a
 *     validated `PermissionBlock` + a `publicClient`, reconstructs
 *     the ZeroDev `PermissionPlugin` via the SDK's
 *     `deserializePermissionAccount`, recomputes `deinitData` via
 *     `plugin.getEnableData(...)`, and feeds it through the pure
 *     encoder. Hits the chain only for `getChainId` inside the
 *     deserializer.
 *
 * Broadcasting is NOT in this module's surface. The callable revoke
 * path lives in `revoke.ts`, which routes to either the sentinel
 * encoder (`buildSentinelRevokeCallData`) or the cryptographic
 * encoder here, then runs the same build+sign+submit pipeline. The
 * cryptographic path additionally requires the kernel's ROOT
 * validator (sudo) signer — see `AdapterConfig.operatorPrivateKey` —
 * because the kernel's `onlyEntryPointOrSelfOrRoot` guard blocks any
 * other signer.
 *
 * Validation invariants enforced here:
 *
 *   1. `validation_id` MUST equal `0x02 ‖ rightPad(permissionId, 20)`.
 *      The kernel uses `validationId` as the lookup key, but the
 *      ZeroDev SDK derives it deterministically from `permissionId`,
 *      so a mismatch in the dispatch payload is a programming bug.
 *   2. `package_version` MUST equal
 *      `KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion`.
 *      The pin is the audited contract surface; refusing a
 *      mismatched blob is the fail-closed posture against silent
 *      package drift.
 *
 * `KERNEL_PERMISSION_PIN.acceptedSignerContracts` /
 * `acceptedPolicyContracts` remains the declarative module set the
 * runtime is designed around, but this module does not yet introspect
 * a deserialized plugin blob deeply enough to enforce that allowlist
 * at revoke-time. That enforcement belongs with the grant-flow
 * artifact producer, where the raw signer + policy config is still
 * structured.
 *
 * Each invariant failure throws a `CryptographicRevokeError` with a
 * specific reason code so `executeRevoke` can emit a precise
 * `revoke_failed` callback rather than a generic surface.
 */

import {
  type Hex,
  type Address,
  type PublicClient,
  encodeFunctionData,
  isHex,
  pad,
  concatHex,
} from "viem";
import { deserializePermissionAccount } from "@zerodev/permissions";
import { getEntryPoint, KERNEL_V3_1 } from "@zerodev/sdk/constants";

import type { PermissionBlock } from "../../contracts/schemas.js";
import { KERNEL_PERMISSION_PIN } from "./permission_validator.js";

/**
 * `0x02` validator-type prefix for the kernel's `PERMISSION` validator
 * type. Matches `VALIDATOR_TYPE.PERMISSION` in `@zerodev/sdk` (see
 * `node_modules/@zerodev/sdk/_cjs/constants.js`).
 */
export const VALIDATOR_TYPE_PERMISSION_PREFIX = "0x02" as const satisfies Hex;

/**
 * Specific failure modes the cryptographic revoke encoder can hit.
 * `executeRevoke` maps these onto the
 * `delegation.state_changed{state: "revoke_failed"}` callback's
 * `reason` field. Each value matches the on-chain or SDK semantic
 * the failure represents — a future operator runbook can map them
 * to remediation steps.
 */
export type CryptographicRevokeFailureCode =
  | "validation_id_mismatch"
  | "package_version_mismatch"
  | "session_signer_missing"
  | "permission_deserialization_failed"
  | "deinit_computation_failed"
  | "operator_key_missing"
  | "unaccepted_signer_module"
  | "unaccepted_policy_module";

export class CryptographicRevokeError extends Error {
  constructor(
    public readonly code: CryptographicRevokeFailureCode,
    message: string,
  ) {
    super(message);
    this.name = "CryptographicRevokeError";
  }
}

/**
 * Pure encoder. Given the bytes feed `Kernel.uninstallValidation(...)`
 * needs, return the ABI-encoded inner calldata. This does NOT wrap in
 * the ERC-7579 outer envelope (that is `wrapInErc7579Execute(...)` in
 * `./erc7579.ts`).
 *
 * The encoder uses `KERNEL_PERMISSION_PIN.uninstallValidationFunction`
 * directly so the function selector cannot drift without a deliberate
 * change to the pin (which the tripwire test in
 * `test/permission-validator-pin.test.ts` enforces).
 */
export function encodeUninstallValidationCallData(args: {
  validationId: Hex;
  deinitData: Hex;
  hookDeinitData?: Hex;
}): Hex {
  if (!isHex(args.validationId) || args.validationId.length !== 44) {
    // 0x + 21 bytes × 2 hex chars/byte = 44.
    throw new CryptographicRevokeError(
      "validation_id_mismatch",
      `validation_id must be 0x + 42 hex chars (21 bytes), got: ${args.validationId.length} chars`,
    );
  }
  return encodeFunctionData({
    abi: [KERNEL_PERMISSION_PIN.uninstallValidationFunction],
    functionName: "uninstallValidation",
    args: [args.validationId, args.deinitData, args.hookDeinitData ?? "0x"],
  });
}

/**
 * Compute the canonical 21-byte `validationId` from a 4-byte
 * `permissionId`. Mirrors the SDK's
 * `concatHex([VALIDATOR_TYPE.PERMISSION, pad(permissionId, {size: 20,
 * dir: "right"})])` derivation. Exported for tests and the
 * mismatch-detection guard in `assertValidationIdConsistent`.
 */
export function deriveValidationId(permissionId: Hex): Hex {
  if (!isHex(permissionId) || permissionId.length !== 10) {
    // 0x + 4 bytes × 2 = 10.
    throw new CryptographicRevokeError(
      "validation_id_mismatch",
      `permission_id must be 0x + 8 hex chars (4 bytes), got: ${permissionId.length} chars`,
    );
  }
  return concatHex([
    VALIDATOR_TYPE_PERMISSION_PREFIX,
    pad(permissionId, { size: 20, dir: "right" }),
  ]);
}

/**
 * Refuse a `permission` block whose `validation_id` is not the exact
 * derivation of its `permission_id`. This guard does not catch all
 * tampering (an attacker who controls Phoenix's grant flow could send
 * a consistent-but-wrong pair), but it does catch paste-mismatches
 * and stale-blob serialization bugs.
 */
export function assertValidationIdConsistent(block: PermissionBlock): void {
  const derived = deriveValidationId(block.permission_id as Hex);
  if (derived.toLowerCase() !== block.validation_id.toLowerCase()) {
    throw new CryptographicRevokeError(
      "validation_id_mismatch",
      `permission_id ${block.permission_id} derives validation_id ${derived}, dispatch claims ${block.validation_id}`,
    );
  }
}

/**
 * Refuse a block whose `package_version` does not match the audited
 * `@zerodev/permissions` version pinned in `KERNEL_PERMISSION_PIN`.
 * The pin is the contract surface the cryptographic revoke is built
 * against — silently round-tripping a blob from a different package
 * version risks decoding-shape drift and is the kind of thing that
 * the
 * `permission-validator-pin.test.ts` tripwire is meant to surface
 * before it reaches production.
 */
export function assertPackageVersionPinned(block: PermissionBlock): void {
  if (
    block.package_version !==
    KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion
  ) {
    throw new CryptographicRevokeError(
      "package_version_mismatch",
      `permission.package_version ${block.package_version} does not match adapter pin ${KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion}`,
    );
  }
}

/**
 * Pure allowlist assertions enforced after
 * `deserializePermissionAccount` reconstructs a permission plugin.
 *
 * `KERNEL_PERMISSION_PIN.acceptedSignerContracts` and
 * `acceptedPolicyContracts` enumerate the ZeroDev modules the
 * runtime is willing to drive. Until these assertions ran, the
 * pin was declarative-only — its tripwire test pinned the addresses
 * against the package, but no production code rejected a blob that
 * referenced a different module. These assertions close that gap:
 * if a blob ever references a module outside the pin (e.g. a future
 * package bump introduces WebAuthn or a new policy variant we have
 * not audited), the cryptographic revoke fails closed before any
 * UserOp goes near the bundler.
 *
 * The functions are pure: input is a single 0x-prefixed address (or
 * an array thereof), comparison is case-insensitive, output is a
 * `CryptographicRevokeError` thrown on first violation. Tests can
 * exercise them against fixture addresses without mocking
 * `@zerodev/permissions` deserialization.
 *
 * The error's `code` (`unaccepted_signer_module` /
 * `unaccepted_policy_module`) is mapped to the
 * `delegation.state_changed{state: "revoke_failed"}` callback's
 * `reason` field; the offending address is logged in the structured
 * log line but deliberately NOT included in the callback payload
 * (Subagent D's redaction discipline review).
 */
export function assertSignerModuleAllowed(
  signerContractAddress: string | undefined,
  allowed: readonly Hex[] = KERNEL_PERMISSION_PIN.acceptedSignerContracts,
): void {
  if (!signerContractAddress) {
    throw new CryptographicRevokeError(
      "unaccepted_signer_module",
      "permission plugin exposes no signerContractAddress",
    );
  }
  const lc = signerContractAddress.toLowerCase();
  const ok = allowed.some((a) => a.toLowerCase() === lc);
  if (!ok) {
    throw new CryptographicRevokeError(
      "unaccepted_signer_module",
      `signer contract ${signerContractAddress} is not in KERNEL_PERMISSION_PIN.acceptedSignerContracts`,
    );
  }
}

/**
 * Validate every entry in a list of policy contract addresses
 * against the pinned allowlist. Empty list is a refusal — a
 * permission with zero policies is structurally invalid and we
 * refuse to proceed rather than silently treat it as "no
 * restrictions".
 */
export function assertPolicyModulesAllowed(
  policyContractAddresses: readonly (string | undefined)[],
  allowed: readonly Hex[] = KERNEL_PERMISSION_PIN.acceptedPolicyContracts,
): void {
  if (policyContractAddresses.length === 0) {
    throw new CryptographicRevokeError(
      "unaccepted_policy_module",
      "permission plugin carries zero policy modules",
    );
  }

  const lcAllowed = allowed.map((a) => a.toLowerCase());
  for (const addr of policyContractAddresses) {
    if (!addr) {
      throw new CryptographicRevokeError(
        "unaccepted_policy_module",
        "policy module exposes no contract address",
      );
    }
    if (!lcAllowed.includes(addr.toLowerCase())) {
      throw new CryptographicRevokeError(
        "unaccepted_policy_module",
        `policy contract ${addr} is not in KERNEL_PERMISSION_PIN.acceptedPolicyContracts`,
      );
    }
  }
}

/**
 * Extract the policy contract addresses from a deserialized
 * `PermissionPlugin`. Reads
 * `plugin.getPluginSerializationParams().policies[].policyParams.policyAddress`
 * — every reconstructed policy in `@zerodev/permissions@5.6.3`
 * carries `policyParams.policyAddress` (verified against
 * `node_modules/@zerodev/permissions/policies/*.ts`'s
 * `policyParams: { type, policyAddress, ... }` shape).
 *
 * Returns the raw values without validation; pair with
 * `assertPolicyModulesAllowed` to enforce the pin.
 *
 * Tolerates a missing `policyParams` or `policyAddress` by
 * returning `undefined` for that slot — the assertion converts
 * `undefined` into a precise refusal.
 */
export function extractPolicyContractAddresses(plugin: {
  getPluginSerializationParams: () => {
    policies?: ReadonlyArray<{
      policyParams?: { policyAddress?: string };
    }>;
  };
}): (string | undefined)[] {
  const params = plugin.getPluginSerializationParams();
  return (params.policies ?? []).map((p) => p?.policyParams?.policyAddress);
}

/**
 * Result of `buildCryptographicRevokeCallData`. The caller attaches
 * this to the outer ERC-7579 execute envelope and signs the UserOp
 * with the operator (kernel root) key.
 */
export interface CryptographicRevokeCallData {
  innerCallData: Hex;
  validationId: Hex;
}

/**
 * Reconstruct the ZeroDev permission plugin from the dispatch
 * payload's `permission.blob` and produce the inner
 * `uninstallValidation(...)` calldata. Hits the chain only for
 * `getChainId` (inside `deserializePermissionAccount`).
 *
 * Caller responsibilities:
 *   - The `publicClient` MUST be configured for the same chain the
 *     blob was produced against (caller's job; we do not cross-check
 *     here because the deserializer would just throw a less-readable
 *     error).
 *   - The caller wraps `innerCallData` in the ERC-7579 outer envelope
 *     (`wrapInErc7579Execute`) and submits the UserOp under the
 *     operator EOA. See `executeCryptographicRevoke` in
 *     `./revoke.ts`.
 *
 * Throws `CryptographicRevokeError` on any consistency / pin / SDK
 * failure so `executeRevoke` can emit a precise `revoke_failed`
 * reason.
 */
export async function buildCryptographicRevokeCallData(args: {
  block: PermissionBlock;
  publicClient: PublicClient;
  smartAccountAddress: Address;
}): Promise<CryptographicRevokeCallData> {
  // Pin guards run BEFORE any RPC so a clearly-malformed dispatch
  // does not reach into the chain at all.
  assertValidationIdConsistent(args.block);
  assertPackageVersionPinned(args.block);

  const entryPoint = getEntryPoint("0.7");

  let account;
  try {
    // `deserializePermissionAccount(client, entryPoint, kernelVersion,
    // blob, modularSigner?)` reconstructs the kernel account whose
    // `kernelPluginManager.regularValidator` is the original
    // permission plugin. We pass the blob verbatim; if it carries a
    // `privateKey` field the deserializer rebuilds the session signer
    // from it, otherwise the missing-signer branch throws — both are
    // surfaced as `permission_deserialization_failed`.
    account = await deserializePermissionAccount(
      // viem's `PublicClient` and ZeroDev's expected `Client` type
      // diverged across viem minor versions; the runtime call works
      // fine since both share the JSON-RPC surface
      // `deserializePermissionAccount` actually invokes (`getChainId`).
      args.publicClient as never,
      entryPoint,
      KERNEL_V3_1,
      args.block.blob,
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    throw new CryptographicRevokeError(
      "permission_deserialization_failed",
      `deserializePermissionAccount failed: ${message}`,
    );
  }

  const plugin = (
    account as unknown as {
      kernelPluginManager: { regularValidator?: { getEnableData?: unknown } };
    }
  ).kernelPluginManager.regularValidator;
  if (
    !plugin ||
    typeof (plugin as { getEnableData?: unknown }).getEnableData !== "function"
  ) {
    throw new CryptographicRevokeError(
      "permission_deserialization_failed",
      "deserializePermissionAccount returned an account with no regular validator (the blob is not a permission account)",
    );
  }

  let deinitData: Hex;
  try {
    // Per `@zerodev/permissions` `toPermissionValidator.ts`,
    // `getEnableData` ignores its kernelAccountAddress argument; we
    // pass the smart-account address for symmetry with the SDK's
    // `uninstallPlugin` action even though it is unused inside the
    // closure. Returns `abi.encode(bytes[], [...policies, signer])` —
    // the same blob the kernel sees stored under this validator's
    // permission slot.
    deinitData = (await (
      plugin as { getEnableData: (addr: Address) => Promise<Hex> }
    ).getEnableData(args.smartAccountAddress)) as Hex;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    throw new CryptographicRevokeError(
      "deinit_computation_failed",
      `plugin.getEnableData failed: ${message}`,
    );
  }

  const innerCallData = encodeUninstallValidationCallData({
    validationId: args.block.validation_id as Hex,
    deinitData,
    hookDeinitData: "0x",
  });

  return { innerCallData, validationId: args.block.validation_id as Hex };
}
