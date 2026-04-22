/**
 * Revoke delegation dispatch handler tests (ERC-4337 v0.7 path).
 *
 * Exercises the full revoke lifecycle against mocked `BaseClients`:
 *
 *   - validation + rejection paths
 *   - revoking → revoked on a confirmed sentinel UserOp
 *   - revoking → revoke_failed on bundler rejection
 *   - revoking → revoke_failed (with AA tx_refs) on confirmation wait failure
 *   - revoking → revoke_failed on a reverted user-op receipt
 *   - idempotency under duplicate in-flight dispatches
 */

import { describe, it, expect, beforeEach } from "vitest";
import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { getUserOperationHash } from "viem/account-abstraction";
import { buildApp, type AppDeps } from "../src/app.js";
import { testConfig } from "../src/config/index.js";
import {
  createTestCallbackClient,
  resetCallbackSeq,
} from "../src/callbacks/client.js";
import { resetRevokeState } from "../src/dispatch/revoke.js";
import type { BaseClients } from "../src/chains/base/client.js";
import { dispatchRevokeDelegation } from "./fixtures/index.js";
import { dispatchAuthHeaders } from "./dispatch-auth-headers.js";
import type { FastifyInstance } from "fastify";

const SMART_ACCOUNT =
  "0x000000000000000000000000000000000000a11c" as const;
const ENTRY_POINT = "0x0000000071727de22e5e9d8baf0edac6f37da032" as const;
const TX_HASH =
  "0xaaaa111111111111111111111111111111111111111111111111111111111111" as const;
const SIGNER_KEY = ("0x" + "ef".repeat(32)) as `0x${string}`;

/**
 * Stand-in for a well-behaved bundler: recomputes the canonical EIP-4337
 * v0.7 user-op hash from the operation it received, exactly like the
 * adapter does locally. Required so the new
 * `bundler-hash-mismatch` guard does not trip on legitimate test runs.
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

interface MockOpts {
  sendUserOperation?: (args: {
    entryPointAddress: `0x${string}`;
    [k: string]: unknown;
  }) => Promise<unknown>;
  waitForUserOperationReceipt?: () => Promise<unknown>;
}

function mockClients(opts: MockOpts = {}): BaseClients {
  const sendUserOperation =
    opts.sendUserOperation ??
    (async (args) => honestBundlerSendUserOperation(args));
  const waitForUserOperationReceipt =
    opts.waitForUserOperationReceipt ??
    (async () => ({
      success: true,
      receipt: {
        transactionHash: TX_HASH,
        blockNumber: 42_000n,
      },
    }));

  return {
    publicClient: {
      chain: { id: 8453 },
      readContract: async () => 17n,
      estimateFeesPerGas: async () => ({
        maxFeePerGas: 1_000_000_000n,
        maxPriorityFeePerGas: 100_000_000n,
      }),
    },
    walletClient: {},
    bundlerClient: {
      estimateUserOperationGas: async () => ({
        callGasLimit: 100_000n,
        verificationGasLimit: 200_000n,
        preVerificationGas: 60_000n,
      }),
      sendUserOperation,
      waitForUserOperationReceipt,
    },
    account: privateKeyToAccount(SIGNER_KEY),
    smartAccountAddress: SMART_ACCOUNT,
    entryPointAddress: ENTRY_POINT,
  } as unknown as BaseClients;
}

describe("POST /dispatch/revoke_delegation", () => {
  let app: FastifyInstance;
  let callbackClient: ReturnType<typeof createTestCallbackClient>;

  beforeEach(async () => {
    resetCallbackSeq();
    resetRevokeState();
    callbackClient = createTestCallbackClient();
  });

  async function buildWithClients(
    clients: BaseClients = mockClients(),
  ): Promise<FastifyInstance> {
    const deps: AppDeps = {
      config: testConfig(),
      callbackClient,
      baseClients: clients,
    };
    const instance = buildApp(deps);
    await instance.ready();
    return instance;
  }

  describe("validation", () => {
    it("rejects malformed payload", async () => {
      app = await buildWithClients();
      const response = await app.inject({
        method: "POST",
        url: "/dispatch/revoke_delegation",
        headers: dispatchAuthHeaders,
        payload: { bad: "data" },
      });

      expect(response.statusCode).toBe(400);
      expect(response.json().error.code).toBe("validation_error");
      expect(callbackClient.payloads).toHaveLength(0);
    });

    it("rejects missing smart_account_id", async () => {
      app = await buildWithClients();
      const payload = { ...dispatchRevokeDelegation, smart_account_id: "" };
      const response = await app.inject({
        method: "POST",
        url: "/dispatch/revoke_delegation",
        headers: dispatchAuthHeaders,
        payload,
      });

      expect(response.statusCode).toBe(400);
      expect(callbackClient.payloads).toHaveLength(0);
    });

    it("rejects missing reason", async () => {
      app = await buildWithClients();
      const payload = { ...dispatchRevokeDelegation, reason: "" };
      const response = await app.inject({
        method: "POST",
        url: "/dispatch/revoke_delegation",
        headers: dispatchAuthHeaders,
        payload,
      });

      expect(response.statusCode).toBe(400);
    });
  });

  describe("on-chain success path", () => {
    it("emits revoking then revoked with AA tx_refs on confirmed sentinel user-op", async () => {
      app = await buildWithClients();

      const response = await app.inject({
        method: "POST",
        url: "/dispatch/revoke_delegation",
        headers: dispatchAuthHeaders,
        payload: dispatchRevokeDelegation,
      });

      expect(response.statusCode).toBe(202);
      const body = response.json();
      expect(body.accepted).toBe(true);
      expect(body.status).toBe("revoking");
      expect(body.smart_account_id).toBe(
        dispatchRevokeDelegation.smart_account_id,
      );

      expect(callbackClient.payloads).toHaveLength(2);

      const revoking = callbackClient.payloads[0]!;
      if (revoking.kind !== "delegation.state_changed")
        throw new Error("unreachable");
      expect(revoking.state).toBe("revoking");
      expect(revoking.reason).toBe("operator_requested");
      expect(revoking.delegation_id).toBe("del_primary");
      expect(revoking.tx_refs).toBeUndefined();

      const revoked = callbackClient.payloads[1]!;
      if (revoked.kind !== "delegation.state_changed")
        throw new Error("unreachable");
      expect(revoked.state).toBe("revoked");
      expect(revoked.reason).toBe("operator_requested");
      expect(revoked.tx_refs).toBeDefined();
      expect(revoked.tx_refs![0]!.chain).toBe("base");
      // Adapter computes the userop hash locally; the honest-bundler
      // mock returns the same value. Just shape-check rather than
      // pinning a magic constant.
      expect(revoked.tx_refs![0]!.userop_hash).toMatch(/^0x[0-9a-f]{64}$/);
      expect(revoked.tx_refs![0]!.hash).toBe(TX_HASH);
      expect(revoked.tx_refs![0]!.block_number).toBe(42_000);
      expect(revoked.tx_refs![0]!.status).toBe("success");
      expect(revoked.tx_refs![0]!.bundler).toBe("base-v07-bundler");
    });
  });

  describe("on-chain failure paths", () => {
    // Failure branches MUST emit state=revoke_failed, never revoked.
    // Conflating the two blinded Phoenix to whether the delegation
    // was actually disabled. See `src/chains/base/revoke.ts` for the
    // invariant and `priv/adapter/contract.md` for Phoenix semantics.
    it("emits revoke_failed with bundler_rejected when the bundler rejects the user-op", async () => {
      const clients = mockClients({
        sendUserOperation: async () => {
          throw new Error("AA33: paymaster deposit too low");
        },
      });
      app = await buildWithClients(clients);

      const response = await app.inject({
        method: "POST",
        url: "/dispatch/revoke_delegation",
        headers: dispatchAuthHeaders,
        payload: dispatchRevokeDelegation,
      });

      expect(response.statusCode).toBe(202);
      expect(callbackClient.payloads).toHaveLength(2);

      const terminal = callbackClient.payloads[1]!;
      if (terminal.kind !== "delegation.state_changed")
        throw new Error("unreachable");
      expect(terminal.state).toBe("revoke_failed");
      expect(terminal.reason).toMatch(/bundler_rejected/);
      expect(terminal.tx_refs).toBeUndefined();
    });

    it("emits revoke_failed with confirmation_failed when waitForUserOperationReceipt throws", async () => {
      const clients = mockClients({
        waitForUserOperationReceipt: async () => {
          throw new Error("timeout waiting for user-op receipt");
        },
      });
      app = await buildWithClients(clients);

      const response = await app.inject({
        method: "POST",
        url: "/dispatch/revoke_delegation",
        headers: dispatchAuthHeaders,
        payload: dispatchRevokeDelegation,
      });

      expect(response.statusCode).toBe(202);
      expect(callbackClient.payloads).toHaveLength(2);

      const terminal = callbackClient.payloads[1]!;
      if (terminal.kind !== "delegation.state_changed")
        throw new Error("unreachable");
      expect(terminal.state).toBe("revoke_failed");
      expect(terminal.reason).toMatch(/confirmation_failed/);
      expect(terminal.tx_refs).toBeDefined();
      expect(terminal.tx_refs![0]!.userop_hash).toMatch(/^0x[0-9a-f]{64}$/);
      expect(terminal.tx_refs![0]!.status).toBe("unknown");
    });

    it("emits revoke_failed with sentinel_reverted when the user-op receipt is reverted", async () => {
      const clients = mockClients({
        waitForUserOperationReceipt: async () => ({
          success: false,
          receipt: {
            transactionHash: TX_HASH,
            blockNumber: 42_001n,
          },
        }),
      });
      app = await buildWithClients(clients);

      const response = await app.inject({
        method: "POST",
        url: "/dispatch/revoke_delegation",
        headers: dispatchAuthHeaders,
        payload: dispatchRevokeDelegation,
      });

      expect(response.statusCode).toBe(202);
      expect(callbackClient.payloads).toHaveLength(2);

      const terminal = callbackClient.payloads[1]!;
      if (terminal.kind !== "delegation.state_changed")
        throw new Error("unreachable");
      expect(terminal.state).toBe("revoke_failed");
      expect(terminal.reason).toBe("sentinel_reverted");
      expect(terminal.tx_refs![0]!.status).toBe("reverted");
      expect(terminal.tx_refs![0]!.block_number).toBe(42_001);
    });
  });

  describe("idempotency", () => {
    it("suppresses a duplicate on-chain send while one is in flight", async () => {
      // Gate the first call's send so we can fire a second dispatch
      // while it is still pending. The send still has to return the
      // canonical user-op hash so the bundler-mismatch guard does not
      // trip; the gating happens BEFORE the call returns, not by
      // returning a wrong value.
      let release: () => void = () => {};
      const gate = new Promise<void>((resolve) => {
        release = resolve;
      });

      const clients = mockClients({
        sendUserOperation: async (args) => {
          await gate;
          return honestBundlerSendUserOperation(args);
        },
        waitForUserOperationReceipt: async () => ({
          success: true,
          receipt: {
            transactionHash: TX_HASH,
            blockNumber: 42_002n,
          },
        }),
      });

      app = await buildWithClients(clients);

      const first = app.inject({
        method: "POST",
        url: "/dispatch/revoke_delegation",
        headers: dispatchAuthHeaders,
        payload: dispatchRevokeDelegation,
      });

      // Give the first call a microtask tick to enter inFlight.
      await new Promise((r) => setImmediate(r));

      const second = await app.inject({
        method: "POST",
        url: "/dispatch/revoke_delegation",
        headers: dispatchAuthHeaders,
        payload: dispatchRevokeDelegation,
      });

      expect(second.statusCode).toBe(202);

      release();
      const firstResp = await first;
      expect(firstResp.statusCode).toBe(202);

      // Expected callbacks:
      //   1. revoking (first dispatch)
      //   2. revoking (second dispatch, re-emitted idempotently)
      //   3. revoked (first dispatch only — second skipped on-chain send)
      const kinds = callbackClient.payloads.map((p) =>
        p.kind === "delegation.state_changed" ? p.state : p.kind,
      );
      expect(kinds).toEqual(["revoking", "revoking", "revoked"]);
    });
  });
});
