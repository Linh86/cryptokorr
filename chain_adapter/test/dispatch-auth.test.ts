/**
 * Dispatch auth preHandler tests.
 *
 * The adapter REQUIRES `Authorization: Bearer <ADAPTER_DISPATCH_SECRET>`
 * on every `POST /dispatch/*` route. These tests assert the preHandler
 * applies to all three dispatch routes uniformly:
 *
 *   - missing header              → 401 missing_authorization
 *   - non-Bearer scheme           → 401 invalid_authorization_scheme
 *   - wrong bearer                → 401 invalid_credentials
 *   - correct bearer              → request reaches the handler (≠ 401)
 *
 * `GET /health` deliberately stays public — operational endpoint that
 * liveness probes can hit without credentials.
 *
 * The auth check runs BEFORE payload validation, so an unauthenticated
 * caller cannot probe the input schema. Every 401 case here uses a
 * deliberately-malformed body to confirm we never reached the
 * validator (which would return 400, not 401).
 */

import { describe, it, expect, beforeEach } from "vitest";
import { buildApp, type AppDeps } from "../src/app.js";
import { testConfig } from "../src/config/index.js";
import {
  createTestCallbackClient,
  resetCallbackSeq,
} from "../src/callbacks/client.js";
import type { FastifyInstance } from "fastify";

const DISPATCH_PATHS = [
  "/dispatch/transfer",
  "/dispatch/swap",
  "/dispatch/revoke_delegation",
] as const;

describe("dispatch auth preHandler", () => {
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

  for (const path of DISPATCH_PATHS) {
    describe(`POST ${path}`, () => {
      it("returns 401 missing_authorization when no header is sent", async () => {
        const response = await app.inject({
          method: "POST",
          url: path,
          payload: { bad: "data" },
        });

        expect(response.statusCode).toBe(401);
        expect(response.json().error.code).toBe("missing_authorization");
        expect(callbackClient.payloads).toHaveLength(0);
      });

      it("returns 401 invalid_authorization_scheme for non-Bearer schemes", async () => {
        const response = await app.inject({
          method: "POST",
          url: path,
          headers: { authorization: "Basic dXNlcjpwYXNz" },
          payload: { bad: "data" },
        });

        expect(response.statusCode).toBe(401);
        expect(response.json().error.code).toBe(
          "invalid_authorization_scheme",
        );
        expect(callbackClient.payloads).toHaveLength(0);
      });

      it("returns 401 invalid_authorization_scheme for empty Bearer token", async () => {
        const response = await app.inject({
          method: "POST",
          url: path,
          headers: { authorization: "Bearer " },
          payload: { bad: "data" },
        });

        expect(response.statusCode).toBe(401);
        expect(response.json().error.code).toBe(
          "invalid_authorization_scheme",
        );
      });

      it("returns 401 invalid_credentials when the bearer does not match", async () => {
        const response = await app.inject({
          method: "POST",
          url: path,
          headers: { authorization: "Bearer not-the-secret" },
          payload: { bad: "data" },
        });

        expect(response.statusCode).toBe(401);
        expect(response.json().error.code).toBe("invalid_credentials");
        expect(callbackClient.payloads).toHaveLength(0);
      });

      it("passes the preHandler with the configured bearer (no 401)", async () => {
        // Use a deliberately bad payload so we don't depend on chain
        // handlers — we're only asserting auth let us through to the
        // validator, which will reject the body itself.
        const response = await app.inject({
          method: "POST",
          url: path,
          headers: {
            authorization: `Bearer ${testConfig().dispatchAuthSecret}`,
          },
          payload: { bad: "data" },
        });

        expect(response.statusCode).not.toBe(401);
      });
    });
  }

  describe("GET /health", () => {
    it("does not require authentication", async () => {
      const response = await app.inject({
        method: "GET",
        url: "/health",
      });

      expect(response.statusCode).toBe(200);
      expect(response.json().status).toBe("ok");
    });
  });
});
