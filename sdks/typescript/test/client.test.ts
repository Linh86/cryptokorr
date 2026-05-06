import { describe, expect, it, vi } from "vitest";
import { Cryptobank } from "../src/client.js";
import { SwapSafetyError, ValidationError } from "../src/errors.js";

const TEST_KEY = "cb_test_dummy_key_for_unit_tests_only";

interface MockCall {
  url: string;
  init: RequestInit;
}

interface MockSpec {
  status?: number;
  body?: unknown;
  headers?: Record<string, string>;
}

function jsonResponse({ status = 200, body, headers = {} }: MockSpec): Response {
  return new Response(body === undefined ? "" : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

function makeClient(specs: MockSpec[]): { client: Cryptobank; calls: MockCall[] } {
  const calls: MockCall[] = [];
  let i = 0;
  const fetchImpl = vi.fn(async (input: string | URL, init?: RequestInit) => {
    calls.push({ url: input.toString(), init: init ?? {} });
    if (i >= specs.length) throw new Error(`mock ran out at call ${i + 1}`);
    const spec = specs[i]!;
    i += 1;
    return jsonResponse(spec);
  });
  return {
    client: new Cryptobank({
      apiKey: TEST_KEY,
      baseUrl: "http://localhost:4000",
      fetch: fetchImpl,
    }),
    calls,
  };
}

function readBody(init: RequestInit): Record<string, unknown> {
  return JSON.parse(init.body as string) as Record<string, unknown>;
}

describe("Cryptobank.fromEnv", () => {
  it("reads CRYPTOBANK_API_KEY from process.env", () => {
    const old = process.env["CRYPTOBANK_API_KEY"];
    process.env["CRYPTOBANK_API_KEY"] = TEST_KEY;
    try {
      const client = Cryptobank.fromEnv();
      expect(client.toString()).toBe("Cryptobank(baseUrl=http://localhost:4000)");
    } finally {
      if (old === undefined) delete process.env["CRYPTOBANK_API_KEY"];
      else process.env["CRYPTOBANK_API_KEY"] = old;
    }
  });

  it("toString() does NOT echo the API key", () => {
    const client = new Cryptobank({ apiKey: TEST_KEY, baseUrl: "http://localhost:4000" });
    expect(client.toString()).not.toContain("cb_");
    expect(client.toString()).not.toContain(TEST_KEY);
  });
});

describe("Cryptobank.submitTransfer", () => {
  it("POSTs /v1/intents with snake_case kind=transfer", async () => {
    const { client, calls } = makeClient([
      {
        status: 202,
        body: {
          intent_id: "int_xfer",
          state: "submitted",
          idempotent_replay: false,
          intent: { id: "int_xfer" },
          links: { self: "/v1/intents/int_xfer", replay: "/v1/intents/int_xfer/replay" },
        },
      },
    ]);

    const result = await client.submitTransfer({
      agentId: "agent-alice",
      asset: "USDC",
      chain: "base-sepolia",
      amount: "10.5",
      target: { counterpartyId: "cp_1" },
      idempotencyKey: "fixed-key",
    });

    expect(result.intentId).toBe("int_xfer");
    expect(result.idempotentReplay).toBe(false);
    expect(calls[0]!.url).toBe("http://localhost:4000/v1/intents");
    expect(calls[0]!.init.method).toBe("POST");
    expect(readBody(calls[0]!.init)).toEqual({
      agent_id: "agent-alice",
      kind: "transfer",
      asset: "USDC",
      chain: "base-sepolia",
      amount: "10.5",
      target: { counterparty_id: "cp_1" },
      source: "agent",
    });
  });

  it("forwards smartAccountId when supplied", async () => {
    const { client, calls } = makeClient([
      { status: 202, body: { intent_id: "x", state: "submitted", idempotent_replay: false, intent: {}, links: {} } },
    ]);
    await client.submitTransfer({
      agentId: "a",
      asset: "USDC",
      chain: "base-sepolia",
      amount: "1",
      target: { rawAddress: "0xabc" },
      smartAccountId: "sa_main",
    });
    expect(readBody(calls[0]!.init)["smart_account_id"]).toBe("sa_main");
  });

  it("surfaces SwapSafetyError on swap_amount_invalid", async () => {
    const { client } = makeClient([
      {
        status: 422,
        body: {
          error: {
            code: "swap_amount_invalid",
            message: "min > expected",
            retryable: false,
          },
        },
      },
    ]);
    await expect(
      client.submitSwap({
        agentId: "a",
        chain: "base-sepolia",
        sourceAsset: "USDC",
        destinationAsset: "USDC",
        amount: "0",
      }),
    ).rejects.toBeInstanceOf(SwapSafetyError);
  });

  it("surfaces ValidationError on plain invalid_amount", async () => {
    const { client } = makeClient([
      {
        status: 422,
        body: {
          error: { code: "invalid_amount", message: "must be positive", retryable: false },
        },
      },
    ]);
    await expect(
      client.submitTransfer({
        agentId: "a",
        asset: "USDC",
        chain: "base-sepolia",
        amount: "0",
        target: { rawAddress: "0xabc" },
      }),
    ).rejects.toBeInstanceOf(ValidationError);
  });
});

describe("Cryptobank.submitAllocateIdleCapital", () => {
  it("defaults chain to base-sepolia and sends kind=defi_yield_deposit", async () => {
    const { client, calls } = makeClient([
      { status: 202, body: { intent_id: "int_morpho", state: "submitted", idempotent_replay: false, intent: {}, links: {} } },
    ]);
    await client.submitAllocateIdleCapital({
      agentId: "a",
      asset: "USDC",
      amount: "1",
      vaultAddress: "0xv4ult",
    });
    expect(readBody(calls[0]!.init)).toMatchObject({
      kind: "defi_yield_deposit",
      chain: "base-sepolia",
      vault_address: "0xv4ult",
    });
  });
});

describe("Cryptobank.simulateIntent / cancelIntent / getAuditTrail", () => {
  it("simulateIntent posts the reason", async () => {
    const { client, calls } = makeClient([
      { status: 200, body: { id: "sim_1", intent_id: "int_1", status: "ok" } },
    ]);
    const result = await client.simulateIntent("int_1", { reason: "operator_inspection" });
    expect(result.id).toBe("sim_1");
    expect(calls[0]!.url).toBe("http://localhost:4000/v1/intents/int_1/simulate");
    expect(readBody(calls[0]!.init)).toEqual({ reason: "operator_inspection" });
  });

  it("cancelIntent posts the reason and surfaces idempotent flag", async () => {
    const { client, calls } = makeClient([
      {
        status: 200,
        body: {
          intent_id: "int_1",
          state: "cancelled",
          idempotent: true,
          reason: "operator_canceled",
          intent: {},
          links: {},
        },
      },
    ]);
    const result = await client.cancelIntent("int_1", { reason: "operator_canceled" });
    expect(result.idempotent).toBe(true);
    expect(readBody(calls[0]!.init)).toEqual({ reason: "operator_canceled" });
  });

  it("getAuditTrail GETs the replay path", async () => {
    const { client, calls } = makeClient([
      { status: 200, body: { intent: null, decisions: [], simulations: [] } },
    ]);
    await client.getAuditTrail("int_1");
    expect(calls[0]!.url).toBe("http://localhost:4000/v1/intents/int_1/replay");
    expect(calls[0]!.init.method).toBe("GET");
  });
});

describe("Cryptobank.waitForDecision", () => {
  it("polls intent → decision until outcome lands", async () => {
    const { client, calls } = makeClient([
      // First intent fetch — no decision yet.
      { status: 200, body: { id: "int_1", current_decision_id: null } },
      // Second intent fetch — decision id available.
      { status: 200, body: { id: "int_1", current_decision_id: "dec_1" } },
      // Decision fetch.
      {
        status: 200,
        body: {
          id: "dec_1",
          intent_id: "int_1",
          outcome: "approval_required",
          state: "decided",
          current: true,
          risk_tier: "moderate",
          reasons: { items: [] },
          approval_expires_at: null,
          decided_at: "2026-05-06T00:00:00Z",
          decided_by: null,
          policy_snapshot_ref: null,
          supersedes_id: null,
        },
      },
    ]);

    const decision = await client.waitForDecision("int_1", {
      timeoutSeconds: 5,
      pollIntervalMs: 1,
    });
    expect(decision.outcome).toBe("approval_required");
    expect(calls).toHaveLength(3);
  });

  it("times out cleanly", async () => {
    const { client } = makeClient(
      Array.from({ length: 50 }, () => ({
        status: 200,
        body: { id: "int_1", current_decision_id: null },
      })),
    );
    await expect(
      client.waitForDecision("int_1", { timeoutSeconds: 0, pollIntervalMs: 1 }),
    ).rejects.toThrow(/timed out/);
  });
});

describe("Cryptobank.operator.approveDecision / rejectDecision", () => {
  it("approveDecision posts to /v1/approvals/:id/approve with actor_id", async () => {
    const { client, calls } = makeClient([
      {
        status: 200,
        body: {
          decision: { id: "dec_1", intent_id: "int_1", outcome: "auto_exec", approval_expires_at: null },
          dispatch: "dispatched",
          execution_plan: { plan_id: "plan_1", smart_account_id: "sa_main" },
        },
      },
    ]);

    const result = await client.operator.approveDecision("dec_1", {
      actorId: "ops",
      reason: "looks good",
    });
    expect(result.dispatch).toBe("dispatched");
    expect(result.executionPlan).toEqual({ planId: "plan_1", smartAccountId: "sa_main" });
    expect(calls[0]!.url).toBe("http://localhost:4000/v1/approvals/dec_1/approve");
    expect(readBody(calls[0]!.init)).toEqual({ actor_id: "ops", reason: "looks good" });
  });

  it("rejectDecision posts to /v1/approvals/:id/reject", async () => {
    const { client, calls } = makeClient([
      {
        status: 200,
        body: {
          decision: { id: "dec_1", intent_id: "int_1", outcome: "block", approval_expires_at: null },
          dispatch: "no_dispatch",
        },
      },
    ]);
    await client.operator.rejectDecision("dec_1", { actorId: "ops", reason: "too risky" });
    expect(calls[0]!.url).toBe("http://localhost:4000/v1/approvals/dec_1/reject");
  });
});

describe("Cryptobank.getRuntimeStatus", () => {
  it("hits /v1/health/deep without Authorization", async () => {
    const { client, calls } = makeClient([
      { status: 200, body: { status: "ok", service: "bank", version: "0.1.0", checks: {} } },
    ]);
    const status = await client.getRuntimeStatus();
    expect(status.status).toBe("ok");
    const headers = calls[0]!.init.headers as Record<string, string>;
    expect(headers["authorization"]).toBeUndefined();
  });
});
