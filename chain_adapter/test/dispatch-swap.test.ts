/**
 * Swap dispatch handler tests.
 *
 * Swap is intentionally not wired in v0.1. These tests verify that:
 * 1. The request shape is validated
 * 2. The handler aborts explicitly
 * 3. An execution.aborted callback is sent to Phoenix
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
      baseClients: null,
    };
    app = buildApp(deps);
    await app.ready();
  });

  it("validates the fixture payload and aborts with a callback", async () => {
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
    expect(body.reason).toContain("swap_not_implemented");

    // Verify the abort callback was sent
    expect(callbackClient.payloads).toHaveLength(1);
    const callback = callbackClient.payloads[0]!;
    expect(callback.kind).toBe("execution.aborted");
    expect(callback.execution_plan_id).toBe(dispatchSwap.execution_plan_id);
    expect("reason" in callback && callback.reason).toContain(
      "swap_not_implemented",
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

  it("does not produce a fake success", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/swap",
      headers: dispatchAuthHeaders,
      payload: dispatchSwap,
    });

    const body = response.json();
    // Explicitly: the swap never claims to have been executed
    expect(body.status).not.toBe("confirmed");
    expect(body.status).not.toBe("success");
    expect(body.status).toBe("aborted");
  });
});
