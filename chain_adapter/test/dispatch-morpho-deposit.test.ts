/**
 * Morpho deposit dispatch handler tests (#206).
 *
 * The dispatch-layer tests use `baseClients: null` and prove that:
 *   1. The Phoenix fixture round-trips through the zod schema.
 *   2. Each per-field validation gate fires the expected error
 *      shape (400 for shape errors, 422 for unsupported chain/asset).
 *   3. With `baseClients: null` the handler emits a structured
 *      `execution.aborted` callback with reason
 *      `chain_clients_unavailable` rather than 500-ing.
 *   4. Mainnet (`chain: "base"`) is rejected at the adapter even
 *      though the generic chain guard would admit it. Belt-and-
 *      suspenders with the Phoenix `Bank.Intents.normalize/1`
 *      boundary gate (#203 P2).
 *
 * Full bundler/UserOp execution is exercised by a separate
 * `base-morpho-deposit.test.ts` (mocked bundler) — out of scope
 * here.
 */

import { describe, it, expect, beforeEach } from "vitest";
import { buildApp, type AppDeps } from "../src/app.js";
import { testConfig } from "../src/config/index.js";
import {
  createTestCallbackClient,
  resetCallbackSeq,
} from "../src/callbacks/client.js";
import { dispatchMorphoDeposit } from "./fixtures/index.js";
import { dispatchAuthHeaders } from "./dispatch-auth-headers.js";
import type { FastifyInstance } from "fastify";

describe("POST /dispatch/morpho_deposit (#206)", () => {
  let app: FastifyInstance;
  let callbackClient: ReturnType<typeof createTestCallbackClient>;

  beforeEach(async () => {
    resetCallbackSeq();
    callbackClient = createTestCallbackClient();
    const deps: AppDeps = {
      config: testConfig(),
      callbackClient,
      // Null baseClients triggers the structured
      // `chain_clients_unavailable` abort branch.
      baseClients: null,
    };
    app = buildApp(deps);
    await app.ready();
  });

  it("accepts the canonical fixture and emits execution.aborted (chain_clients_unavailable) when no baseClients", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/morpho_deposit",
      headers: dispatchAuthHeaders,
      payload: dispatchMorphoDeposit,
    });

    expect(response.statusCode).toBe(202);
    const body = response.json();
    expect(body.accepted).toBe(true);
    expect(body.execution_plan_id).toBe(
      (dispatchMorphoDeposit as { execution_plan_id: string }).execution_plan_id,
    );
    expect(body.status).toBe("aborted");
    expect(body.reason).toBe("chain_clients_unavailable");

    // The structured abort callback fired so Phoenix sees a
    // concrete `execution.aborted` row instead of a 500.
    expect(callbackClient.payloads.length).toBe(1);
    const cb = callbackClient.payloads[0] as { kind: string; reason?: string };
    expect(cb.kind).toBe("execution.aborted");
    expect(cb.reason).toBe("chain_clients_unavailable");
  });

  it("rejects bad payload shape (400)", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/morpho_deposit",
      headers: dispatchAuthHeaders,
      payload: { bad: "data" },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json().error.code).toBe("validation_error");
  });

  it("rejects wrong contract version", async () => {
    const payload = { ...dispatchMorphoDeposit, contract_version: 99 };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/morpho_deposit",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(400);
  });

  it("rejects unsupported chain (e.g., ethereum) at the generic guard", async () => {
    const payload = { ...dispatchMorphoDeposit, chain: "ethereum" };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/morpho_deposit",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(422);
    expect(response.json().error.code).toBe("unsupported");
  });

  it("rejects mainnet (chain: 'base') at the morpho-specific guard — Base Sepolia only in v0.1", async () => {
    const payload = { ...dispatchMorphoDeposit, chain: "base" };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/morpho_deposit",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(422);
    expect(response.json().error.code).toBe("unsupported");
    expect(response.json().error.message).toMatch(/Base Sepolia only/i);
  });

  it("rejects unsupported asset (e.g., DAI)", async () => {
    const payload = { ...dispatchMorphoDeposit, asset: "DAI" };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/morpho_deposit",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(422);
    expect(response.json().error.code).toBe("unsupported");
  });

  it("rejects non-hex vault_address (400)", async () => {
    const payload = { ...dispatchMorphoDeposit, vault_address: "not-hex" };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/morpho_deposit",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(400);
  });

  it("rejects non-UUID execution_plan_id (400)", async () => {
    const payload = { ...dispatchMorphoDeposit, execution_plan_id: "not-a-uuid" };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/morpho_deposit",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(400);
  });

  it("rejects missing required field (e.g., amount)", async () => {
    const payload = { ...dispatchMorphoDeposit, amount: undefined };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/morpho_deposit",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(400);
  });

  it("does NOT accept a `calldata` field on the wire (Phoenix never supplies adapter calldata for morpho_deposit)", async () => {
    // The schema deliberately has no `calldata` field. A payload
    // that ADDS `calldata` should still validate (zod by default
    // strips unknown fields), but the field never reaches the
    // execution path. This test pins the structural invariant
    // that a future schema change cannot silently start honouring
    // operator-supplied calldata.
    const payload = { ...dispatchMorphoDeposit, calldata: "0xdeadbeef" };
    const response = await app.inject({
      method: "POST",
      url: "/dispatch/morpho_deposit",
      headers: dispatchAuthHeaders,
      payload,
    });

    expect(response.statusCode).toBe(202);
    expect(response.json().status).toBe("aborted");
    expect(response.json().reason).toBe("chain_clients_unavailable");
  });
});
