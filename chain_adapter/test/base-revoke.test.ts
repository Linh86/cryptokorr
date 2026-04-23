/**
 * Base delegation revoke execution tests (ERC-4337 v0.7 sentinel path).
 *
 * `executeRevoke` now routes through the same AA path as transfers —
 * inner call is `SimpleAccount.execute(self, 0, 0x)` — so callbacks
 * carry `userop_hash` + on-chain `hash`. Mocks stand in for the
 * bundler and chain RPC; the delegation signer is real so the
 * signing behavior is exercised end-to-end.
 */

import { describe, it, expect, beforeEach } from "vitest";
import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { getUserOperationHash } from "viem/account-abstraction";
import { executeRevoke } from "../src/chains/base/revoke.js";
import {
  createTestCallbackClient,
  resetCallbackSeq,
} from "../src/callbacks/client.js";
import type { BaseClients } from "../src/chains/base/client.js";
import { ExecutionError } from "../src/lib/errors.js";

const SMART_ACCOUNT =
  "0x000000000000000000000000000000000000a11c" as const;
const ENTRY_POINT = "0x0000000071727de22e5e9d8baf0edac6f37da032" as const;
const TX_HASH =
  "0xbbbb222222222222222222222222222222222222222222222222222222222222" as const;
const SIGNER_KEY = ("0x" + "cd".repeat(32)) as `0x${string}`;

/**
 * Mirrors a conformant bundler: rederives the canonical EIP-4337 v0.7
 * user-op hash from the operation handed to it, with the signature
 * stripped (the hash is computed over the unsigned op; the bundler
 * verifies the signature separately). This is what the adapter expects
 * back on the happy path — `userOpHashesEqual` should match.
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
    userOperation: { ...userOp, signature: "0x" as Hex } as never,
  });
}

function successfulReceipt() {
  return {
    success: true,
    receipt: {
      transactionHash: TX_HASH,
      blockNumber: 100n,
    },
  };
}

function revertedReceipt(reason: string | undefined = undefined) {
  return {
    success: false,
    reason,
    receipt: {
      transactionHash: TX_HASH,
      blockNumber: 101n,
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
  const readContract = opts.readContract ?? (async () => 7n);
  const estimateFees =
    opts.estimateFees ??
    (async () => ({
      maxFeePerGas: 1_000_000_000n,
      maxPriorityFeePerGas: 100_000_000n,
    }));
  const estimateUserOpGas =
    opts.estimateUserOpGas ??
    (async () => ({
      callGasLimit: 100_000n,
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

describe("executeRevoke — Base sentinel (AA v0.7)", () => {
  beforeEach(() => resetCallbackSeq());

  it("submits a sentinel UserOp and emits revoked on confirmed receipt", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients();

    const result = await executeRevoke(
      "sa_test",
      "del_primary",
      "operator_requested",
      clients,
      callbackClient,
    );

    expect(result.status).toBe("success");
    // Local hash is the source of truth post-fix; an honest bundler
    // returns the same value, so we just check shape + downstream
    // consistency rather than pinning a magic constant.
    expect(result.userOpHash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(result.txHash).toBe(TX_HASH);

    expect(callbackClient.payloads).toHaveLength(1);
    const cb = callbackClient.payloads[0]!;
    if (cb.kind !== "delegation.state_changed") throw new Error("unreachable");
    expect(cb.state).toBe("revoked");
    expect(cb.reason).toBe("operator_requested");
    // delegation_id is echoed straight from the caller into the
    // projection-level callback; the sentinel body does not consume
    // it yet (see TODO(#58) in `src/chains/base/revoke.ts`).
    expect(cb.delegation_id).toBe("del_primary");
    expect(cb.tx_refs![0]!.userop_hash).toBe(result.userOpHash);
    expect(cb.tx_refs![0]!.hash).toBe(TX_HASH);
    expect(cb.tx_refs![0]!.block_number).toBe(100);
    expect(cb.tx_refs![0]!.status).toBe("success");
    expect(cb.tx_refs![0]!.bundler).toBe("base-v07-bundler");
    expect(cb.tx_refs![0]!.nonce).toBe("0x7");
  });

  it("threads a Kernel-shaped bytes32 permissionId hex into the callback", async () => {
    // The dispatch schema accepts any non-empty delegation_id; the
    // sentinel path must not choke on the post-Kernel 66-char hex
    // form either. Once #58 wires the real disable body this same
    // value will also feed `permissionIdFromDelegationId`.
    const permissionHex = ("0x" + "ab".repeat(32)) as `0x${string}`;
    const callbackClient = createTestCallbackClient();
    const clients = mockClients();

    await executeRevoke(
      "sa_test",
      permissionHex,
      "operator_requested",
      clients,
      callbackClient,
    );

    const cb = callbackClient.payloads[0]!;
    if (cb.kind !== "delegation.state_changed") throw new Error("unreachable");
    expect(cb.delegation_id).toBe(permissionHex);
    expect(cb.state).toBe("revoked");
  });

  it("emits revoke_failed with bundler_rejected when the bundler rejects the user-op", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      sendUserOperation: async () => {
        throw new Error("AA33 reverted: paymaster deposit too low");
      },
    });

    await expect(
      executeRevoke(
        "sa_test",
        "del_primary",
        "operator_requested",
        clients,
        callbackClient,
      ),
    ).rejects.toThrow(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(1);
    const cb = callbackClient.payloads[0]!;
    if (cb.kind !== "delegation.state_changed") throw new Error("unreachable");
    expect(cb.state).toBe("revoke_failed");
    expect(cb.reason).toMatch(/bundler_rejected/);
    expect(cb.tx_refs).toBeUndefined();
  });

  it("emits revoke_failed with userop_build_failed when gas estimation fails", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      estimateUserOpGas: async () => {
        throw new Error("AA23 simulation failed");
      },
    });

    await expect(
      executeRevoke(
        "sa_test",
        "del_primary",
        "operator_requested",
        clients,
        callbackClient,
      ),
    ).rejects.toThrow(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(1);
    const cb = callbackClient.payloads[0]!;
    if (cb.kind !== "delegation.state_changed") throw new Error("unreachable");
    expect(cb.state).toBe("revoke_failed");
    expect(cb.reason).toMatch(/userop_build_failed/);
  });

  it("emits revoke_failed with confirmation_failed and AA tx_refs on receipt wait failure", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      waitForUserOperationReceipt: async () => {
        throw new Error("timeout");
      },
    });

    await expect(
      executeRevoke(
        "sa_test",
        "del_primary",
        "operator_requested",
        clients,
        callbackClient,
      ),
    ).rejects.toThrow(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(1);
    const cb = callbackClient.payloads[0]!;
    if (cb.kind !== "delegation.state_changed") throw new Error("unreachable");
    expect(cb.state).toBe("revoke_failed");
    expect(cb.reason).toMatch(/confirmation_failed/);
    expect(cb.tx_refs![0]!.userop_hash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(cb.tx_refs![0]!.status).toBe("unknown");
    expect(cb.tx_refs![0]!.hash).toBeUndefined();
  });

  it("emits revoke_failed with sentinel_reverted and throws ExecutionError on revert receipt", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      waitForUserOperationReceipt: async () => revertedReceipt(),
    });

    await expect(
      executeRevoke(
        "sa_test",
        "del_primary",
        "operator_requested",
        clients,
        callbackClient,
      ),
    ).rejects.toThrow(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(1);
    const cb = callbackClient.payloads[0]!;
    if (cb.kind !== "delegation.state_changed") throw new Error("unreachable");
    expect(cb.state).toBe("revoke_failed");
    expect(cb.reason).toBe("sentinel_reverted");
    expect(cb.tx_refs![0]!.status).toBe("reverted");
    expect(cb.tx_refs![0]!.block_number).toBe(101);
    expect(cb.tx_refs![0]!.userop_hash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(cb.tx_refs![0]!.hash).toBe(TX_HASH);
  });

  it("propagates the bundler's revert reason when provided", async () => {
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      waitForUserOperationReceipt: async () =>
        revertedReceipt("permission_module_refused"),
    });

    await expect(
      executeRevoke(
        "sa_test",
        "del_primary",
        "operator_requested",
        clients,
        callbackClient,
      ),
    ).rejects.toThrow(ExecutionError);

    const cb = callbackClient.payloads[0]!;
    if (cb.kind !== "delegation.state_changed") throw new Error("unreachable");
    expect(cb.reason).toBe("permission_module_refused");
  });

  it("emits revoke_failed with bundler_hash_mismatch when bundler returns a divergent user-op hash", async () => {
    // Same invariant as the transfer path: a bundler that returns a
    // user-op hash different from what the adapter computed locally
    // must trigger a fail-closed revoke_failed callback BEFORE Phoenix
    // ever sees the bogus hash. The revoke path has no broadcast
    // callback, so the only callback emitted should be the terminal
    // revoke_failed.
    const WRONG_HASH =
      "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" as const;
    const callbackClient = createTestCallbackClient();
    const clients = mockClients({
      sendUserOperation: async () => WRONG_HASH,
    });

    await expect(
      executeRevoke(
        "sa_test",
        "del_primary",
        "operator_requested",
        clients,
        callbackClient,
      ),
    ).rejects.toThrow(ExecutionError);

    expect(callbackClient.payloads).toHaveLength(1);
    const cb = callbackClient.payloads[0]!;
    if (cb.kind !== "delegation.state_changed") throw new Error("unreachable");
    expect(cb.state).toBe("revoke_failed");
    expect(cb.reason).toMatch(/bundler_hash_mismatch/);
    expect(cb.reason).toContain(WRONG_HASH);
    // No tx_refs on a pre-confirmation abort — no on-chain anchor exists.
    expect(cb.tx_refs).toBeUndefined();
  });
});
