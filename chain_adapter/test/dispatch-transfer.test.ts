/**
 * Transfer dispatch handler tests.
 */

import { describe, it, expect, beforeEach } from "vitest";
import { buildApp, type AppDeps } from "../src/app.js";
import { testConfig } from "../src/config/index.js";
import {
  createTestCallbackClient,
  resetCallbackSeq,
} from "../src/callbacks/client.js";
import { dispatchTransfer } from "./fixtures/index.js";
import { dispatchAuthHeaders } from "./dispatch-auth-headers.js";
import type { FastifyInstance } from "fastify";

describe("POST /dispatch/transfer", () => {
  let app: FastifyInstance;
  let callbackClient: ReturnType<typeof createTestCallbackClient>;

  beforeEach(async () => {
    resetCallbackSeq();
    callbackClient = createTestCallbackClient();
    const deps: AppDeps = {
      config: testConfig(),
      callbackClient,
      baseClients: null, // transfer will fail at chain call, which is expected
    };
    app = buildApp(deps);
    await app.ready();
  });

  it("validates the fixture payload shape and returns 400 on bad input", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/transfer",
      headers: dispatchAuthHeaders,
      payload: { bad: "data" },
    });

    expect(response.statusCode).toBe(400);
    const body = response.json();
    expect(body.error.code).toBe("validation_error");
  });

  it("rejects missing amount", async () => {
    const payload = { ...dispatchTransfer, amount: undefined };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/transfer",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(400);
  });

  it("rejects wrong contract version", async () => {
    const payload = { ...dispatchTransfer, contract_version: 99 };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/transfer",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(400);
  });

  it("rejects unsupported chain", async () => {
    const payload = { ...dispatchTransfer, chain: "solana" };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/transfer",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(422);
    expect(response.json().error.code).toBe("unsupported");
  });

  it("rejects unsupported asset", async () => {
    const payload = { ...dispatchTransfer, asset: "DAI" };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/transfer",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(422);
    expect(response.json().error.code).toBe("unsupported");
  });

  it("rejects non-UUID execution_plan_id", async () => {
    const payload = { ...dispatchTransfer, execution_plan_id: "not-a-uuid" };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/transfer",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(400);
  });

  it("rejects non-hex target address", async () => {
    const payload = {
      ...dispatchTransfer,
      target: { ...dispatchTransfer.target, address: "not-hex" },
    };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/transfer",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(400);
  });
});
