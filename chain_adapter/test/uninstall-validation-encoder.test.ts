/**
 * Pure-encoder tests for the cryptographic revoke calldata path (#58).
 *
 * The encoder + validation guards in
 * `src/chains/base/uninstall_validation.ts` are written so they
 * stand alone — no RPC, no SDK, no secrets — so that the eventual
 * cryptographic revoke broadcast has a unit-tested foundation. The
 * SDK's full `uninstallPlugin` orchestration runs on top of these
 * primitives in production but is not exercised here; broadcasting
 * needs a real bundler + a real grant blob, which is the honest
 * boundary we draw under #58 (see
 * `docs/zerodev-permissions-integration.md`).
 *
 * Each test pins a behaviour that, if it broke, would let the
 * cryptographic revoke build malformed calldata or accept stale
 * blobs:
 *
 *   - calldata selector matches the kernel v3.1 `uninstallValidation`
 *     fragment pinned in `KERNEL_PERMISSION_PIN`;
 *   - `validation_id` derivation byte-by-byte from `permission_id`;
 *   - validation_id consistency guard catches mismatched dispatch
 *     payloads;
 *   - package version pin guard catches blob/runtime drift.
 */

import { describe, it, expect } from "vitest";
import {
  encodeFunctionData,
  type Hex,
} from "viem";
import {
  encodeUninstallValidationCallData,
  deriveValidationId,
  assertValidationIdConsistent,
  assertPackageVersionPinned,
  assertSignerModuleAllowed,
  assertPolicyModulesAllowed,
  extractPolicyContractAddresses,
  CryptographicRevokeError,
  VALIDATOR_TYPE_PERMISSION_PREFIX,
} from "../src/chains/base/uninstall_validation.js";
import { KERNEL_PERMISSION_PIN } from "../src/chains/base/permission_validator.js";
import type { PermissionBlock } from "../src/contracts/schemas.js";

const PERMISSION_ID = "0xa1b2c3d4" as const;
const VALIDATION_ID =
  "0x02a1b2c3d400000000000000000000000000000000" as const;
const SAMPLE_DEINIT =
  "0x0123456789abcdef" as const;

function validBlock(overrides: Partial<PermissionBlock> = {}): PermissionBlock {
  return {
    blob: "eyJzZXJpYWxpemVkUGVybWlzc2lvbkFjY291bnQiOiJ0ZXN0In0=",
    permission_id: PERMISSION_ID,
    validation_id: VALIDATION_ID,
    kernel_version: "0.3.1",
    package_version: KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion,
    ...overrides,
  };
}

describe("encodeUninstallValidationCallData", () => {
  it("matches viem's encodeFunctionData using the pinned ABI fragment", () => {
    // The encoder is a thin wrapper around viem's
    // `encodeFunctionData` + the pinned ABI. We pin behaviour by
    // computing the expected calldata via the SAME path Phoenix
    // would compute it via (the pinned fragment) and asserting
    // byte equality. If the pinned fragment changes, the tripwire
    // test in `permission-validator-pin.test.ts` fires; here we
    // pin the encoder's relationship to that fragment.
    const expected = encodeFunctionData({
      abi: [KERNEL_PERMISSION_PIN.uninstallValidationFunction],
      functionName: "uninstallValidation",
      args: [VALIDATION_ID, SAMPLE_DEINIT, "0x"],
    });

    const actual = encodeUninstallValidationCallData({
      validationId: VALIDATION_ID,
      deinitData: SAMPLE_DEINIT,
    });

    expect(actual).toBe(expected);
  });

  it("starts with the canonical uninstallValidation selector", () => {
    // Selector for `uninstallValidation(bytes21,bytes,bytes)` is
    // `keccak256("uninstallValidation(bytes21,bytes,bytes)")[0:4]
    // = 0xe6f3d50a`. Pinning it explicitly here means a future
    // change to the ABI fragment that drifts the function signature
    // (e.g. someone changes `bytes21` to `bytes32`) breaks this
    // test even if the encoder still appears to round-trip.
    const calldata = encodeUninstallValidationCallData({
      validationId: VALIDATION_ID,
      deinitData: SAMPLE_DEINIT,
    });
    expect(calldata.slice(0, 10).toLowerCase()).toBe("0xe6f3d50a");
  });

  it("defaults hookDeinitData to 0x when omitted", () => {
    const withoutHook = encodeUninstallValidationCallData({
      validationId: VALIDATION_ID,
      deinitData: SAMPLE_DEINIT,
    });
    const withExplicitEmpty = encodeUninstallValidationCallData({
      validationId: VALIDATION_ID,
      deinitData: SAMPLE_DEINIT,
      hookDeinitData: "0x",
    });
    expect(withoutHook).toBe(withExplicitEmpty);
  });

  it("rejects validationId shorter than 21 bytes with validation_id_mismatch", () => {
    expect(() =>
      encodeUninstallValidationCallData({
        validationId: "0x02" as Hex,
        deinitData: SAMPLE_DEINIT,
      }),
    ).toThrow(CryptographicRevokeError);
  });

  it("rejects validationId longer than 21 bytes with validation_id_mismatch", () => {
    const tooLong = ("0x02" + "a1".repeat(25)) as Hex;
    expect(() =>
      encodeUninstallValidationCallData({
        validationId: tooLong,
        deinitData: SAMPLE_DEINIT,
      }),
    ).toThrow(CryptographicRevokeError);
  });
});

describe("deriveValidationId", () => {
  it("computes 0x02 ‖ rightPad(permissionId, 20)", () => {
    expect(deriveValidationId(PERMISSION_ID)).toBe(VALIDATION_ID);
  });

  it("uses the canonical PERMISSION validator-type prefix", () => {
    // Pin the prefix as a constant so the test fails if anyone
    // edits it to e.g. `0x01` (SECONDARY) by mistake. The kernel
    // dispatches by these bytes — getting them wrong silently
    // routes the UserOp to the wrong validator.
    expect(VALIDATOR_TYPE_PERMISSION_PREFIX).toBe("0x02");
    const v = deriveValidationId(PERMISSION_ID);
    expect(v.slice(0, 4)).toBe("0x02");
  });

  it("rejects malformed permission_id", () => {
    expect(() => deriveValidationId("0xa1b2" as Hex)).toThrow(
      CryptographicRevokeError,
    );
  });
});

describe("assertValidationIdConsistent", () => {
  it("accepts a block whose validation_id derives from its permission_id", () => {
    expect(() => assertValidationIdConsistent(validBlock())).not.toThrow();
  });

  it("is case-insensitive on hex characters", () => {
    expect(() =>
      assertValidationIdConsistent(
        validBlock({
          validation_id: VALIDATION_ID.toUpperCase().replace("0X", "0x") as Hex,
        }),
      ),
    ).not.toThrow();
  });

  it("rejects a block with a permissionId/validationId mismatch", () => {
    expect(() =>
      assertValidationIdConsistent(
        validBlock({
          // Wrong padding direction (left-pad instead of right-pad).
          // Catches the most plausible serializer bug. 0x + 1 byte
          // (0x02) + 16 zero bytes + 4 bytes permissionId at the
          // tail = exactly 21 bytes / 42 hex chars / 44 chars total.
          validation_id:
            "0x0200000000000000000000000000000000a1b2c3d4" as Hex,
        }),
      ),
    ).toThrow(CryptographicRevokeError);
  });
});

describe("assertPackageVersionPinned", () => {
  it("accepts a block whose package_version equals the pin", () => {
    expect(() => assertPackageVersionPinned(validBlock())).not.toThrow();
  });

  it("rejects a block whose package_version drifts from the pin", () => {
    // If the runtime upgrades `@zerodev/permissions` and the
    // tripwire test passes (so addresses still match), but a stale
    // grant blob from the older package is dispatched, the runtime
    // refuses rather than risks decoding-shape drift on the blob.
    expect(() =>
      assertPackageVersionPinned(
        validBlock({ package_version: "5.5.0" }),
      ),
    ).toThrow(CryptographicRevokeError);
  });
});

describe("assertSignerModuleAllowed", () => {
  // Allowlist-enforcement tests for the cryptographic revoke path
  // (Finding #3 of the post-PR-130 review). Until these landed, the
  // pin's `acceptedSignerContracts` was declarative-only — its
  // tripwire test verified the addresses against the package, but
  // no production code rejected a blob whose signer module was
  // outside the pin. This block + the policy block below close
  // that gap.

  it("accepts an address that is in KERNEL_PERMISSION_PIN.acceptedSignerContracts", () => {
    expect(() =>
      assertSignerModuleAllowed(KERNEL_PERMISSION_PIN.acceptedSignerContracts[0]),
    ).not.toThrow();
  });

  it("is case-insensitive on hex characters", () => {
    const upper =
      KERNEL_PERMISSION_PIN.acceptedSignerContracts[0]!.toUpperCase().replace(
        "0X",
        "0x",
      );
    expect(() => assertSignerModuleAllowed(upper)).not.toThrow();
  });

  it("rejects an address that is not in the pin with unaccepted_signer_module", () => {
    const arbitrary = ("0x" + "ab".repeat(20)) as Hex;
    expect(() => assertSignerModuleAllowed(arbitrary)).toThrow(
      CryptographicRevokeError,
    );
    try {
      assertSignerModuleAllowed(arbitrary);
    } catch (err) {
      expect(err).toBeInstanceOf(CryptographicRevokeError);
      expect((err as CryptographicRevokeError).code).toBe(
        "unaccepted_signer_module",
      );
    }
  });

  it("rejects undefined (missing signerContractAddress)", () => {
    // A deserialized plugin that exposes no signerContractAddress
    // is structurally invalid; refuse rather than fall through.
    expect(() => assertSignerModuleAllowed(undefined)).toThrow(
      CryptographicRevokeError,
    );
  });

  it("accepts an explicit allowlist override (for tests / future overrides)", () => {
    // The optional second arg lets callers narrow the allowlist
    // without re-importing the pin. Useful in tests that want to
    // exercise the rejection path against a curated subset.
    const onlyOne = [KERNEL_PERMISSION_PIN.acceptedSignerContracts[0]!];
    expect(() =>
      assertSignerModuleAllowed(onlyOne[0], onlyOne),
    ).not.toThrow();
  });
});

describe("assertPolicyModulesAllowed", () => {
  it("accepts a list of pinned policy addresses", () => {
    expect(() =>
      assertPolicyModulesAllowed(KERNEL_PERMISSION_PIN.acceptedPolicyContracts),
    ).not.toThrow();
  });

  it("is case-insensitive", () => {
    const lower = KERNEL_PERMISSION_PIN.acceptedPolicyContracts.map((a) =>
      a.toLowerCase(),
    );
    expect(() => assertPolicyModulesAllowed(lower)).not.toThrow();
  });

  it("rejects an empty list with unaccepted_policy_module", () => {
    // Empty policies = no on-chain restrictions. We refuse to
    // operate on a permission with zero policies rather than treat
    // it as "no restrictions" — that posture would let an
    // attacker who somehow produces an empty-policies blob slip
    // through the cryptographic revoke pipeline.
    expect(() => assertPolicyModulesAllowed([])).toThrow(
      CryptographicRevokeError,
    );
    try {
      assertPolicyModulesAllowed([]);
    } catch (err) {
      expect((err as CryptographicRevokeError).code).toBe(
        "unaccepted_policy_module",
      );
    }
  });

  it("rejects a list containing one unpinned address", () => {
    const sneaky = [
      KERNEL_PERMISSION_PIN.acceptedPolicyContracts[0]!,
      ("0x" + "cc".repeat(20)) as Hex,
    ];
    expect(() => assertPolicyModulesAllowed(sneaky)).toThrow(
      CryptographicRevokeError,
    );
  });

  it("rejects undefined entries (malformed plugin missing policyAddress)", () => {
    expect(() =>
      assertPolicyModulesAllowed([
        KERNEL_PERMISSION_PIN.acceptedPolicyContracts[0]!,
        undefined,
      ]),
    ).toThrow(CryptographicRevokeError);
  });
});

describe("extractPolicyContractAddresses", () => {
  it("reads policyParams.policyAddress from each policy", () => {
    const fakePlugin = {
      getPluginSerializationParams: () => ({
        policies: [
          {
            policyParams: {
              policyAddress: KERNEL_PERMISSION_PIN.acceptedPolicyContracts[0]!,
            },
          },
          {
            policyParams: {
              policyAddress: KERNEL_PERMISSION_PIN.acceptedPolicyContracts[1]!,
            },
          },
        ],
      }),
    };
    expect(extractPolicyContractAddresses(fakePlugin)).toEqual([
      KERNEL_PERMISSION_PIN.acceptedPolicyContracts[0],
      KERNEL_PERMISSION_PIN.acceptedPolicyContracts[1],
    ]);
  });

  it("returns undefined for a policy missing policyParams", () => {
    // The downstream `assertPolicyModulesAllowed` converts
    // undefined into a precise `unaccepted_policy_module` refusal.
    const fakePlugin = {
      getPluginSerializationParams: () => ({
        policies: [{}],
      }),
    };
    expect(extractPolicyContractAddresses(fakePlugin)).toEqual([undefined]);
  });

  it("returns an empty list when policies are absent", () => {
    const fakePlugin = {
      getPluginSerializationParams: () => ({}),
    };
    expect(extractPolicyContractAddresses(fakePlugin)).toEqual([]);
  });

  it("end-to-end: extract + assert allowed = pass; mixed = fail", () => {
    const allowedPlugin = {
      getPluginSerializationParams: () => ({
        policies: KERNEL_PERMISSION_PIN.acceptedPolicyContracts.map(
          (a) => ({ policyParams: { policyAddress: a } }),
        ),
      }),
    };
    const addrs = extractPolicyContractAddresses(allowedPlugin);
    expect(() => assertPolicyModulesAllowed(addrs)).not.toThrow();

    const mixedPlugin = {
      getPluginSerializationParams: () => ({
        policies: [
          {
            policyParams: {
              policyAddress: KERNEL_PERMISSION_PIN.acceptedPolicyContracts[0]!,
            },
          },
          { policyParams: { policyAddress: ("0x" + "ee".repeat(20)) } },
        ],
      }),
    };
    const mixedAddrs = extractPolicyContractAddresses(mixedPlugin);
    expect(() => assertPolicyModulesAllowed(mixedAddrs)).toThrow(
      CryptographicRevokeError,
    );
  });
});
