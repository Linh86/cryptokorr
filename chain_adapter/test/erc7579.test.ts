/**
 * ERC-7579 outer-wrap tripwire tests (issue #57, narrowed scope).
 *
 * Pins the parts of the Kernel-shaped revoke path that ARE verifiable
 * today from the EIP-7579 spec, independent of which Permission
 * Validator deployment #58 ultimately picks:
 *
 *   - the `execute(bytes32 mode, bytes executionCalldata)` ABI shape,
 *   - its function selector `0xe9ae5c53`,
 *   - the all-zeros single-call ModeCode constant,
 *   - the packed body layout `target ‖ value ‖ callData`,
 *   - the structural distinction from SimpleAccount's
 *     `execute(address,uint256,bytes)` (selector `0xb61d27f6`) so we
 *     cannot accidentally regress to wrapping a Kernel call with the
 *     v0.1 SimpleAccount envelope.
 *
 * If a test fails: either you are landing #58 against a different
 * outer wrap (which would mean Kernel/ERC-7579 itself broke
 * compatibility — extremely unlikely), or you have changed the
 * canonical ERC-7579 envelope by accident and should restore it.
 */

import { describe, it, expect } from "vitest";
import {
  encodeFunctionData,
  encodePacked,
  toFunctionSelector,
  type Address,
  type Hex,
} from "viem";
import {
  ERC_7579_EXECUTE_ABI,
  ERC_7579_EXECUTE_FUNCTION,
  ERC_7579_SINGLE_CALL_MODE,
  buildErc7579ExecuteCallData,
  encodeErc7579SingleCall,
} from "../src/chains/base/erc7579.js";
import { SIMPLE_ACCOUNT_EXECUTE_ABI } from "../src/chains/base/entrypoint.js";

const SAMPLE_TARGET: Address =
  "0x000000000000000000000000000000000000a11d" as const;
const SAMPLE_INNER: Hex = "0xdeadbeef" as const;

describe("ERC-7579 execute ABI (issue #57 pin, narrowed)", () => {
  it("exposes exactly execute(bytes32, bytes)", () => {
    expect(ERC_7579_EXECUTE_ABI).toHaveLength(1);
    const fragment = ERC_7579_EXECUTE_ABI[0]!;
    expect(fragment.type).toBe("function");
    if (fragment.type !== "function") return;
    expect(fragment.name).toBe(ERC_7579_EXECUTE_FUNCTION);
    expect(fragment.name).toBe("execute");
    expect(fragment.stateMutability).toBe("payable");
    expect(fragment.inputs).toEqual([
      { name: "mode", type: "bytes32" },
      { name: "executionCalldata", type: "bytes" },
    ]);
    expect(fragment.outputs).toEqual([]);
  });

  it("function selector is keccak256('execute(bytes32,bytes)')[:4]", () => {
    const selector = toFunctionSelector("execute(bytes32,bytes)");
    expect(selector).toBe("0xe9ae5c53");
  });

  it("is structurally distinct from SimpleAccount.execute", () => {
    // The whole point of pinning a separate ABI is so that #58 cannot
    // accidentally wrap a Kernel call with the v0.1 SimpleAccount
    // envelope. The selectors differ by spec; this assertion records
    // that fact and fails loudly if either constant is mutated.
    const erc7579Selector = toFunctionSelector("execute(bytes32,bytes)");
    const simpleAccountSelector = toFunctionSelector(
      "execute(address,uint256,bytes)",
    );
    expect(erc7579Selector).not.toBe(simpleAccountSelector);
    expect(simpleAccountSelector).toBe("0xb61d27f6");
  });
});

describe("ERC-7579 single-call mode constant", () => {
  it("is the 32-byte zero word (callType=0x00, execType=0x00, all else 0)", () => {
    expect(ERC_7579_SINGLE_CALL_MODE).toBe(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    expect(ERC_7579_SINGLE_CALL_MODE.length).toBe(2 + 64);
  });
});

describe("ERC-7579 single-call body encoder", () => {
  it("matches viem's canonical encodePacked for (address, uint256, bytes)", () => {
    const body = encodeErc7579SingleCall(SAMPLE_TARGET, 0n, SAMPLE_INNER);
    const expected = encodePacked(
      ["address", "uint256", "bytes"],
      [SAMPLE_TARGET, 0n, SAMPLE_INNER],
    );
    expect(body).toBe(expected);
  });

  it("produces a body whose minimum length is 20 + 32 bytes (target + value)", () => {
    const empty = encodeErc7579SingleCall(SAMPLE_TARGET, 0n, "0x" as Hex);
    // 0x prefix + (20 + 32) * 2 hex chars = 2 + 104 = 106
    expect(empty.length).toBe(2 + (20 + 32) * 2);
  });

  it("preserves the target address bytes at the head of the body", () => {
    const body = encodeErc7579SingleCall(SAMPLE_TARGET, 0n, SAMPLE_INNER);
    // body is 0x || target (20 bytes = 40 hex) || value (32 bytes = 64 hex) || data
    const targetBytes = body.slice(2, 2 + 40).toLowerCase();
    expect(targetBytes).toBe(SAMPLE_TARGET.slice(2).toLowerCase());
  });
});

describe("ERC-7579 outer wrap (full execute calldata)", () => {
  it("buildErc7579ExecuteCallData matches viem's canonical encoding", () => {
    const wrapped = buildErc7579ExecuteCallData(SAMPLE_TARGET, 0n, SAMPLE_INNER);
    const innerBody = encodeErc7579SingleCall(SAMPLE_TARGET, 0n, SAMPLE_INNER);
    const expected = encodeFunctionData({
      abi: ERC_7579_EXECUTE_ABI,
      functionName: "execute",
      args: [ERC_7579_SINGLE_CALL_MODE, innerBody],
    });
    expect(wrapped).toBe(expected);
  });

  it("encoded calldata starts with the execute(bytes32,bytes) selector", () => {
    const wrapped = buildErc7579ExecuteCallData(SAMPLE_TARGET, 0n, SAMPLE_INNER);
    expect(wrapped.slice(0, 10)).toBe("0xe9ae5c53");
  });

  it("differs from the SimpleAccount-wrapped equivalent", () => {
    // Sanity: if an account exposes both shapes, dispatch picks by
    // selector. The SimpleAccount wrap and the ERC-7579 wrap MUST be
    // distinct byte strings or #58 could ship calldata that lands on
    // the wrong code path on a dual-shape account.
    const erc7579Wrapped = buildErc7579ExecuteCallData(
      SAMPLE_TARGET,
      0n,
      SAMPLE_INNER,
    );
    const simpleAccountWrapped = encodeFunctionData({
      abi: SIMPLE_ACCOUNT_EXECUTE_ABI,
      functionName: "execute",
      args: [SAMPLE_TARGET, 0n, SAMPLE_INNER],
    });
    expect(erc7579Wrapped).not.toBe(simpleAccountWrapped);
    expect(erc7579Wrapped.slice(0, 10)).not.toBe(
      simpleAccountWrapped.slice(0, 10),
    );
  });
});
