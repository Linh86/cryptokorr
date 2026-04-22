/**
 * Adapter ↔ Phoenix mapping helpers for the future cryptographic
 * delegation revoke (#58).
 *
 * Scope of #57 — narrowed to what is verifiable today:
 *
 *   - the **mapping convention** between Phoenix's opaque
 *     `delegation_id` string and the on-chain authority record. The
 *     convention is our design choice (it does not depend on any
 *     specific validator deployment), so it can be pinned now.
 *   - the **strict env accessor** `requirePermissionValidatorAddress`
 *     in `src/config/index.ts`, so #58 cannot silently degrade to a
 *     sentinel revoke if the operator forgets to set the env var on a
 *     Kernel-provisioned deployment.
 *   - the **outer ERC-7579 execute wrap** in `src/chains/base/erc7579.ts`,
 *     pinned against EIP-7579's normative
 *     `execute(bytes32 mode, bytes executionCalldata)` shape (selector
 *     `0xe9ae5c53`).
 *
 * What this module deliberately does NOT pin:
 *
 *   - The Permission Validator's own disable ABI fragment, function
 *     name, or selector. The chosen architecture (Kernel v3 / ERC-7579
 *     — see `docs/smart-account-and-revoke-design.md` in the Phoenix
 *     repo, GitHub #56) standardises the OUTER `execute` envelope but
 *     not the INNER per-permission-disable interface; that depends on
 *     the specific validator deployment a Kernel-provisioned operator
 *     installs. Pinning a name like `disablePermission(bytes32)` here
 *     before that deployment has been verified would be speculation,
 *     and a wrong selector would surface as a silent on-chain revert
 *     at the first real revoke against a Kernel-provisioned account.
 *
 * #58 still has three sub-prereqs to land in order, each tracked
 * separately so the prerequisites do not silently bundle:
 *
 *   1. **Provision a Kernel v3 / ERC-7579 deployment on Base** and
 *      install a Permission Validator against it. Tracked in #84.
 *      Runbook: Phoenix `docs/provisioning-kernel-v3.md`. Templates:
 *      `scripts/provision-kernel.ts` + `scripts/verify-installed-validator.ts`.
 *   2. **Verify the Permission Validator deployment artifact and pin
 *      the disable ABI fragment + selector** against a real artifact
 *      (verified contract / canonical audited package / vendor-published
 *      deployment manifest with bytecode hash + ABI). Add a tripwire
 *      test pinning the fragment alongside this module. Tracked in
 *      #83. The handoff format from #84 to #83 is the JSON receipt
 *      emitted by `scripts/verify-installed-validator.ts` (see the
 *      "What #83 must populate" section below for the exact contract).
 *   3. Wire `executeRevoke` to call
 *      `buildErc7579ExecuteCallData(validatorAddress, 0n,
 *      <verified inner disable body>)` and update the sentinel-pin
 *      tripwire in `test/base-revoke-sentinel-pin.test.ts`. Tracked
 *      in #58 itself.
 *
 * Until those land, NOTHING in this module is called from the live
 * revoke path — `executeRevoke` still uses
 * `buildSentinelRevokeCallData` against the SimpleAccount envelope.
 *
 * ## What #83 must populate
 *
 * #83 is the issue that actually pins the validator interface. So the
 * eventual pin can land in this file without architecture work, the
 * data contract #83 needs to populate is fixed here in advance.
 *
 * The pin is a single TypeScript record bound to ONE specific verified
 * deployment, sourced from a concrete artifact. The shape:
 *
 *     interface VerifiedPermissionValidator {
 *       // ID of the chain the validator is deployed on. 8453 = Base
 *       // mainnet, 84532 = Base Sepolia. Pinned per chain because the
 *       // bytecode hash is per-deployment, not per-source.
 *       chainId: 8453 | 84532;
 *
 *       // The address bound to PERMISSION_VALIDATOR_ADDRESS. Must
 *       // match the env value at startup; tripwire compares the
 *       // configured address against this field.
 *       address: Address;
 *
 *       // keccak256 of `eth_getCode(address)` against this chain.
 *       // Captured by `scripts/verify-installed-validator.ts` in the
 *       // `permission_validator_bytecode_keccak256` receipt field.
 *       // Tripwire compares the live bytecode hash against this at
 *       // startup; ANY drift fails closed (intentional — bytecode drift
 *       // means the validator was redeployed and its ABI must be
 *       // re-verified).
 *       deployedBytecodeKeccak256: Hex;
 *
 *       // Provenance for the ABI pin below. EXACTLY one is required.
 *       // `kind` is the artifact category; `url` is where a reviewer
 *       // can re-verify the disable ABI from scratch.
 *       artifactSource: {
 *         kind:
 *           | "etherscan_verified_contract"
 *           | "basescan_verified_contract"
 *           | "vendor_audited_package"
 *           | "vendor_deployment_manifest";
 *         url: string;
 *         // Free-text description of WHAT was inspected at `url` —
 *         // e.g. "Basescan source for 0x… verified against compiler
 *         // 0.8.23+commit.f704f362, function permissionId at line 124".
 *         note: string;
 *       };
 *
 *       // The disable function fragment, lifted byte-for-byte from
 *       // the artifact above. NOT inferred, NOT renamed, NOT inlined
 *       // from a plausible reference. The function MUST take exactly
 *       // one `bytes32` argument (the permissionId) and return either
 *       // nothing or a single bool — anything else means the chosen
 *       // validator does not fit the per-permission disable shape and
 *       // #83 needs to escalate (probably re-pick a validator).
 *       disableFunction: AbiFunction;
 *     }
 *
 * Behavioural contract for the eventual #83 pin:
 *
 *   - On adapter startup, the runtime reads the configured
 *     `PERMISSION_VALIDATOR_ADDRESS`, calls `eth_getCode` against the
 *     configured Base RPC, computes keccak256, and compares it against
 *     `deployedBytecodeKeccak256`. Mismatch = fail-closed startup error
 *     ("validator at 0x… on chain N has bytecode hash 0xA, pin expects
 *     0xB; verification artifact at <url> may be stale"). This is the
 *     bytecode tripwire that #58 calls for.
 *   - The disable function ABI fragment is consumed by `executeRevoke`
 *     via `encodeFunctionData({ abi: [pin.disableFunction], … })` and
 *     wrapped with `buildErc7579ExecuteCallData(pin.address, 0n,
 *     innerBody)`. The OUTER wrap selector is the verified
 *     `0xe9ae5c53` from `./erc7579.ts`; the INNER selector falls out
 *     of the verified ABI fragment.
 *   - A tripwire test pins the disable function selector against the
 *     verified ABI fragment, mirroring the `0xe9ae5c53` pin in
 *     `test/erc7579.test.ts`. If a future change to the pin file
 *     mutates the function name/inputs, the selector test fails.
 *   - The pin file's location: this module exports nothing for #83
 *     yet. When #83 lands, the pin lives in a sibling file
 *     (e.g. `permission_validator_pin.ts`) so this file's mapping
 *     helpers stay deployment-agnostic and reviewers see the pin
 *     diff in isolation.
 *
 * What #83 MUST NOT do:
 *
 *   - Pin a function name like `disablePermission(bytes32)` from a
 *     plausible-sounding reference name without tying it to one of
 *     the four `artifactSource.kind` values above. The whole point of
 *     #83 is that the speculative version of this pin was already
 *     attempted and rejected during #57; re-introducing it without
 *     verifiable provenance reverts that work.
 *   - Pin against a chain the operator has not actually deployed on.
 *     The `chainId` field forces #83 to commit to either Base mainnet
 *     or Base Sepolia for the deployment under verification; the pin
 *     is per-chain, not per-source, because bytecode hash is per
 *     deployment.
 *
 * ## Mapping semantics
 *
 * Phoenix stores `delegation_id` as a plain string column
 * (`delegations.delegation_id` — see Phoenix `Bank.Delegations.Delegation`).
 * The mapping this module enforces, post-Kernel provisioning, is:
 *
 *   delegation_id  ==  lowercase hex form of the `bytes32 permissionId`,
 *                      including the `0x` prefix
 *
 * That is 66 ASCII characters total: `0x` + 64 lowercase hex digits.
 * The encoding is deterministic and the round trip is byte-exact:
 * `delegationIdFromPermissionId(permissionIdFromDelegationId(x)) === x.toLowerCase()`.
 *
 * The `del_…` style ids that the v0.1 SimpleAccount path emits are
 * intentionally NOT accepted by `permissionIdFromDelegationId`: they
 * pre-date Kernel provisioning and have no on-chain authority record
 * to disable. When #58 lands, the grant path will start minting
 * Kernel-shaped delegation ids; legacy ids continue to flow through
 * the sentinel path or are migrated explicitly.
 *
 * That this convention CAN be pinned independently of the validator
 * choice is the load-bearing observation: Phoenix's column is opaque,
 * and the lowercase-hex form is a property of `bytes32` that every
 * candidate ERC-7579 Permission Validator inherits regardless of
 * function name.
 */

import { isHex, type Hex } from "viem";

/** Length of a `bytes32` permission id in its 0x-prefixed hex form. */
export const PERMISSION_ID_HEX_LENGTH = 2 + 64;

/**
 * Parse a Phoenix-side `delegation_id` into a `bytes32 permissionId`.
 *
 * Accepts only the canonical form: `0x` + 64 lowercase or uppercase hex
 * digits. Returns the lowercased hex value as a `viem` `Hex`. Throws
 * `PermissionMappingError` on any other input — including the
 * `del_primary` SimpleAccount-era placeholder, which has no permission
 * record on chain and must not silently degrade to a sentinel revoke
 * after #58 lands.
 */
export function permissionIdFromDelegationId(delegationId: string): Hex {
  if (typeof delegationId !== "string" || delegationId.length === 0) {
    throw new PermissionMappingError(
      "delegation_id is empty or not a string",
      delegationId,
    );
  }
  if (delegationId.length !== PERMISSION_ID_HEX_LENGTH) {
    throw new PermissionMappingError(
      `delegation_id must be ${PERMISSION_ID_HEX_LENGTH} chars (0x + 64 hex), got ${delegationId.length}`,
      delegationId,
    );
  }
  if (!isHex(delegationId)) {
    throw new PermissionMappingError(
      "delegation_id is not a 0x-prefixed hex string",
      delegationId,
    );
  }
  return delegationId.toLowerCase() as Hex;
}

/**
 * Render a `bytes32 permissionId` as a Phoenix-shaped `delegation_id`.
 *
 * The output is the lowercase hex form of the permission id and is the
 * exact value `permissionIdFromDelegationId` will round-trip back. Used
 * at grant time when the adapter mints a delegation id from a permission
 * id returned by the validator.
 */
export function delegationIdFromPermissionId(permissionId: Hex): string {
  if (!isHex(permissionId)) {
    throw new PermissionMappingError(
      "permission_id is not a 0x-prefixed hex string",
      permissionId,
    );
  }
  if (permissionId.length !== PERMISSION_ID_HEX_LENGTH) {
    throw new PermissionMappingError(
      `permission_id must be ${PERMISSION_ID_HEX_LENGTH} chars (0x + 64 hex), got ${permissionId.length}`,
      permissionId,
    );
  }
  return permissionId.toLowerCase();
}

/**
 * Thrown by the mapping helpers when a `delegation_id` or `permissionId`
 * is not in the canonical 32-byte hex form. Carries the offending value
 * for diagnostics; callers should NOT include it directly in
 * operator-facing messages without truncation.
 */
export class PermissionMappingError extends Error {
  public readonly offendingValue: string;

  constructor(message: string, offendingValue: string) {
    super(message);
    this.name = "PermissionMappingError";
    this.offendingValue = offendingValue;
  }
}
