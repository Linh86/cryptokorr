/**
 * Mocked-fetch shape tests for the Vercel AI SDK tool wrappers.
 *
 * Runs under Node's built-in test runner (`node --test`), no extra
 * test framework needed. The tests inject a fake `fetch` so no
 * network call leaves the process.
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { Cryptobank } from "@cryptobank/sdk";
import { buildCryptobankTools } from "../tools.ts";

interface MockSpec {
  status?: number;
  body?: unknown;
}

function jsonResponse({ status = 200, body }: MockSpec): Response {
  return new Response(body === undefined ? "" : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

interface MockCall {
  url: string;
  init: RequestInit;
}

function mockClient(specs: MockSpec[]): { client: Cryptobank; calls: MockCall[] } {
  const calls: MockCall[] = [];
  let i = 0;
  const fetchImpl = async (input: string | URL, init?: RequestInit) => {
    calls.push({ url: input.toString(), init: init ?? {} });
    if (i >= specs.length) throw new Error(`mock ran out at call ${i + 1}`);
    const spec = specs[i]!;
    i += 1;
    return jsonResponse(spec);
  };
  return {
    client: new Cryptobank({
      apiKey: "cb_test_dummy_key_for_unit_tests_only",
      baseUrl: "http://localhost:4000",
      fetch: fetchImpl,
    }),
    calls,
  };
}

describe("buildCryptobankTools", () => {
  it("exposes the three documented tools", () => {
    const { client } = mockClient([]);
    const tools = buildCryptobankTools({ client });
    assert.deepEqual(Object.keys(tools).sort(), [
      "getDecision",
      "submitAllocateIdleCapital",
      "submitTransfer",
    ]);
  });

  it("submitTransfer description warns about approval_required", () => {
    const { client } = mockClient([]);
    const tools = buildCryptobankTools({ client });
    assert.match(tools.submitTransfer.description, /approval_required is a successful response/);
  });

  it("submitTransfer parameters pin Base Sepolia + USDC enums", () => {
    const { client } = mockClient([]);
    const tools = buildCryptobankTools({ client });
    const props = tools.submitTransfer.parameters.properties as Record<string, { enum?: string[] }>;
    assert.deepEqual(props["chain"]!.enum, ["base-sepolia"]);
    assert.deepEqual(props["asset"]!.enum, ["USDC"]);
    assert.deepEqual(tools.submitTransfer.parameters.required, ["amount", "target"]);
  });

  it("submitAllocateIdleCapital requires amount + vaultAddress", () => {
    const { client } = mockClient([]);
    const tools = buildCryptobankTools({ client });
    assert.deepEqual(
      tools.submitAllocateIdleCapital.parameters.required,
      ["amount", "vaultAddress"],
    );
  });

  it("getDecision description names every outcome", () => {
    const { client } = mockClient([]);
    const tools = buildCryptobankTools({ client });
    const desc = tools.getDecision.description;
    for (const outcome of ["auto_exec", "approval_required", "hold", "block"]) {
      assert.ok(desc.includes(outcome), `getDecision description missing outcome ${outcome}`);
    }
  });

  it("submitTransfer.execute calls the SDK with snake_case kind=transfer on the wire", async () => {
    const { client, calls } = mockClient([
      {
        status: 202,
        body: {
          intent_id: "int_test",
          state: "submitted",
          idempotent_replay: false,
          intent: {},
          links: {},
        },
      },
    ]);
    const tools = buildCryptobankTools({ client });

    const result = await tools.submitTransfer.execute({
      amount: "1.5",
      target: { rawAddress: "0xdead" },
    });
    assert.equal(result.intentId, "int_test");
    assert.equal(calls.length, 1);
    assert.equal(calls[0]!.url, "http://localhost:4000/v1/intents");

    const wire = JSON.parse(calls[0]!.init.body as string) as Record<string, unknown>;
    assert.equal(wire["kind"], "transfer");
    assert.equal(wire["chain"], "base-sepolia");
    assert.equal(wire["asset"], "USDC");
    assert.deepEqual(wire["target"], { raw_address: "0xdead" });
  });

  it("submitAllocateIdleCapital.execute sends defi_yield_deposit kind on the wire", async () => {
    const { client, calls } = mockClient([
      {
        status: 202,
        body: {
          intent_id: "int_morpho",
          state: "submitted",
          idempotent_replay: false,
          intent: {},
          links: {},
        },
      },
    ]);
    const tools = buildCryptobankTools({ client });

    await tools.submitAllocateIdleCapital.execute({
      amount: "10",
      vaultAddress: "0xVault",
    });
    const wire = JSON.parse(calls[0]!.init.body as string) as Record<string, unknown>;
    // The TS SDK currently sends defi_yield_deposit; the response
    // returns the public name allocate_idle_capital. The example
    // test pins the wire shape only.
    assert.equal(wire["kind"], "defi_yield_deposit");
    assert.equal(wire["chain"], "base-sepolia");
    assert.equal(wire["vault_address"], "0xVault");
  });

  it("getDecision.execute fetches /v1/decisions/:id", async () => {
    const { client, calls } = mockClient([
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
    const tools = buildCryptobankTools({ client });

    const decision = await tools.getDecision.execute({ decisionId: "dec_1" });
    assert.equal(decision.outcome, "approval_required");
    assert.equal(calls[0]!.url, "http://localhost:4000/v1/decisions/dec_1");
    assert.equal(calls[0]!.init.method, "GET");
  });
});
