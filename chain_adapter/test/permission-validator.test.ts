/**
 * Permission Validator scaffolding tests (issue #57, narrowed).
 *
 * Pins what is verifiable today, independently of any specific
 * Permission Validator deployment:
 *
 *   - the `delegation_id` ↔ `permissionId` mapping convention
 *     (lowercase 0x-prefixed hex form of `bytes32`, 66 chars total)
 *     and its rejection of malformed or pre-Kernel placeholder ids,
 *   - the strict env accessor `requirePermissionValidatorAddress`
 *     fail-closed posture for #58.
 *
 * Deliberately NOT pinned here:
 *
 *   - the validator's own disable function name + selector + ABI
 *     fragment. That depends on the specific deployment #58 picks;
 *     pinning it from a plausible reference name without a verified
 *     deployment would be speculation, and a wrong selector would
 *     surface as a silent on-chain revert at the first revoke. The
 *     ERC-7579 OUTER wrap that #58 will use IS pinned, in
 *     `test/erc7579.test.ts`.
 *
 * If you arrive here because a test failed: either you are landing
 * #58 (in which case update the ADR + the contract docs in lockstep),
 * or you have changed the canonical mapping shape by accident and
 * should restore it.
 */

import { describe, it, expect } from "vitest";
import { type Hex } from "viem";
import {
  PERMISSION_ID_HEX_LENGTH,
  PermissionMappingError,
  delegationIdFromPermissionId,
  permissionIdFromDelegationId,
} from "../src/chains/base/permission_validator.js";
import {
  requirePermissionValidatorAddress,
  testConfig,
} from "../src/config/index.js";
import { permissionIdMapping } from "./fixtures/index.js";

const SAMPLE_PERMISSION_ID =
  "0x0000000000000000000000000000000000000000000000000000000000000abc" as const;

const SAMPLE_VALIDATOR_ADDRESS =
  "0x000000000000000000000000000000000000a11d" as const;

describe("delegation_id ↔ permissionId mapping (issue #57 pin)", () => {
  it("PERMISSION_ID_HEX_LENGTH is 66 (0x + 64 hex)", () => {
    expect(PERMISSION_ID_HEX_LENGTH).toBe(66);
  });

  it("round-trips a canonical permissionId", () => {
    const id = permissionIdFromDelegationId(SAMPLE_PERMISSION_ID);
    expect(id).toBe(SAMPLE_PERMISSION_ID);
    expect(delegationIdFromPermissionId(id)).toBe(SAMPLE_PERMISSION_ID);
  });

  it("normalises to lowercase hex", () => {
    const upper = ("0x" + "ABCD".repeat(16)) as Hex;
    expect(permissionIdFromDelegationId(upper)).toBe(upper.toLowerCase());
    expect(delegationIdFromPermissionId(upper)).toBe(upper.toLowerCase());
  });

  it("rejects the v0.1 SimpleAccount placeholder shape", () => {
    expect(() => permissionIdFromDelegationId("del_primary")).toThrow(
      PermissionMappingError,
    );
  });

  it("rejects empty / non-string input", () => {
    expect(() => permissionIdFromDelegationId("")).toThrow(
      PermissionMappingError,
    );
    expect(() =>
      // Force a type-erased empty case that would slip past TS.
      permissionIdFromDelegationId(undefined as unknown as string),
    ).toThrow(PermissionMappingError);
  });

  it("rejects wrong length", () => {
    expect(() =>
      permissionIdFromDelegationId("0x1234"),
    ).toThrow(PermissionMappingError);
    expect(() =>
      permissionIdFromDelegationId(("0x" + "ab".repeat(33)) as string),
    ).toThrow(PermissionMappingError);
  });

  it("rejects non-hex content of correct length", () => {
    const looksRightButIsNot = ("0x" + "z".repeat(64));
    expect(() => permissionIdFromDelegationId(looksRightButIsNot)).toThrow(
      PermissionMappingError,
    );
  });

  it("matches the Phoenix mapping fixture exactly", () => {
    // The Phoenix fixture is the human-readable contract that the
    // adapter must implement. If it changes shape, this assertion
    // breaks and forces both sides to move in lockstep.
    const fixtureDelegationId: string = permissionIdMapping.delegation_id;
    const fixturePermissionId: Hex = permissionIdMapping.permission_id as Hex;

    expect(fixtureDelegationId).toBe(fixturePermissionId);
    expect(permissionIdFromDelegationId(fixtureDelegationId)).toBe(
      fixturePermissionId,
    );
    expect(delegationIdFromPermissionId(fixturePermissionId)).toBe(
      fixtureDelegationId,
    );
  });
});

describe("requirePermissionValidatorAddress (fail-closed for #58)", () => {
  it("returns the address when configured", () => {
    const cfg = testConfig({
      permissionValidatorAddress: SAMPLE_VALIDATOR_ADDRESS,
    });
    expect(requirePermissionValidatorAddress(cfg)).toBe(
      SAMPLE_VALIDATOR_ADDRESS,
    );
  });

  it("throws a #58-referencing error when unset", () => {
    const cfg = testConfig({ permissionValidatorAddress: undefined });
    expect(() => requirePermissionValidatorAddress(cfg)).toThrow(
      /PERMISSION_VALIDATOR_ADDRESS/,
    );
    expect(() => requirePermissionValidatorAddress(cfg)).toThrow(/#58/);
  });

  it("default testConfig leaves the validator unset (sentinel-era posture)", () => {
    const cfg = testConfig();
    expect(cfg.permissionValidatorAddress).toBeUndefined();
  });
});
