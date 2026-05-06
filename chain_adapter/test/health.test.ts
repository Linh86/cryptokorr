/**
 * Health endpoint test.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { buildApp, type AppDeps } from "../src/app.js";
import { testConfig } from "../src/config/index.js";
import { createTestCallbackClient } from "../src/callbacks/client.js";
import type { FastifyInstance } from "fastify";

describe("GET /health", () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    const deps: AppDeps = {
      config: testConfig(),
      callbackClient: createTestCallbackClient(),
      baseClients: null,
    };
    app = buildApp(deps);
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
  });

  it("returns 200 with service info", async () => {
    const response = await app.inject({
      method: "GET",
      url: "/health",
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.status).toBe("ok");
    expect(body.service).toBe("cryptobank-ts-adapter");
    expect(body.contract_version).toBe(1);
    expect(body.supported_chains).toEqual(["base", "base-sepolia"]);
    expect(body.supported_assets).toEqual(["USDC"]);
    expect(body.timestamp).toBeTruthy();
  });
});
