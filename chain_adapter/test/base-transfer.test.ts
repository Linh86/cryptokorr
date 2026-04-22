/**
 * Base + USDC transfer execution tests (ERC-4337 v0.7 UserOperation path).
 *
 * Exercises the full transfer lifecycle against a mocked `BaseClients`
 * whose `bundlerClient` stands in for the configured bundler. The
 * delegation signer is a real `privateKeyToAccount` so the signing
 * behavior is end-to-end real; only the bundler RPC and chain RPC are
 * swapped for in-memory doubles.
 *
 * Failure branches asserted:
 *   - userop build failure  -> execution.aborted (reason: userop_build_failed)
 *   - bundler rejection     -> execution.aborted (reason: bundler_rejected)
 *   - confirmation timeout  -> execution.aborted (reason: confirmation_failed)
 *   - userop revert         -> execution.reverted
 *
 * The callback tx_refs shape on the AA path is validated here: broadcast
 * emits `userop_hash` + hex `nonce` + `bundler` label; the terminal
 * callback additionally emits the on-chain `hash` from the bundler
 * receipt.
 */

import { describe, it, expect, beforeEach } from "vitest";
import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { getUserOperationHash } from "viem/account-abstraction";
import { executeTransfer } from "../src/chains/base/transfer.js";
import {
  createTestCallbackClient,
  resetCallbackSeq,
} from "../src/callbacks/client.js";
import type { BaseClients } from "../src/chains/base/client.js";
import type { DispatchTransfer } from "../src/contracts/schemas.js";
import { ExecutionError } from "../src/lib/errors.js";

const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as const;
const SMART_ACCOUNT =
  "0x000000000000000000000000000000000000a11c" as const;
const ENTRY_POINT = "0x0000000071727de22e5e9d8baf0edac6f37da032" as const;
const TX_HASH =
  "0x1111111111111111111111111111111111111111111111111111111111111111" as const;
const SIGNER_KEY = ("0x" + "ab".repeat(32)) as `0x${string}`;

/**
 * Stand-in for a well-behaved bundler: recomputes the canonical
 * EIP-4337 v0.7 user-op hash from the operation it was handed, the
 * same way the adapter does locally. Returns that hash, so the
 * mismatch check inside the adapter passes.
 */
function honestBundlerSendUserOperation(args: {
  entryPointAddress: `0x${string}`;
  [k: string]: unknown;
}): Hex {
  const { account: _account, entryPointAddress, ...userOp } = args;
  return getUserOperationHash({
    chainId: 8453,
    entryPointAddress,
    entryPointVersion: "0.7",
    // Hash is computed over the unsigned operation; the bundler
    // verifies the signature separately. Strip whatever signature
    // the adapter sent in.
    userOperation: { ...userOp, signature: "0x" as Hex } as never,
  });
}

function baseDispatch(): DispatchTransfer {
  return {
    contract_version: 1,
    action: "transfer",
    execution_plan_id: "11111111-1111-4111-8111-111111111111",
    intent_id: "22222222-2222-4222-8222-222222222222",
    smart_account_id: "sa_test",
    chain: "base",
    asset: "USDC",
    amount: "50",
    target: {
      address: "0x000000000000000000000000000000000000dEaD",
      counterparty_id: "33333333-3333-4333-8333-333333333333",
    },
    signing_requirements: {
      delegation_id: "del_primary",
      scope: { chain: "base", asset: "USDC", max_amount: "500" },
    },
    correlation_id: "22222222-2222-4222-8222-222222222222",
    emitted_at: "2026-04-15T20:00:00Z",
  };
}

function successfulReceipt() {
  return {
    success: true,
    receipt: {
      transactionHash: TX_HASH,
      blockNumber: 12_345n,
    },
  };
}

function revertedReceipt() {
  return {
    success: false,
    reason: "ERC20: transfer amount exceeds balance",
    receipt: {
      transactionHash: TX_HASH,
      blockNumber: 12_345n,
    },
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
}

function mockClients(opts: MockOpts = {}): BaseClients {
  const readContract =
    opts.readContract ?? (async () => 42n); // nonce
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
    (async (args) => honestBundlerSendUserOperation(args));
  const waitForUserOperationReceipt =
    opts.waitForUserOperationReceipt ?? (async () => successfulReceipt());

  const signer = privateKeyToAccount(SIGNER_KEY);

  return {
    publicClient: {
      chain: { id: 8453 },
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

describe("executeTransfer — Base + USDC (AA v0.7)", () => {
  beforeEach(() => resetCallbackSeq());

  it("emits execution.broadcast then execution.confirmed on a successful user-op", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients();

    const result = await executeTransfer(
      baseDispatch(),
      clients,
      callbackClient,
      USDC_ADDRESS,
    );

    expect(result.status).toBe("success");
    // Local hash is the source of truth post-fix; an honest bundler
    // returns the same value, so we just check shape + downstream
    // consistency rather than pinning a magic constant.
    expect(result.userOpHash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(result.txHash).toBe(TX_HASH);

    expect(callbackClient.payloads).toHaveLength(2);
    expect(callbackClient.payloads[0]!.kind).toBe("execution.broadcast");
    expect(callbackClient.payloads[1]!.kind).toBe("execution.confirmed");

    const broadcast = callbackClient.payloads[0]!;
    if (broadcast.kind !== "execution.broadcast") throw new Error("unreachable");
    expect(broadcast.tx_refs[0]!.userop_hash).toBe(result.userOpHash);
    expect(broadcast.tx_refs[0]!.bundler).toBe("base-v07-bundler");
    expect(broadcast.tx_refs[0]!.nonce).toBe("0x2a"); // 42 in hex
    // AA-only on broadcast — no on-chain hash yet.
    expect(broadcast.tx_refs[0]!.hash).toBeUndefined();

    const confirmed = callbackClient.payloads[1]!;
    if (confirmed.kind !== "execution.confirmed") throw new Error("unreachable");
    expect(confirmed.execution_plan_id).toBe(
      "11111111-1111-4111-8111-111111111111",
    );
    expect(confirmed.tx_refs[0]!.userop_hash).toBe(result.userOpHash);
    expect(confirmed.tx_refs[0]!.hash).toBe(TX_HASH);
    expect(confirmed.tx_refs[0]!.status).toBe("success");
    expect(confirmed.tx_refs[0]!.block_number).toBe(12_345);
    expect(confirmed.final_balance_changes.items[0]).toEqual({
      asset: "USDC",
      amount: "-50",
    });
  });

  it("emits execution.broadcast then execution.reverted when receipt reports success=false", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      waitForUserOperationReceipt: async () => revertedReceipt(),
    });

    const result = await executeTransfer(
      baseDispatch(),
      clients,
      callbackClient,
      USDC_ADDRESS,
    );

    expect(result.status).toBe("reverted");
    expect(callbackClient.payloads).toHaveLength(2);
    expect(callbackClient.payloads[0]!.kind).toBe("execution.broadcast");

    const reverted = callbackClient.payloads[1]!;
    if (reverted.kind !== "execution.reverted") throw new Error("unreachable");
    expect(reverted.reason).toBe("ERC20: transfer amount exceeds balance");
    expect(reverted.tx_refs[0]!.userop_hash).toBe(result.userOpHash);
    expect(reverted.tx_refs[0]!.hash).toBe(TX_HASH);
    expect(reverted.tx_refs[0]!.status).toBe("reverted");
  });

  it("emits execution.aborted and throws when the bundler rejects the user-op", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      sendUserOperation: async () => {
        throw new Error("invalid signature");
      },
    });

    await expect(
      executeTransfer(baseDispatch(), clients, callbackClient, USDC_ADDRESS),
    ).rejects.toThrow(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(1);
    const aborted = callbackClient.payloads[0]!;
    if (aborted.kind !== "execution.aborted") throw new Error("unreachable");
    expect(aborted.reason).toMatch(/bundler_rejected/);
    expect(aborted.execution_plan_id).toBe(
      "11111111-1111-4111-8111-111111111111",
    );
  });

  it("emits execution.aborted when user-op build fails (e.g. gas estimation rejects)", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      estimateUserOpGas: async () => {
        throw new Error("AA23 reverted: insufficient balance");
      },
    });

    await expect(
      executeTransfer(baseDispatch(), clients, callbackClient, USDC_ADDRESS),
    ).rejects.toThrow(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(1);
    const aborted = callbackClient.payloads[0]!;
    if (aborted.kind !== "execution.aborted") throw new Error("unreachable");
    expect(aborted.reason).toMatch(/userop_build_failed/);
  });

  it("emits execution.broadcast then execution.aborted when confirmation times out", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      waitForUserOperationReceipt: async () => {
        throw new Error("timeout waiting for user-op receipt");
      },
    });

    await expect(
      executeTransfer(baseDispatch(), clients, callbackClient, USDC_ADDRESS),
    ).rejects.toThrow(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(2);
    expect(callbackClient.payloads[0]!.kind).toBe("execution.broadcast");

    const aborted = callbackClient.payloads[1]!;
    if (aborted.kind !== "execution.aborted") throw new Error("unreachable");
    expect(aborted.reason).toMatch(/confirmation_failed/);
  });

  it("emits execution.aborted with bundler_hash_mismatch when bundler returns a divergent user-op hash", async () => {
    // Simulates a buggy/malicious bundler returning a hash that does not
    // match what the adapter computed locally. Per EIP-4337 the two
    // hashes MUST be byte-equal; a divergence means the bundler is
    // hashing a different operation, is on a different chain, or a
    // proxy has rewritten the request. The adapter MUST refuse to emit
    // the broadcast callback in that case — Phoenix would otherwise
    // anchor the wrong identity for the operation.
    const WRONG_HASH =
      "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" as const;
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      sendUserOperation: async () => WRONG_HASH,
    });

    await expect(
      executeTransfer(baseDispatch(), clients, callbackClient, USDC_ADDRESS),
    ).rejects.toThrow(ExecutionError);

    // Critical: only ONE callback emitted — the abort. No broadcast, no
    // confirmed. Phoenix must never see a userop_hash that the adapter
    // could not vouch for.
    expect(callbackClient.payloads).toHaveLength(1);
    const aborted = callbackClient.payloads[0]!;
    if (aborted.kind !== "execution.aborted") throw new Error("unreachable");
    expect(aborted.reason).toMatch(/bundler_hash_mismatch/);
    expect(aborted.reason).toContain(WRONG_HASH);
    expect(aborted.execution_plan_id).toBe(
      "11111111-1111-4111-8111-111111111111",
    );
  });
});
