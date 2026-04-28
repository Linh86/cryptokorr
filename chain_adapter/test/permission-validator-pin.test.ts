/**
 * Pin tripwire for the ZeroDev kernel permission system (issue #83).
 *
 * `KERNEL_PERMISSION_PIN` is `null` today. The earlier model that
 * pinned a single Permission Validator address + `disableFunction`
 * was wrong — `@zerodev/permissions` has no such contract. See
 * `docs/zerodev-permissions-integration.md` and the file-level
 * comment in `src/chains/base/permission_validator.ts` for the
 * corrected ZeroDev model.
 *
 * If you arrive here because the `toBeNull()` assertion failed:
 * that is intentional. You landed a real pin — good. Before the
 * PR merges, make sure you ALSO land:
 *
 *   1. The runtime `@zerodev/sdk` + `@zerodev/permissions` deps
 *      and a matching version range pinned in
 *      `KernelPermissionPin.zeroDevPermissionsPackageVersion`.
 *   2. A startup check that asserts the `acceptedSignerContracts`
 *      and `acceptedPolicyContracts` match the addresses the
 *      runtime SDK actually uses (kernel `permissionConfig` lookup
 *      against the bound RPC).
 *   3. The live revoke swap in `src/chains/base/revoke.ts`: replace
 *      `buildSentinelRevokeCallData(...)` with a UserOp whose
 *      callData is `Kernel.uninstallValidation(vId, deinitData,
 *      hookDeinitData)` against the smart account itself, signed
 *      by a sudo signer for that account. Flip
 *      `test/base-revoke-sentinel-pin.test.ts` to pin the new
 *      outer calldata at the same time.
 *   4. The doc flip: `docs/smart-account-and-revoke-design.md`,
 *      `docs/incident-runbook.md`,
 *      `docs/zerodev-permissions-integration.md`, and
 *      `chain_adapter/README.md` stop describing the revoke as a
 *      sentinel, and #31 can close.
 */

import { describe, it, expect } from "vitest";
import {
  KERNEL_PERMISSION_PIN,
  type KernelPermissionPin,
} from "../src/chains/base/permission_validator.js";

describe("KERNEL_PERMISSION_PIN (#83 tripwire)", () => {
  it("is null until #83 lands a verified ZeroDev pin", () => {
    // When this flips, see the file-level comment for the four
    // follow-ups that must land in the same PR.
    expect(KERNEL_PERMISSION_PIN).toBeNull();
  });

  it("declares the KernelPermissionPin contract the future pin must match", () => {
    // Compile-time contract check: if this literal stops type-checking,
    // the `KernelPermissionPin` shape in `permission_validator.ts`
    // drifted from what the eventual pin review expects. Fix the
    // type, not this test. The values below are intentionally
    // throwaway shape-only — never the actual pin.
    const _contract: KernelPermissionPin = {
      acceptedSignerContracts: ["0x0000000000000000000000000000000000000000"],
      acceptedPolicyContracts: ["0x0000000000000000000000000000000000000000"],
      zeroDevPermissionsPackageVersion: ">=0.0.0",
      artifactSource: {
        kind: "vendor_audited_package",
        url: "https://example.invalid",
        note: "placeholder fixture — never committed as the actual pin",
      },
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
    expect(_contract.zeroDevPermissionsPackageVersion).toBe(">=0.0.0");
  });
});
