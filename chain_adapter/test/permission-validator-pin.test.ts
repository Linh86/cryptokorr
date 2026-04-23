/**
 * Pin tripwire for the Permission Validator ABI artifact (issue #83).
 *
 * The eventual cryptographic revoke (#58) calls
 * `encodeFunctionData({ abi: [pin.disableFunction], args: [permissionId] })`
 * against `KERNEL_PERMISSION_VALIDATOR_PIN`. That pin is `null` today
 * — #83 is the issue that populates it from a verified deployment
 * artifact (one of etherscan / basescan / vendor audit / vendor
 * deployment manifest, see `VerifiedPermissionValidator` in
 * `src/chains/base/permission_validator.ts`).
 *
 * This test exists to block drift in the null-vs-populated state
 * transition. If you arrive here because the `toBeNull()` assertion
 * failed: that is intentional. You landed a pin — good. Before the
 * PR merges, make sure you ALSO land:
 *
 *   1. A byte-for-byte selector assertion against the pinned
 *      `disableFunction` (mirror of the `0xe9ae5c53` pin in
 *      `test/erc7579.test.ts`). Replaces the `toBeNull()` below.
 *   2. A startup bytecode check: `keccak256(eth_getCode(pin.address))`
 *      against the configured `BASE_RPC_URL` equals
 *      `pin.deployedBytecodeKeccak256`; mismatch is a loud
 *      fail-closed startup error. The assertion lives in the config
 *      load path or a sibling "startup verification" module.
 *   3. The live revoke swap in `src/chains/base/revoke.ts`: replace
 *      `buildSentinelRevokeCallData(...)` with the ERC-7579-wrapped
 *      disable body per the TODO(#58) block. And flip
 *      `test/base-revoke-sentinel-pin.test.ts` to pin the new outer
 *      calldata so the sentinel tripwire stays honest.
 *   4. The doc flip: `docs/smart-account-and-revoke-design.md`,
 *      `docs/incident-runbook.md`, and `chain_adapter/README.md`
 *      stop describing the revoke as a sentinel, and #31 can close.
 *
 * If you arrive here because one of the "structural shape" checks
 * below failed: the eventual `VerifiedPermissionValidator` MUST
 * populate every field with a verified value — no inferred names,
 * no placeholder urls, no `chainId` other than 8453 (Base) or
 * 84532 (Base Sepolia). The check runs on the interface, not on a
 * fake instance, so today it's only a compile-time contract.
 */

import { describe, it, expect } from "vitest";
import {
  KERNEL_PERMISSION_VALIDATOR_PIN,
  type VerifiedPermissionValidator,
} from "../src/chains/base/permission_validator.js";

describe("KERNEL_PERMISSION_VALIDATOR_PIN (#83 tripwire)", () => {
  it("is null until #83 lands a verified artifact", () => {
    // When this flips, see the file-level comment for the four
    // follow-ups that must land in the same PR.
    expect(KERNEL_PERMISSION_VALIDATOR_PIN).toBeNull();
  });

  it("declares the VerifiedPermissionValidator contract the pin must match", () => {
    // Compile-time contract check: if the interface below stops
    // type-checking, the `VerifiedPermissionValidator` shape in
    // `permission_validator.ts` drifted from what the eventual pin
    // review expects. Fix the type, not this test.
    const _contract: VerifiedPermissionValidator = {
      chainId: 84_532,
      address: "0x0000000000000000000000000000000000000000",
      deployedBytecodeKeccak256: "0x" + "00".repeat(32) as `0x${string}`,
      artifactSource: {
        kind: "basescan_verified_contract",
        url: "https://sepolia.basescan.org/address/0x0",
        note: "placeholder fixture — never committed as the actual pin",
      },
      disableFunction: {
        type: "function",
        name: "unused_in_this_test",
        inputs: [{ name: "permissionId", type: "bytes32" }],
        outputs: [],
        stateMutability: "nonpayable",
      },
    };
    expect(_contract.chainId).toBe(84_532);
  });
});
