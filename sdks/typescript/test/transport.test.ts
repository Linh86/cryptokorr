import { describe, expect, it, vi } from "vitest";
import { resolveConfig } from "../src/config.js";
import {
  IdempotencyConflictError,
  RateLimitError,
  ValidationError,
  WorkspacePausedError,
} from "../src/errors.js";
import { Transport } from "../src/transport.js";

const TEST_KEY = "cb_test_dummy_key_for_unit_tests_only";

interface MockCall {
  url: string;
  init: RequestInit;
}

interface JsonResponseInit {
  status?: number;
  body?: unknown;
  headers?: Record<string, string>;
}

function jsonResponse({ status = 200, body, headers = {} }: JsonResponseInit = {}): Response {
  const text = body === undefined ? "" : JSON.stringify(body);
  return new Response(text, {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

function makeTransport(
  responses: Response[],
  opts: { timeoutMs?: number; baseUrl?: string } = {},
): { transport: Transport; calls: MockCall[] } {
  const calls: MockCall[] = [];
  let i = 0;
  const fetchImpl = vi.fn(async (input: string | URL, init?: RequestInit) => {
    calls.push({ url: input.toString(), init: init ?? {} });
    if (i >= responses.length) {
      throw new Error(`mock fetch ran out of responses at call ${i + 1}`);
    }
    const response = responses[i];
    i += 1;
    return response!;
  });

  const cfg = resolveConfig({
    apiKey: TEST_KEY,
    baseUrl: opts.baseUrl ?? "http://localhost:4000",
    ...(opts.timeoutMs !== undefined && { timeoutMs: opts.timeoutMs }),
    fetch: fetchImpl,
  });
  return { transport: new Transport(cfg), calls };
}

function readBody(init: RequestInit): Record<string, unknown> {
  expect(init.body).toBeTypeOf("string");
  return JSON.parse(init.body as string) as Record<string, unknown>;
}

function readHeaders(init: RequestInit): Record<string, string> {
  // RequestInit.headers can be string[][], Record, or Headers in
  // theory; the SDK always passes a plain Record.
  return init.headers as Record<string, string>;
}

describe("Transport.request — happy path", () => {
  it("camelCases the response and snake_cases the request", async () => {
    const { transport, calls } = makeTransport([
      jsonResponse({
        status: 202,
        body: {
          intent_id: "int_123",
          state: "submitted",
          idempotent_replay: false,
          intent: { id: "int_123", agent_id: "agent-alice" },
          links: { self: "/v1/intents/int_123", replay: "/v1/intents/int_123/replay" },
        },
      }),
    ]);

    const result = await transport.request<{
      intentId: string;
      idempotentReplay: boolean;
      intent: { id: string; agentId: string };
    }>({
      method: "POST",
      path: "/v1/intents",
      body: { agentId: "agent-alice", chain: "base-sepolia" },
    });

    expect(result.intentId).toBe("int_123");
    expect(result.idempotentReplay).toBe(false);
    expect(result.intent.agentId).toBe("agent-alice");

    expect(calls).toHaveLength(1);
    const wireBody = readBody(calls[0]!.init);
    expect(wireBody).toEqual({ agent_id: "agent-alice", chain: "base-sepolia" });
  });

  it("auto-generates an Idempotency-Key on writes", async () => {
    const { transport, calls } = makeTransport([
      jsonResponse({ status: 202, body: { ok: true } }),
    ]);
    await transport.request({
      method: "POST",
      path: "/v1/intents",
      body: { foo: "bar" },
    });
    const headers = readHeaders(calls[0]!.init);
    expect(headers["idempotency-key"]).toMatch(/.{8,}/);
  });

  it("respects a caller-supplied Idempotency-Key", async () => {
    const { transport, calls } = makeTransport([
      jsonResponse({ status: 202, body: { ok: true } }),
    ]);
    await transport.request({
      method: "POST",
      path: "/v1/intents",
      body: { foo: "bar" },
      idempotencyKey: "stable-key-123",
    });
    expect(readHeaders(calls[0]!.init)["idempotency-key"]).toBe("stable-key-123");
  });

  it("does NOT add an Idempotency-Key on GET", async () => {
    const { transport, calls } = makeTransport([
      jsonResponse({ status: 200, body: { id: "abc" } }),
    ]);
    await transport.request({ method: "GET", path: "/v1/intents/abc" });
    expect(readHeaders(calls[0]!.init)["idempotency-key"]).toBeUndefined();
  });

  it("sends Authorization with the bearer key on authed calls", async () => {
    const { transport, calls } = makeTransport([
      jsonResponse({ status: 200, body: { ok: true } }),
    ]);
    await transport.request({ method: "GET", path: "/v1/intents/abc" });
    expect(readHeaders(calls[0]!.init)["authorization"]).toBe(`Bearer ${TEST_KEY}`);
  });

  it("omits Authorization when unauthenticated=true (health/deep)", async () => {
    const { transport, calls } = makeTransport([
      jsonResponse({ status: 200, body: { status: "ok" } }),
    ]);
    await transport.request({
      method: "GET",
      path: "/v1/health/deep",
      unauthenticated: true,
    });
    expect(readHeaders(calls[0]!.init)["authorization"]).toBeUndefined();
  });

  it("appends defined query params and drops undefined", async () => {
    const { transport, calls } = makeTransport([
      jsonResponse({ status: 200, body: { data: [] } }),
    ]);
    await transport.request({
      method: "GET",
      path: "/v1/counterparties",
      query: { q: "acme", active: true, cursor: undefined, limit: 10 },
    });
    expect(calls[0]!.url).toBe(
      "http://localhost:4000/v1/counterparties?q=acme&active=true&limit=10",
    );
  });
});

describe("Transport.request — error decoding", () => {
  it("throws ValidationError on 422 invalid_amount", async () => {
    const { transport } = makeTransport([
      jsonResponse({
        status: 422,
        body: {
          error: {
            code: "invalid_amount",
            message: "amount must be positive",
            retryable: false,
          },
        },
      }),
    ]);
    await expect(
      transport.request({ method: "POST", path: "/v1/intents", body: { foo: "bar" } }),
    ).rejects.toBeInstanceOf(ValidationError);
  });

  it("throws IdempotencyConflictError on 409 idempotency_conflict", async () => {
    const { transport } = makeTransport([
      jsonResponse({
        status: 409,
        body: {
          error: {
            code: "idempotency_conflict",
            message: "key reused with mismatched body",
            retryable: false,
          },
        },
      }),
    ]);
    await expect(
      transport.request({ method: "POST", path: "/v1/intents", body: {}, idempotencyKey: "k" }),
    ).rejects.toBeInstanceOf(IdempotencyConflictError);
  });

  it("throws RateLimitError on 429 with Retry-After parsed", async () => {
    const { transport } = makeTransport([
      jsonResponse({
        status: 429,
        headers: { "retry-after": "5" },
        body: { error: { code: "rate_limited", message: "slow down", retryable: true } },
      }),
      // Second call (after a single retry would happen) — but we
      // pass `idempotencyKey: undefined` on a GET so retry is
      // disabled regardless. Provide a stub anyway in case the
      // budget logic fires.
      jsonResponse({ status: 429, body: { error: { code: "rate_limited", message: "slow down", retryable: true } } }),
    ]);
    await expect(
      transport.request({ method: "GET", path: "/v1/intents/abc" }),
    ).rejects.toMatchObject({
      name: "RateLimitError",
      retryAfterSeconds: 5,
    });
  });
});

describe("Transport.request — retry posture", () => {
  it("retries a retryable 503 once when an Idempotency-Key is present", async () => {
    const { transport, calls } = makeTransport([
      jsonResponse({
        status: 503,
        body: { error: { code: "workspace_paused", message: "paused", retryable: true } },
      }),
      jsonResponse({ status: 202, body: { intent_id: "int_ok", idempotent_replay: false } }),
    ]);
    const result = await transport.request<{ intentId: string }>({
      method: "POST",
      path: "/v1/intents",
      body: { foo: "bar" },
      idempotencyKey: "stable",
    });
    expect(result.intentId).toBe("int_ok");
    expect(calls).toHaveLength(2);
  });

  it("does NOT retry a non-retryable 422 even with an Idempotency-Key", async () => {
    const { transport, calls } = makeTransport([
      jsonResponse({
        status: 422,
        body: { error: { code: "invalid_amount", message: "bad", retryable: false } },
      }),
    ]);
    await expect(
      transport.request({
        method: "POST",
        path: "/v1/intents",
        body: { foo: "bar" },
        idempotencyKey: "stable",
      }),
    ).rejects.toBeInstanceOf(ValidationError);
    expect(calls).toHaveLength(1);
  });

  it("surfaces WorkspacePausedError class for 503 workspace_paused", async () => {
    const { transport } = makeTransport([
      jsonResponse({
        status: 503,
        body: { error: { code: "workspace_paused", message: "paused", retryable: true } },
      }),
      jsonResponse({
        status: 503,
        body: { error: { code: "workspace_paused", message: "paused", retryable: true } },
      }),
      jsonResponse({
        status: 503,
        body: { error: { code: "workspace_paused", message: "paused", retryable: true } },
      }),
    ]);
    // Use a tight retry budget so the test doesn't burn 60 seconds.
    await expect(
      transport.request(
        {
          method: "POST",
          path: "/v1/intents",
          body: { foo: "bar" },
          idempotencyKey: "stable",
          retryBudgetMs: 50,
        },
      ),
    ).rejects.toBeInstanceOf(WorkspacePausedError);
  });
});

describe("Transport.request — secret hygiene", () => {
  it("never embeds the API key in network-error messages", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new TypeError(`fetch failed (key cb_abcdefghij1234567 leaked)`);
    });
    const cfg = resolveConfig({
      apiKey: TEST_KEY,
      baseUrl: "http://localhost:4000",
      fetch: fetchImpl,
    });
    const transport = new Transport(cfg);

    await expect(
      transport.request({ method: "GET", path: "/v1/health/deep", unauthenticated: true }),
    ).rejects.toThrow(/\[REDACTED\]/);
  });
});
