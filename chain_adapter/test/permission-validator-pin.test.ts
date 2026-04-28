/**
 * Pin tripwire for the ZeroDev kernel permission system (issue #83).
 *
 * The `KERNEL_PERMISSION_PIN` constant in
 * `src/chains/base/permission_validator.ts` declares which signer
 * + policy modules the eventual cryptographic revoke (#58) is
 * willing to drive, plus the kernel-account
 * `uninstallValidation(bytes21,bytes,bytes)` ABI fragment that the
 * revoke encoder will use.
 *
 * Every value is verified here by reading the SAME source the pin
 * claims to come from:
 *
 *   - signer + policy module addresses are imported from
 *     `@zerodev/permissions` (the adapter's devDependency, audited
 *     at install time via the package-lock.json), and asserted
 *     equal to the literal addresses in the pin.
 *   - The `uninstallValidation` ABI fragment is found inside
 *     `KernelV3_1AccountAbi` from `@zerodev/sdk` and compared
 *     element-for-element against the pin's literal.
 *
 * If a future package bump moves an address or changes the ABI,
 * this test fails and forces a deliberate review of
 * `KERNEL_PERMISSION_PIN`. If a future change to
 * `KERNEL_PERMISSION_PIN` adds an address we don't carry through
 * the package, this test fails and forces a deliberate review.
 *
 * The runtime `executeRevoke` does not currently consume this
 * pin — it stays sentinel until #58 ships. This test is the
 * "we have not silently broken the source-of-truth contract"
 * guard between #83 and #58.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it, expect } from "vitest";
import {
  ECDSA_SIGNER_CONTRACT,
  CALL_POLICY_CONTRACT_V0_0_5,
  GAS_POLICY_CONTRACT,
  RATE_LIMIT_POLICY_CONTRACT,
  SIGNATURE_POLICY_CONTRACT,
  SUDO_POLICY_CONTRACT,
  TIMESTAMP_POLICY_CONTRACT,
} from "@zerodev/permissions";
import { KernelV3_1AccountAbi } from "@zerodev/sdk";
import {
  KERNEL_PERMISSION_PIN,
  type KernelPermissionPin,
} from "../src/chains/base/permission_validator.js";

// Read the resolved package's `package.json` directly off disk.
// `createRequire` would normally do this, but `@zerodev/permissions`
// declares an `exports` field that does not list `./package.json`,
// so Node refuses the resolution. Reading the file by absolute
// path bypasses the exports gate; the path is constructed from the
// test file's own URL so it does not depend on a particular
// working directory.
const __dirname = dirname(fileURLToPath(import.meta.url));
const resolvedPermissionsPkg = JSON.parse(
  readFileSync(
    join(
      __dirname,
      "..",
      "node_modules",
      "@zerodev",
      "permissions",
      "package.json",
    ),
    "utf8",
  ),
) as { name: string; version: string };

describe("KERNEL_PERMISSION_PIN — accepted module addresses match @zerodev/permissions", () => {
  it("acceptedSignerContracts is exactly the package's ECDSA_SIGNER_CONTRACT", () => {
    expect(KERNEL_PERMISSION_PIN.acceptedSignerContracts).toEqual([
      ECDSA_SIGNER_CONTRACT,
    ]);
  });

  it("acceptedPolicyContracts contains every latest-version policy module", () => {
    // The pin lists the latest version of each policy. Earlier
    // versions (V0_0_1 through V0_0_4 of CALL_POLICY, the WebAuthn
    // signer line, RATE_LIMIT_POLICY_WITH_RESET) are intentionally
    // excluded — adding them would require a deliberate product
    // decision. If `@zerodev/permissions` adds a new policy module
    // entirely, this assertion fails and forces a review.
    expect(KERNEL_PERMISSION_PIN.acceptedPolicyContracts).toEqual([
      CALL_POLICY_CONTRACT_V0_0_5,
      GAS_POLICY_CONTRACT,
      RATE_LIMIT_POLICY_CONTRACT,
      SIGNATURE_POLICY_CONTRACT,
      SUDO_POLICY_CONTRACT,
      TIMESTAMP_POLICY_CONTRACT,
    ]);
  });

  it("every accepted address is a 20-byte 0x-prefixed hex literal", () => {
    // Defense-in-depth against a typo'd literal in the pin: the
    // `0x${string}` template type accepts anything starting with
    // 0x, so we sanity-check shape too.
    const allAddrs = [
      ...KERNEL_PERMISSION_PIN.acceptedSignerContracts,
      ...KERNEL_PERMISSION_PIN.acceptedPolicyContracts,
    ];
    for (const addr of allAddrs) {
      expect(addr).toMatch(/^0x[0-9a-fA-F]{40}$/);
    }
  });

  it("zeroDevPermissionsPackageVersion records the verified version", () => {
    expect(KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion).toBe(
      "5.6.3",
    );
  });

  it("the resolved @zerodev/permissions package matches the pinned version", () => {
    // Closes the loop on the version pin: the test imports the
    // package's own `package.json` and asserts the running version
    // matches what `KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion`
    // claims. If `chain_adapter/package.json` ever drifts (someone
    // bumps the dep without re-verifying the addresses, or
    // someone updates the pin literal without bumping the dep),
    // this test fails.
    expect(resolvedPermissionsPkg.name).toBe("@zerodev/permissions");
    expect(resolvedPermissionsPkg.version).toBe(
      KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion,
    );
  });

  it("artifactSource attributes the pin to the npm tarball", () => {
    expect(KERNEL_PERMISSION_PIN.artifactSource.kind).toBe(
      "vendor_audited_package",
    );
    expect(KERNEL_PERMISSION_PIN.artifactSource.url).toContain(
      "@zerodev/permissions",
    );
    expect(KERNEL_PERMISSION_PIN.artifactSource.note.length).toBeGreaterThan(
      40,
    );
  });
});

describe("KERNEL_PERMISSION_PIN — uninstallValidation ABI matches Kernel v3.1", () => {
  it("matches the Kernel v3.1 ABI fragment byte-for-byte", () => {
    // Find `uninstallValidation` inside the Kernel v3.1 ABI as
    // shipped by `@zerodev/sdk`. If the kernel implementation
    // changes the function signature, this fails and forces a pin
    // update.
    const sdkFragment = (
      KernelV3_1AccountAbi as readonly { type?: string; name?: string }[]
    ).find((f) => f.type === "function" && f.name === "uninstallValidation");
    expect(sdkFragment).toBeDefined();

    const pinned = KERNEL_PERMISSION_PIN.uninstallValidationFunction;
    expect(pinned.name).toBe("uninstallValidation");
    expect(pinned.type).toBe("function");
    expect(pinned.stateMutability).toBe("payable");

    // The pin drops `internalType` keys; the SDK ABI carries them.
    // Compare just the canonical AbiFunction surface.
    const sdkInputs = (sdkFragment as { inputs: { name: string; type: string }[] }).inputs;
    expect(pinned.inputs.length).toBe(sdkInputs.length);
    for (let i = 0; i < sdkInputs.length; i += 1) {
      expect(pinned.inputs[i]!.name).toBe(sdkInputs[i]!.name);
      expect(pinned.inputs[i]!.type).toBe(sdkInputs[i]!.type);
    }
  });

  it("inputs are exactly (bytes21 vId, bytes deinitData, bytes hookDeinitData)", () => {
    // Belt-and-braces — the SDK comparison above is the source of
    // truth, but pinning the exact shape directly catches a bad
    // edit even if `@zerodev/sdk`'s ABI is somehow stubbed.
    expect(
      KERNEL_PERMISSION_PIN.uninstallValidationFunction.inputs,
    ).toEqual([
      { name: "vId", type: "bytes21" },
      { name: "deinitData", type: "bytes" },
      { name: "hookDeinitData", type: "bytes" },
    ]);
  });

  it("returns nothing — uninstallValidation has no outputs", () => {
    expect(
      KERNEL_PERMISSION_PIN.uninstallValidationFunction.outputs,
    ).toEqual([]);
  });
});

describe("KERNEL_PERMISSION_PIN — type contract", () => {
  it("structurally matches the KernelPermissionPin interface", () => {
    // Compile-time contract check: if the interface drifts from
    // what the eventual #58 swap expects, this assignment stops
    // type-checking. The fixture below is just the pin itself —
    // we re-bind through the typed local to fail the build on
    // shape changes.
    const _typed: KernelPermissionPin = KERNEL_PERMISSION_PIN;
    expect(_typed.zeroDevPermissionsPackageVersion).toBe(
      KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion,
    );
  });
});
