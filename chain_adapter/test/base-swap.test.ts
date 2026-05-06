/**
 * Base 0x swap execution tests (#192) — ERC-4337 v0.7 UserOperation path.
 *
 * Mirrors the `base-transfer.test.ts` pattern: mocks `BaseClients`'s
 * chain RPC + bundler, but keeps the delegation signer real
 * (`privateKeyToAccount`) so the canonical v0.7 user-op hash is
 * computed end-to-end.
 *
 * Coverage:
 *   - happy path             → broadcast + confirmed callbacks, with
 *                              final_balance_changes carrying input
 *                              outflow + output inflow.
 *   - userop revert          → broadcast + reverted callbacks.
 *   - bundler rejection      → execution.aborted, reason
 *                              `bundler_rejected:`.
 *   - bundler hash mismatch  → execution.aborted, reason
 *                              `bundler_hash_mismatch:`.
 *   - confirmation timeout   → execution.aborted, reason
 *                              `confirmation_failed:`.
 *   - swap_route_incomplete  → no UserOp built; abort with the
 *                              missing-field name.
 *   - unsupported_provider   → no UserOp built; abort with the tag.
 *   - unsupported_input      → abort with `unsupported_input_asset`.
 *   - native_input           → abort with `native_input_not_implemented`.
 *   - stale_route            → abort with `stale_route` when deadline
 *                              has passed.
 *   - non_zero_value_with_erc20_input → abort.
 *   - approve+swap batch     → the inner UserOp callData decodes to
 *                              `executeBatch([token, router], [0, 0],
 *                              [approve(spender, inputAmount), 0xCALL])`.
 */

import { describe, it, expect, beforeEach } from "vitest";
import {
  decodeFunctionData,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { getUserOperationHash } from "viem/account-abstraction";
import { executeSwap } from "../src/chains/base/swap.js";
import {
  createTestCallbackClient,
  resetCallbackSeq,
} from "../src/callbacks/client.js";
import type { BaseClients } from "../src/chains/base/client.js";
import type { DispatchSwap } from "../src/contracts/schemas.js";
import { ExecutionError } from "../src/lib/errors.js";
import { ERC20_TRANSFER_ABI } from "../src/chains/base/usdc.js";
import { SIMPLE_ACCOUNT_EXECUTE_BATCH_ABI } from "../src/chains/base/entrypoint.js";

const SMART_ACCOUNT =
  "0x000000000000000000000000000000000000a11c" as const;
const ENTRY_POINT = "0x0000000071727de22e5e9d8baf0edac6f37da032" as const;
const TX_HASH =
  "0x2222222222222222222222222222222222222222222222222222222222222222" as const;
const SIGNER_KEY = ("0x" + "ab".repeat(32)) as `0x${string}`;
const ZEROX_ROUTER =
  "0x0000000000001fF3684f28c67538d4D072C22734" as `0x${string}`;
const USDC_SEPOLIA =
  "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as `0x${string}`;
const WETH_SEPOLIA =
  "0x4200000000000000000000000000000000000006" as `0x${string}`;
const SWAP_CALLDATA =
  "0x415565b0000000000000000000000000036cbd53842c5426634e7929541ec2318f3dcf7e0000000000000000000000004200000000000000000000000000000000000006" as Hex;

function honestBundlerSendUserOperation(args: {
  entryPointAddress: `0x${string}`;
  [k: string]: unknown;
}): Hex {
  const { account: _account, entryPointAddress, ...userOp } = args;
  return getUserOperationHash({
    chainId: 84532,
    entryPointAddress,
    entryPointVersion: "0.7",
    userOperation: { ...userOp, signature: "0x" as Hex } as never,
  });
}

function baseSwapDispatch(
  routeOverrides: Partial<DispatchSwap["route"]> = {},
  rest: Partial<DispatchSwap> = {},
): DispatchSwap {
  return {
    contract_version: 1,
    action: "swap",
    execution_plan_id: "11111111-1111-4111-8111-11111111aaaa",
    intent_id: "22222222-2222-4222-8222-22222222bbbb",
    smart_account_id: "sa_test",
    chain: "base-sepolia",
    input_asset: "USDC",
    output_asset: "WETH",
    input_amount: "100",
    expected_output: "0.028",
    slippage_bps: 50,
    route: {
      venue: "whitelisted_aggregator_v1",
      path: ["USDC", "WETH"],
      route_provider: "zerox",
      swap_target_contract: ZEROX_ROUTER,
      spender: ZEROX_ROUTER,
      calldata: SWAP_CALLDATA,
      source_token_address: USDC_SEPOLIA,
      destination_token_address: WETH_SEPOLIA,
      minimum_output_amount: "0.0278",
      value: "0",
      deadline: "2099-12-31T23:59:59Z",
      ...routeOverrides,
    },
    signing_requirements: {
      delegation_id: "del_primary",
      scope: { chain: "base-sepolia", asset: "USDC", max_amount: "500" },
    },
    correlation_id: "22222222-2222-4222-8222-22222222bbbb",
    emitted_at: "2026-04-15T20:00:00Z",
    ...rest,
  };
}

function successfulReceipt() {
  return {
    success: true,
    receipt: { transactionHash: TX_HASH, blockNumber: 12_345n },
  };
}

function revertedReceipt(reason = "INSUFFICIENT_OUTPUT_AMOUNT") {
  return {
    success: false,
    reason,
    receipt: { transactionHash: TX_HASH, blockNumber: 12_345n },
  };
}

interface MockOpts {
  readContract?: () => Promise<unknown>;
  estimateFees?: () => Promise<unknown>;
  estimateUserOpGas?: () => Promise<unknown>;
  sendUserOperation?: (args: {
    entryPointAddress: `0x${string}`;
    [k: string]: unknown;
  }) => Promise<unknown>;
  waitForUserOperationReceipt?: () => Promise<unknown>;
  /** Captures every call shipped to the bundler so tests can assert callData. */
  sentUserOps?: Array<{ entryPointAddress: `0x${string}`; [k: string]: unknown }>;
}

function mockClients(opts: MockOpts = {}): BaseClients {
  const readContract = opts.readContract ?? (async () => 42n);
  const estimateFees =
    opts.estimateFees ??
    (async () => ({
      maxFeePerGas: 1_000_000_000n,
      maxPriorityFeePerGas: 100_000_000n,
    }));
  const estimateUserOpGas =
    opts.estimateUserOpGas ??
    (async () => ({
      callGasLimit: 200_000n,
      verificationGasLimit: 200_000n,
      preVerificationGas: 60_000n,
    }));
  const sendUserOperation =
    opts.sendUserOperation ??
    (async (args) => {
      opts.sentUserOps?.push(args);
      return honestBundlerSendUserOperation(args);
    });
  const waitForUserOperationReceipt =
    opts.waitForUserOperationReceipt ?? (async () => successfulReceipt());

  const signer = privateKeyToAccount(SIGNER_KEY);

  return {
    publicClient: {
      chain: { id: 84532 },
      readContract,
      estimateFeesPerGas: estimateFees,
    },
    walletClient: {},
    bundlerClient: {
      estimateUserOperationGas: estimateUserOpGas,
      sendUserOperation,
      waitForUserOperationReceipt,
    },
    account: signer,
    smartAccountAddress: SMART_ACCOUNT,
    entryPointAddress: ENTRY_POINT,
  } as unknown as BaseClients;
}

describe("executeSwap — Base + 0x (AA v0.7, #192)", () => {
  beforeEach(() => resetCallbackSeq());

  it("emits broadcast then confirmed on a successful swap UserOp", async () => {
    const callbackClient = createTestCallbackClient();
    const sentUserOps: Array<{ entryPointAddress: `0x${string}`; [k: string]: unknown }> = [];
    const clients = mockClients({ sentUserOps });

    const result = await executeSwap(
      baseSwapDispatch(),
      clients,
      callbackClient,
    );

    if ("aborted" in result) throw new Error("expected execution result, got abort");
    expect(result.status).toBe("success");
    expect(result.userOpHash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(result.txHash).toBe(TX_HASH);

    expect(callbackClient.payloads).toHaveLength(2);
    expect(callbackClient.payloads[0]!.kind).toBe("execution.broadcast");
    expect(callbackClient.payloads[1]!.kind).toBe("execution.confirmed");

    const broadcast = callbackClient.payloads[0]!;
    if (broadcast.kind !== "execution.broadcast") throw new Error("unreachable");
    expect(broadcast.tx_refs[0]!.userop_hash).toBe(result.userOpHash);
    expect(broadcast.tx_refs[0]!.bundler).toBe("base-v07-bundler");
    expect(broadcast.tx_refs[0]!.nonce).toBe("0x2a");
    expect(broadcast.tx_refs[0]!.hash).toBeUndefined();

    const confirmed = callbackClient.payloads[1]!;
    if (confirmed.kind !== "execution.confirmed") throw new Error("unreachable");
    expect(confirmed.tx_refs[0]!.hash).toBe(TX_HASH);
    expect(confirmed.tx_refs[0]!.userop_hash).toBe(result.userOpHash);
    expect(confirmed.tx_refs[0]!.status).toBe("success");
    expect(confirmed.final_balance_changes.items).toEqual([
      { asset: "USDC", amount: "-100" },
      { asset: "WETH", amount: "0.028" },
    ]);

    // All three callbacks reference the same execution_plan_id —
    // Phoenix can dedupe on (execution_plan_id, callback_id) safely.
    for (const cb of callbackClient.payloads) {
      expect(cb.execution_plan_id).toBe("11111111-1111-4111-8111-11111111aaaa");
    }
    const ids = callbackClient.payloads.map((c) => c.callback_id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("emits the inner UserOp callData as executeBatch([token, router], [0, 0], [approve, 0x...])", async () => {
    const callbackClient = createTestCallbackClient();
    const sentUserOps: Array<{ entryPointAddress: `0x${string}`; [k: string]: unknown }> = [];
    const clients = mockClients({ sentUserOps });

    const result = await executeSwap(
      baseSwapDispatch(),
      clients,
      callbackClient,
    );
    if ("aborted" in result) throw new Error("expected execution result");

    expect(sentUserOps).toHaveLength(1);
    const callData = sentUserOps[0]!.callData as Hex;

    const decoded = decodeFunctionData({
      abi: SIMPLE_ACCOUNT_EXECUTE_BATCH_ABI,
      data: callData,
    });
    expect(decoded.functionName).toBe("executeBatch");

    const [targets, values, datas] = decoded.args as readonly [
      readonly `0x${string}`[],
      readonly bigint[],
      readonly Hex[],
    ];

    expect(targets.map((a) => a.toLowerCase())).toEqual([
      USDC_SEPOLIA.toLowerCase(),
      ZEROX_ROUTER.toLowerCase(),
    ]);
    expect(values).toEqual([0n, 0n]);
    expect(datas[1]).toBe(SWAP_CALLDATA);

    // Inner approve must encode `approve(spender, inputAmount)` —
    // bounded, NOT MaxUint256.
    const approveDecoded = decodeFunctionData({
      abi: ERC20_TRANSFER_ABI,
      data: datas[0]!,
    });
    expect(approveDecoded.functionName).toBe("approve");
    const [spender, amount] = approveDecoded.args as readonly [
      `0x${string}`,
      bigint,
    ];
    expect(spender.toLowerCase()).toBe(ZEROX_ROUTER.toLowerCase());
    // 100 USDC at 6 decimals = 100_000_000.
    expect(amount).toBe(100_000_000n);
    // Defense-in-depth: the bounded amount must NOT match MaxUint256.
    expect(amount).not.toBe((1n << 256n) - 1n);
  });

  it("emits broadcast then reverted when the bundler receipt reports a revert", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      waitForUserOperationReceipt: async () => revertedReceipt("Slippage"),
    });

    const result = await executeSwap(
      baseSwapDispatch(),
      clients,
      callbackClient,
    );
    if ("aborted" in result) throw new Error("expected reverted, got abort");
    expect(result.status).toBe("reverted");

    expect(callbackClient.payloads).toHaveLength(2);
    expect(callbackClient.payloads[1]!.kind).toBe("execution.reverted");

    const reverted = callbackClient.payloads[1]!;
    if (reverted.kind !== "execution.reverted") throw new Error("unreachable");
    expect(reverted.reason).toBe("Slippage");
    expect(reverted.tx_refs[0]!.hash).toBe(TX_HASH);
  });

  it("aborts when the bundler rejects the UserOp", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      sendUserOperation: async () => {
        throw new Error("bundler full");
      },
    });

    await expect(
      executeSwap(baseSwapDispatch(), clients, callbackClient),
    ).rejects.toBeInstanceOf(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(1);
    const aborted = callbackClient.payloads[0]!;
    if (aborted.kind !== "execution.aborted") throw new Error("unreachable");
    expect(aborted.reason.startsWith("bundler_rejected:")).toBe(true);
  });

  it("aborts when the bundler returns a mismatched user-op hash", async () => {
    const callbackClient = createTestCallbackClient();
    const wrongHash =
      "0x9999999999999999999999999999999999999999999999999999999999999999" as Hex;
    const clients = mockClients({
      sendUserOperation: async () => wrongHash,
    });

    await expect(
      executeSwap(baseSwapDispatch(), clients, callbackClient),
    ).rejects.toBeInstanceOf(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(1);
    const aborted = callbackClient.payloads[0]!;
    if (aborted.kind !== "execution.aborted") throw new Error("unreachable");
    expect(aborted.reason.startsWith("bundler_hash_mismatch:")).toBe(true);
  });

  it("aborts when waitForUserOperationReceipt times out", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      waitForUserOperationReceipt: async () => {
        throw new Error("timeout");
      },
    });

    await expect(
      executeSwap(baseSwapDispatch(), clients, callbackClient),
    ).rejects.toBeInstanceOf(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(2);
    // broadcast then aborted (the receipt wait happens AFTER broadcast).
    expect(callbackClient.payloads[0]!.kind).toBe("execution.broadcast");
    const aborted = callbackClient.payloads[1]!;
    if (aborted.kind !== "execution.aborted") throw new Error("unreachable");
    expect(aborted.reason.startsWith("confirmation_failed:")).toBe(true);
  });

  describe("envelope fail-closed gates", () => {
    it("aborts with swap_route_incomplete when calldata is missing", async () => {
      const callbackClient = createTestCallbackClient();
      const clients = mockClients();

      const result = await executeSwap(
        baseSwapDispatch({ calldata: undefined }),
        clients,
        callbackClient,
      );
      if (!("aborted" in result)) throw new Error("expected abort");
      expect(result.reason).toContain("swap_route_incomplete");
      expect(result.reason).toContain("calldata");

      // No UserOp built → no broadcast.
      expect(callbackClient.payloads).toHaveLength(1);
      expect(callbackClient.payloads[0]!.kind).toBe("execution.aborted");
    });

    it("aborts with swap_route_incomplete when route_provider is missing", async () => {
      const callbackClient = createTestCallbackClient();
      const clients = mockClients();

      const result = await executeSwap(
        baseSwapDispatch({ route_provider: undefined }),
        clients,
        callbackClient,
      );
      if (!("aborted" in result)) throw new Error("expected abort");
      expect(result.reason).toContain("route_provider");
    });

    it("aborts with unsupported_provider for non-MVP venues", async () => {
      const callbackClient = createTestCallbackClient();
      const clients = mockClients();

      const result = await executeSwap(
        baseSwapDispatch({ route_provider: "paraswap" }),
        clients,
        callbackClient,
      );
      if (!("aborted" in result)) throw new Error("expected abort");
      expect(result.reason).toBe("unsupported_provider: paraswap");
    });

    it("aborts with unsupported_input_asset when input is outside the MVP allowlist", async () => {
      const callbackClient = createTestCallbackClient();
      const clients = mockClients();

      const result = await executeSwap(
        baseSwapDispatch({}, { input_asset: "DAI" }),
        clients,
        callbackClient,
      );
      if (!("aborted" in result)) throw new Error("expected abort");
      expect(result.reason).toBe("unsupported_input_asset: DAI");
    });

    it("aborts with unsupported_output_asset when output is outside the MVP allowlist", async () => {
      const callbackClient = createTestCallbackClient();
      const clients = mockClients();

      const result = await executeSwap(
        baseSwapDispatch({}, { output_asset: "DAI" }),
        clients,
        callbackClient,
      );
      if (!("aborted" in result)) throw new Error("expected abort");
      expect(result.reason).toBe("unsupported_output_asset: DAI");
    });

    it("aborts with native_input_not_implemented when source is the 0x ETH sentinel", async () => {
      const callbackClient = createTestCallbackClient();
      const clients = mockClients();

      const result = await executeSwap(
        baseSwapDispatch({
          source_token_address:
            "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        }),
        clients,
        callbackClient,
      );
      if (!("aborted" in result)) throw new Error("expected abort");
      expect(result.reason).toBe("native_input_not_implemented");
    });

    it("aborts with stale_route when the route's deadline has passed", async () => {
      const callbackClient = createTestCallbackClient();
      const clients = mockClients();

      const result = await executeSwap(
        baseSwapDispatch({ deadline: "2020-01-01T00:00:00Z" }),
        clients,
        callbackClient,
      );
      if (!("aborted" in result)) throw new Error("expected abort");
      expect(result.reason).toBe("stale_route");
    });

    it("aborts with non_zero_value_with_erc20_input when value is non-zero on an ERC20-input swap", async () => {
      const callbackClient = createTestCallbackClient();
      const clients = mockClients();

      const result = await executeSwap(
        baseSwapDispatch({ value: "0.001" }),
        clients,
        callbackClient,
      );
      if (!("aborted" in result)) throw new Error("expected abort");
      expect(result.reason).toBe("non_zero_value_with_erc20_input");
    });
  });
});
