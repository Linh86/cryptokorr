/**
 * Swap dispatch handler tests (#192).
 *
 * Two layers of coverage:
 *
 *   1. **Wire-shape gates** — these tests run with `baseClients: null`
 *      (test-mode dependency injection). They verify the handler
 *      validates the dispatch envelope, refuses unsupported chains,
 *      rejects malformed payloads, and aborts cleanly when the
 *      adapter is not bound to a chain client.
 *
 *   2. **End-to-end execution** — exercised in
 *      `test/base-swap.test.ts`, which mounts the executor against a
 *      mocked `BaseClients` to assert the broadcast → confirmed
 *      callback chain and the approve+swap batch shape.
 */

import { describe, it, expect, beforeEach } from "vitest";
import { buildApp, type AppDeps } from "../src/app.js";
import { testConfig } from "../src/config/index.js";
import {
  createTestCallbackClient,
  resetCallbackSeq,
} from "../src/callbacks/client.js";
import { dispatchSwap } from "./fixtures/index.js";
import { dispatchAuthHeaders } from "./dispatch-auth-headers.js";
import type { FastifyInstance } from "fastify";

describe("POST /dispatch/swap", () => {
  let app: FastifyInstance;
  let callbackClient: ReturnType<typeof createTestCallbackClient>;

  beforeEach(async () => {
    resetCallbackSeq();
    callbackClient = createTestCallbackClient();
    const deps: AppDeps = {
      config: testConfig(),
      callbackClient,
      // null in handler-shape tests — the executor is exercised in
      // base-swap.test.ts with a mocked BaseClients.
      baseClients: null,
    };
    app = buildApp(deps);
    await app.ready();
  });

  it("validates the fixture payload (richly-shaped 0x route)", async () => {
    // The fixture under priv/adapter/fixtures/dispatch_swap.json now
    // carries the full 0x execution-route shape (#192). With
    // `baseClients: null` the dispatch handler aborts with a
    // structured `chain_clients_unavailable` reason — the request
    // shape itself is accepted.
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/swap",
      headers: dispatchAuthHeaders,
      payload: dispatchSwap,
    });

    expect(response.statusCode).toBe(202);
    const body = response.json();
    expect(body.accepted).toBe(true);
    expect(body.status).toBe("aborted");
    expect(body.reason).toBe("chain_clients_unavailable");

    expect(callbackClient.payloads).toHaveLength(1);
    const callback = callbackClient.payloads[0]!;
    expect(callback.kind).toBe("execution.aborted");
    expect(callback.execution_plan_id).toBe(dispatchSwap.execution_plan_id);
    expect("reason" in callback && callback.reason).toBe(
      "chain_clients_unavailable",
    );
  });

  it("rejects malformed swap payload", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/swap",
      headers: dispatchAuthHeaders,
      payload: { bad: "data" },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json().error.code).toBe("validation_error");
    expect(callbackClient.payloads).toHaveLength(0);
  });

  it("rejects unsupported chain", async () => {
    const payload = { ...dispatchSwap, chain: "ethereum" };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/swap",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(422);
    expect(response.json().error.code).toBe("unsupported");
    expect(callbackClient.payloads).toHaveLength(0);
  });

  it("accepts 'base-sepolia' but rejects 'base' (mainnet) for swap dispatch (#192 P2)", async () => {
    // The MVP plan keeps live swap execution on Base Sepolia ONLY.
    // Mainnet swap dispatch is post-MVP; admitting `chain: "base"`
    // here would silently broadcast a mainnet swap UserOperation if
    // the deployment had `BASE_CHAIN_ID=8453`. The swap-specific
    // chain guard fails closed.
    const sepolia = await app.inject({
      method: "POST",
      url: "/dispatch/swap",
      headers: dispatchAuthHeaders,
      payload: { ...dispatchSwap, chain: "base-sepolia" },
    });
    expect(sepolia.statusCode).toBe(202);
    expect(sepolia.json().status).toBe("aborted");
    expect(sepolia.json().reason).toBe("chain_clients_unavailable");

    callbackClient.payloads.length = 0;

    const mainnet = await app.inject({
      method: "POST",
      url: "/dispatch/swap",
      headers: dispatchAuthHeaders,
      payload: { ...dispatchSwap, chain: "base" },
    });
    expect(mainnet.statusCode).toBe(422);
    expect(mainnet.json().error.code).toBe("unsupported");
    expect(mainnet.json().error.message).toContain("base");
    expect(mainnet.json().error.message).toContain("Base Sepolia");
    // No callback emitted — swap dispatch was refused before the
    // executor got a chance to broadcast.
    expect(callbackClient.payloads).toHaveLength(0);
  });

  it("rejects invalid slippage_bps", async () => {
    const payload = { ...dispatchSwap, slippage_bps: -10 };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/swap",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(400);
  });

  it("does not produce a fake confirmed status when chain clients are unavailable", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/swap",
      headers: dispatchAuthHeaders,
      payload: dispatchSwap,
    });

    const body = response.json();
    // Test-mode short-circuit: never claims success.
    expect(body.status).not.toBe("confirmed");
    expect(body.status).not.toBe("success");
    expect(body.status).toBe("aborted");
  });
});
