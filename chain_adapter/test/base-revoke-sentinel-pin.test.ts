/**
 * Sentinel revoke-calldata pin (issue #31 tripwire).
 *
 * The v0.1 revoke path is a SENTINEL: the inner call wrapped in the
 * `SimpleAccount.execute(target, value, data)` envelope is exactly
 * `(self, 0, 0x)` — a no-op self-call. This is a real on-chain anchor
 * but NOT a cryptographic revocation of the delegation key (see
 * `src/chains/base/revoke.ts` and `src/chains/base/userop.ts`).
 *
 * Phoenix issue #31 stays open until that changes. To prevent silent
 * drift — someone wiring up calldata that LOOKS like a real revoke
 * without flipping the contract docs and closing #31 — this test
 * pins the sentinel calldata byte-for-byte.
 *
 * If you arrive here because this test failed: that is intentional.
 * Either you are implementing a real permission-module revoke (in
 * which case update `priv/adapter/contract.md`,
 * `docs/incident-runbook.md`, this file, and the README before
 * closing #31), or you have changed the sentinel by accident — fix
 * the inner call back to `(self, 0, 0x)`.
 */

import { describe, it, expect } from "vitest";
import { encodeFunctionData, type Hex } from "viem";
import {
  buildSentinelRevokeCallData,
  buildExecuteCallData,
} from "../src/chains/base/userop.js";
import { SIMPLE_ACCOUNT_EXECUTE_ABI } from "../src/chains/base/entrypoint.js";

const SMART_ACCOUNT =
  "0x000000000000000000000000000000000000a11c" as const;

describe("sentinel revoke calldata (issue #31 pin)", () => {
  it("wraps a no-op self-call: execute(self, 0, 0x)", () => {
    const sentinel = buildSentinelRevokeCallData(SMART_ACCOUNT);

    const expected = encodeFunctionData({
      abi: SIMPLE_ACCOUNT_EXECUTE_ABI,
      functionName: "execute",
      args: [SMART_ACCOUNT, 0n, "0x" as Hex],
    });

    expect(sentinel).toBe(expected);
  });

  it("matches the generic execute builder for the same args (no hidden behavior)", () => {
    const viaHelper = buildSentinelRevokeCallData(SMART_ACCOUNT);
    const viaGeneric = buildExecuteCallData(
      SMART_ACCOUNT,
      0n,
      "0x" as Hex,
    );

    expect(viaHelper).toBe(viaGeneric);
  });

  it("encodes a different smart account independently (target IS self)", () => {
    const otherAccount =
      "0x000000000000000000000000000000000000beef" as const;

    const a = buildSentinelRevokeCallData(SMART_ACCOUNT);
    const b = buildSentinelRevokeCallData(otherAccount);

    expect(a).not.toBe(b);
  });
});
