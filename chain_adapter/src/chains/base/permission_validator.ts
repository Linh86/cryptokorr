/**
 * Pin slot for the ZeroDev kernel permission system. Currently
 * `null`. The original design here was wrong; this file documents
 * the correction and reserves a typed slot for the future, real
 * integration tracked in `docs/zerodev-permissions-integration.md`.
 *
 * ## What this file used to claim
 *
 * Earlier revisions exported `permissionIdFromDelegationId` /
 * `delegationIdFromPermissionId` mapping helpers, a
 * `VerifiedPermissionValidator` interface, and a
 * `KERNEL_PERMISSION_VALIDATOR_PIN` constant — all built around the
 * assumption that ZeroDev's permissions architecture has a single
 * deployable Permission Validator contract at one address with a
 * single `disablePermission(bytes32)` ABI fragment. That assumption
 * is wrong.
 *
 * ## What ZeroDev's `@zerodev/permissions@5.6.3` actually exposes
 *
 *   - `toPermissionValidator()` returns a plugin object whose
 *     `.address === zeroAddress`. There is NO single Permission
 *     Validator contract address to pin.
 *   - The on-chain primitives are CREATE2-deployed (same address on
 *     every chain) signer + policy modules:
 *       * signers: `ECDSA_SIGNER_CONTRACT`,
 *         `WEBAUTHN_SIGNER_CONTRACT_V0_0_4`, …
 *       * policies: `CALL_POLICY_CONTRACT_V0_0_5`, `GAS_POLICY_CONTRACT`,
 *         `RATE_LIMIT_POLICY_CONTRACT`, `SUDO_POLICY_CONTRACT`,
 *         `SIGNATURE_POLICY_CONTRACT`, `TIMESTAMP_POLICY_CONTRACT`, …
 *   - `permissionId` is `bytes4` (4 bytes / 8 hex chars), computed
 *     as `keccak256(abi.encode(policyAndSignerData))[0:4]`. The
 *     earlier helpers in this file enforced 66 chars (0x + 64 hex,
 *     i.e. `bytes32`) and would have rejected every real ZeroDev
 *     permissionId.
 *   - The on-chain revoke entry point is
 *     `Kernel.uninstallValidation(bytes21 vId, bytes deinitData,
 *     bytes hookDeinitData)`, called ON the smart account itself —
 *     not on a separate validator contract. `vId` packs the 4-byte
 *     `permissionId` right-padded to 20 bytes, prefixed by the
 *     `0x02` validator-type tag; `deinitData` is a multi-policy
 *     payload that requires reconstructing the same plugin object
 *     used at grant-time.
 *
 * ## Why the file is intentionally thin today
 *
 * The corrected pin is not a single ABI fragment. It is a tuple of
 * canonical CREATE2 module addresses, the kernel implementation's
 * bytecode hash for the chosen kernel version, and the npm version
 * range of `@zerodev/permissions` whose exported constants the
 * runtime accepts. None of those values are decided in this repo
 * yet — `@zerodev/sdk` and `@zerodev/permissions` are not even
 * listed as runtime deps in `chain_adapter/package.json`. The
 * concrete `KernelPermissionPin` shape and the `executeRevoke`
 * call-site changes will land alongside the SDK integration.
 *
 * ## What survives the correction
 *
 *   - The wire-level `delegation_id` field (Phoenix → adapter via
 *     `DispatchRevokeDelegationSchema`) is still a meaningful
 *     opaque identifier — only the FORMAT-enforcing helpers below
 *     were wrong, not the threading.
 *   - The ERC-7579 outer-execute envelope pin in `./erc7579.ts`
 *     (selector `0xe9ae5c53`) is independent of the permission
 *     model above it. Kernel v3 still routes execution through
 *     this envelope.
 *   - The sentinel revoke body (`SimpleAccount.execute(self, 0,
 *     0x)`) is unaffected — it does not depend on any validator
 *     concept.
 *
 * Tracking: GitHub #83 (was: "verify validator ABI"; now: "design
 * the ZeroDev permission pin and integrate the SDK"). #58 ("swap
 * sentinel for cryptographic revoke") still depends on #83 +
 * provisioning under #84, but both #83 and #84 now need re-scoping
 * before they can produce verifiable artifacts. See
 * `docs/zerodev-permissions-integration.md` for the corrected
 * model and hard blockers.
 */

import type { AbiFunction, Hex } from "viem";

/**
 * Reserved type for the future ZeroDev permission pin. Every field
 * shape here is provisional pending the SDK integration described
 * in `docs/zerodev-permissions-integration.md`. Populating this
 * slot is part of #83.
 *
 * NOTE: this interface deliberately does NOT include a single
 * `validatorAddress` or `disableFunction` field. The earlier
 * version did, and that was the bug.
 */
export interface KernelPermissionPin {
  /**
   * The ZeroDev signer contracts (CREATE2 — same address on every
   * chain) the runtime is willing to accept. Pinning here lets
   * startup refuse to revoke against a permission whose signer
   * module is unknown to the adapter.
   */
  acceptedSignerContracts: readonly `0x${string}`[];

  /**
   * The ZeroDev policy contracts the runtime is willing to accept,
   * same posture as `acceptedSignerContracts`.
   */
  acceptedPolicyContracts: readonly `0x${string}`[];

  /**
   * Pinned npm version range of `@zerodev/permissions` whose
   * exported constants match the addresses above. The adapter
   * refuses to start if the runtime SDK version is outside this
   * range.
   */
  zeroDevPermissionsPackageVersion: string;

  /** Provenance for the pin. */
  artifactSource: {
    kind:
      | "etherscan_verified_contract"
      | "basescan_verified_contract"
      | "vendor_audited_package"
      | "vendor_deployment_manifest";
    url: string;
    note: string;
  };

  /**
   * The kernel-account method `Kernel.uninstallValidation(bytes21,
   * bytes, bytes)` is the on-chain entry point for per-permission
   * revoke. Pinned here so the selector cannot drift without a
   * deliberate change. Not a field on a validator contract — it is
   * a method on the smart account itself.
   */
  uninstallValidationFunction: AbiFunction;
}

/**
 * Pinned ZeroDev kernel permission configuration.
 *
 * Populated under #83 against `@zerodev/permissions@5.6.3` (the
 * adapter's devDependency, audited at install time via
 * `npm ci`'s lockfile resolution). Every address below is sourced
 * from that package's `constants.ts` export and is verified
 * byte-for-byte by `test/permission-validator-pin.test.ts`. The
 * `uninstallValidationFunction` ABI fragment is verified the same
 * way against `KernelV3_1AccountAbi` from `@zerodev/sdk@5.5.10`.
 *
 * The pin is purely declarative today. The runtime revoke path is
 * still sentinel; #58 is the change that wires this pin into
 * `executeRevoke` (alongside the remaining hard blockers in
 * `docs/zerodev-permissions-integration.md`: per-account sudo
 * signer, plugin-blob persistence, on-the-wire `delegation_id`
 * encoding, per-permission vs `invalidateNonce` design call).
 *
 * Editing this constant in any way must:
 *
 *   1. Re-run `test/permission-validator-pin.test.ts` to confirm
 *      the new values still match the package the lockfile pulls.
 *   2. Update `docs/zerodev-permissions-integration.md` and
 *      `docs/smart-account-and-revoke-design.md` if the change
 *      reflects a change in which signer / policy modules the
 *      runtime is willing to drive.
 */
export const KERNEL_PERMISSION_PIN: KernelPermissionPin = {
  // The signer modules the runtime is willing to accept on a
  // permission. Addresses are CREATE2-deployed by ZeroDev and are
  // therefore the same on Base mainnet (8453) and Base Sepolia
  // (84532). Currently ECDSA only — WebAuthn signers are not
  // wired, and adding them would require a separate product
  // decision plus additional adapter integration.
  acceptedSignerContracts: [
    "0x6A6F069E2a08c2468e7724Ab3250CdBFBA14D4FF", // ECDSA_SIGNER_CONTRACT
  ],

  // The policy modules the runtime is willing to accept on a
  // permission. Same CREATE2 same-address-every-chain posture as
  // signers above. Earlier `CALL_POLICY_CONTRACT_V0_0_1`–`V0_0_4`
  // versions and `WEBAUTHN_SIGNER_CONTRACT_V0_0_1`–`V0_0_3` are
  // intentionally excluded — the latest version of each module is
  // listed here, and a future migration that needs an older
  // version must add it explicitly with reviewer attention.
  acceptedPolicyContracts: [
    "0x85770b902D1e503D5f5141d9eaC16d0d08eEaDd2", // CALL_POLICY_CONTRACT_V0_0_5
    "0xaeFC5AbC67FfD258abD0A3E54f65E70326F84b23", // GAS_POLICY_CONTRACT
    "0xf63d4139B25c836334edD76641356c6b74C86873", // RATE_LIMIT_POLICY_CONTRACT
    "0xF6A936c88D97E6fad13b98d2FD731Ff17eeD591d", // SIGNATURE_POLICY_CONTRACT
    "0x67b436caD8a6D025DF6C82C5BB43fbF11fC5B9B7", // SUDO_POLICY_CONTRACT
    "0xB9f8f524bE6EcD8C945b1b87f9ae5C192FdCE20F", // TIMESTAMP_POLICY_CONTRACT
  ],

  // Pinned npm version of `@zerodev/permissions` whose exported
  // constants the addresses above were verified against. The
  // lockfile + the tripwire test together enforce that the
  // resolved package version stays compatible.
  zeroDevPermissionsPackageVersion: "5.6.3",

  artifactSource: {
    kind: "vendor_audited_package",
    url: "https://www.npmjs.com/package/@zerodev/permissions/v/5.6.3",
    note:
      "Addresses sourced from `constants.ts` in the `@zerodev/permissions@5.6.3` " +
      "tarball. Confirmed CREATE2 same-on-every-chain via contractscan.xyz for " +
      "ECDSA_SIGNER_CONTRACT and CALL_POLICY_CONTRACT_V0_0_5; the rest of the " +
      "modules are deployed by the same factory pattern per the package README.",
  },

  // `Kernel.uninstallValidation(bytes21,bytes,bytes)` is the
  // on-chain entry point for per-permission revoke under the
  // corrected ZeroDev model. Verified byte-for-byte against
  // `KernelV3_1AccountAbi.uninstallValidation` in the
  // `@zerodev/sdk@5.5.10` tarball by the tripwire test. The method
  // is on the smart account itself, not on a separate validator
  // contract.
  uninstallValidationFunction: {
    type: "function",
    name: "uninstallValidation",
    inputs: [
      { name: "vId", type: "bytes21" },
      { name: "deinitData", type: "bytes" },
      { name: "hookDeinitData", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
};

// `Hex` is re-exported so consumers that previously imported it via
// this module continue to compile during the transition. Remove
// once no callers depend on it here.
export type { Hex };
