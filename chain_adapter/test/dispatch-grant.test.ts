/**
 * Grant-delegation dispatch handler tests (#58 grant flow).
 *
 * Mirrors `dispatch-revoke.test.ts` for the grant path. Coverage:
 *
 *   - schema validation rejects malformed payloads
 *   - operator-key-missing branch fails closed with the right
 *     callback shape (`grant_failed`, reason=operator_key_missing)
 *   - chain_id mismatch branch fails closed
 *   - duplicate-in-flight idempotency
 *
 * The successful broadcast path is NOT exercised here — it requires
 * a real bundler RPC + a real operator key + a real kernel account
 * already provisioned. See operator runbook in
 * `docs/zerodev-permissions-integration.md` for that path.
 */

import { describe, it, expect, beforeEach } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { buildApp, type AppDeps } from "../src/app.js";
import { testConfig } from "../src/config/index.js";
import {
  type CallbackClient,
  type CallbackPayload,
  createTestCallbackClient,
  resetCallbackSeq,
} from "../src/callbacks/client.js";
import { resetGrantState } from "../src/dispatch/grant.js";
import type { BaseClients } from "../src/chains/base/client.js";
import { dispatchGrantDelegation } from "./fixtures/index.js";
import { dispatchAuthHeaders } from "./dispatch-auth-headers.js";
import type { FastifyInstance } from "fastify";

const SMART_ACCOUNT = "0x000000000000000000000000000000000000a11c" as const;
const ENTRY_POINT = "0x0000000071727de22e5e9d8baf0edac6f37da032" as const;
const SIGNER_KEY = ("0x" + "ef".repeat(32)) as `0x${string}`;

type TestCallbackClient = CallbackClient & {
  payloads: CallbackPayload[];
  clear?: () => void;
};

function mockClients(): BaseClients {
  return {
    publicClient: {
      chain: { id: 84_532 },
    },
    walletClient: {},
    bundlerClient: {},
    account: privateKeyToAccount(SIGNER_KEY),
    smartAccountAddress: SMART_ACCOUNT,
    entryPointAddress: ENTRY_POINT,
  } as unknown as BaseClients;
}

async function eventually(assertion: () => void): Promise<void> {
  const deadline = Date.now() + 1_000;
  let lastError: unknown;

  while (Date.now() < deadline) {
    try {
      assertion();
      return;
    } catch (err) {
      lastError = err;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }

  throw lastError;
}

function createBlockingCallbackClient(): TestCallbackClient & {
  release(): void;
} {
  const base = createTestCallbackClient();
  let release: (() => void) | undefined;
  const blocked = new Promise<void>((resolve) => {
    release = resolve;
  });

  return {
    payloads: base.payloads,
    clear: base.clear,
    release() {
      release?.();
    },
    async send(payload: CallbackPayload): Promise<void> {
      await base.send(payload);
      await blocked;
    },
  };
}

describe("POST /dispatch/grant_delegation", () => {
  let app: FastifyInstance;
  let callbackClient: TestCallbackClient;

  beforeEach(async () => {
    resetCallbackSeq();
    resetGrantState();
    callbackClient = createTestCallbackClient();
  });

  async function buildWithConfig(
    overrides: Parameters<typeof testConfig>[0] = {},
  ): Promise<FastifyInstance> {
    const deps: AppDeps = {
      config: testConfig({ baseChainId: 84_532, ...overrides }),
      callbackClient,
      baseClients: mockClients(),
    };
    const instance = buildApp(deps);
    await instance.ready();
    return instance;
  }

  describe("validation", () => {
    it("rejects malformed payload", async () => {
      app = await buildWithConfig();
      const response = await app.inject({
        method: "POST",
        url: "/dispatch/grant_delegation",
        headers: dispatchAuthHeaders,
        payload: { bad: "data" },
      });

      expect(response.statusCode).toBe(400);
      expect(response.json().error.code).toBe("validation_error");
      expect(callbackClient.payloads).toHaveLength(0);
    });

    it("rejects missing chain_id", async () => {
      app = await buildWithConfig();
      const { chain_id: _drop, ...payload } =
        dispatchGrantDelegation as typeof dispatchGrantDelegation & {
          chain_id: number;
        };

      const response = await app.inject({
        method: "POST",
        url: "/dispatch/grant_delegation",
        headers: dispatchAuthHeaders,
        payload,
      });

      expect(response.statusCode).toBe(400);
      expect(callbackClient.payloads).toHaveLength(0);
    });

    it("rejects empty smart_account_id", async () => {
      app = await buildWithConfig();
      const response = await app.inject({
        method: "POST",
        url: "/dispatch/grant_delegation",
        headers: dispatchAuthHeaders,
        payload: { ...dispatchGrantDelegation, smart_account_id: "" },
      });

      expect(response.statusCode).toBe(400);
    });
  });

  describe("fail-closed branches", () => {
    it("emits grant_failed with operator_key_missing when operator key is unset", async () => {
      // Fresh `testConfig` populates the operator key by default;
      // clearing both fields exercises the
      // operator-key-missing branch. This must NOT be reported as
      // `granted`, because Phoenix would create an active
      // delegation row for a permission that was never installed.
      app = await buildWithConfig({
        operatorPrivateKey: undefined,
        operatorAddress: undefined,
      });

      const response = await app.inject({
        method: "POST",
        url: "/dispatch/grant_delegation",
        headers: dispatchAuthHeaders,
        payload: dispatchGrantDelegation,
      });

      expect(response.statusCode).toBe(202);
      expect(response.json().status).toBe("installing");

      await eventually(() => {
        expect(callbackClient.payloads).toHaveLength(1);
      });

      const cb = callbackClient.payloads[0]!;
      if (cb.kind !== "delegation.state_changed")
        throw new Error("unreachable");
      expect(cb.state).toBe("grant_failed");
      expect(cb.reason).toBe("operator_key_missing");
      expect(cb.permission).toBeUndefined();
    });

    it("emits grant_failed with chain_id_mismatch when adapter is configured for a different chain", async () => {
      // The dispatch's chain_id is 84532; configure adapter for
      // 8453 (Base mainnet) and verify the cross-check trips.
      app = await buildWithConfig({ baseChainId: 8453 });

      const response = await app.inject({
        method: "POST",
        url: "/dispatch/grant_delegation",
        headers: dispatchAuthHeaders,
        payload: dispatchGrantDelegation,
      });

      expect(response.statusCode).toBe(202);
      await eventually(() => {
        expect(callbackClient.payloads).toHaveLength(1);
      });

      const cb = callbackClient.payloads[0]!;
      if (cb.kind !== "delegation.state_changed")
        throw new Error("unreachable");
      expect(cb.state).toBe("grant_failed");
      expect(cb.reason).toBe("chain_id_mismatch");
      expect(cb.permission).toBeUndefined();
    });
  });

  describe("idempotency", () => {
    it("suppresses a duplicate on-chain install while one is in flight", async () => {
      // Hold the first background grant in its callback send so
      // the in-flight set is still populated when the second
      // dispatch arrives.
      const blockingClient = createBlockingCallbackClient();
      callbackClient = blockingClient;
      app = await buildWithConfig({
        operatorPrivateKey: undefined,
        operatorAddress: undefined,
      });

      const first = await app.inject({
        method: "POST",
        url: "/dispatch/grant_delegation",
        headers: dispatchAuthHeaders,
        payload: dispatchGrantDelegation,
      });
      const second = await app.inject({
        method: "POST",
        url: "/dispatch/grant_delegation",
        headers: dispatchAuthHeaders,
        payload: dispatchGrantDelegation,
      });

      expect(first.statusCode).toBe(202);
      expect(second.statusCode).toBe(202);

      await eventually(() => {
        expect(callbackClient.payloads).toHaveLength(1);
      });

      blockingClient.release();
    });
  });

  describe("auth", () => {
    it("requires the dispatch bearer", async () => {
      app = await buildWithConfig();
      const response = await app.inject({
        method: "POST",
        url: "/dispatch/grant_delegation",
        headers: { authorization: "Bearer wrong" },
        payload: dispatchGrantDelegation,
      });

      expect(response.statusCode).toBe(401);
    });
  });
});
