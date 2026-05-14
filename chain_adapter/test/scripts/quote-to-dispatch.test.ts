/**
 * Unit tests for the 0x quote → DispatchSwap converter used by
 * `scripts/fork-proof-swap.ts`.
 *
 * Fixtures mirror the real 0x v2 `/swap/permit2/quote` response
 * shape: `transaction.{to,data,value}`, `allowanceTarget` (Permit2
 * canonical address on Base mainnet), `sellAmount`, `buyAmount`,
 * `minBuyAmount`, `sellToken`, `buyToken`. The fields here come
 * from the 0x v2 API reference and from real Base mainnet quote
 * responses captured during prior integration work.
 */

import { describe, it, expect } from "vitest";
import { quoteToDispatch, type ZeroXQuoteResponse } from "../../scripts/quote-to-dispatch.js";
import { DispatchSwapSchema } from "../../src/contracts/schemas.js";

const USDC_BASE = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const USDT_BASE = "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2";
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

// Realistic 0x v2 router contract address on Base mainnet
// (AllowanceHolder /  Permit2-backed flow). Not the literal one;
// any non-zero hex with the right shape is fine for the converter
// — the converter doesn't verify it lives on-chain, that's the
// fork's job.
const ROUTER = "0x0000000000001ff3684f28c67538d4d072c22734";

// A representative real-shaped 0x v2 swap calldata hex. The leading
// 4 bytes are the function selector; the body is permit2/transfer
// arguments. Length is irrelevant to the converter — only that it
// isn't the synthetic placeholder.
const REAL_CALLDATA =
  "0xfae353fe0000000000000000000000000000000000000000000000000000000000000020";

function baseQuote(overrides: Partial<ZeroXQuoteResponse> = {}): ZeroXQuoteResponse {
  return {
    liquidityAvailable: true,
    sellToken: USDC_BASE,
    buyToken: USDT_BASE,
    sellAmount: "10000000", // 10 USDC, 6 decimals
    buyAmount: "9950000", // 9.95 USDT
    minBuyAmount: "9900000", // 9.90 USDT (50bps below buyAmount)
    allowanceTarget: PERMIT2,
    transaction: {
      to: ROUTER,
      data: REAL_CALLDATA,
      value: "0",
    },
    permit2: {},
    ...overrides,
  };
}

function baseInputs() {
  return {
    chain: "base" as const,
    inputAsset: "USDC" as const,
    outputAsset: "USDT" as const,
    sourceTokenAddress: USDC_BASE,
    destinationTokenAddress: USDT_BASE,
    slippageBps: 50,
    inputAmount: "10",
    smartAccountId: "sa_wb_aaaaaaaa",
    delegationId: "11111111-1111-1111-1111-111111111111",
    now: new Date("2026-05-11T20:00:00Z"),
  };
}

const EXECUTION_PLAN_ID = "22222222-2222-2222-2222-222222222222";
const INTENT_ID = "33333333-3333-3333-3333-333333333333";
const CORRELATION_ID = "44444444-4444-4444-4444-444444444444";

function convert(quote: ZeroXQuoteResponse, overrides: Partial<ReturnType<typeof baseInputs>> = {}) {
  return quoteToDispatch(
    quote,
    { ...baseInputs(), ...overrides },
    EXECUTION_PLAN_ID,
    INTENT_ID,
    CORRELATION_ID,
  );
}

describe("quoteToDispatch — happy path", () => {
  it("returns a DispatchSwap that passes DispatchSwapSchema.parse", () => {
    const result = convert(baseQuote());
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    // Schema-validates clean.
    const parsed = DispatchSwapSchema.safeParse(result.dispatch);
    expect(parsed.success).toBe(true);

    expect(result.dispatch.action).toBe("swap");
    expect(result.dispatch.contract_version).toBe(1);
    expect(result.dispatch.chain).toBe("base");
    expect(result.dispatch.route.route_provider).toBe("zerox");
    expect(result.dispatch.route.calldata).toBe(REAL_CALLDATA);
    expect(result.dispatch.route.swap_target_contract).toBe(ROUTER.toLowerCase());
    expect(result.dispatch.route.spender).toBe(PERMIT2.toLowerCase());
    expect(result.dispatch.route.source_token_address).toBe(USDC_BASE.toLowerCase());
    expect(result.dispatch.route.destination_token_address).toBe(USDT_BASE.toLowerCase());
    expect(result.dispatch.route.value).toBe("0");
  });

  it("converts base-units to decimal strings the schema accepts", () => {
    const result = convert(baseQuote());
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.dispatch.expected_output).toBe("9.95");
    // Trailing zeros stripped — "9.9" is numerically equal to "9.90"
    // and the schema's `decimalString` accepts both. We pin the
    // canonical form here so future drift trips a test.
    expect(result.dispatch.route.minimum_output_amount).toBe("9.9");
    expect(result.dispatch.slippage_bps).toBe(50);
  });

  it("propagates a real-looking deadline (RFC3339, > now)", () => {
    const result = convert(baseQuote());
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const deadline = Date.parse(result.dispatch.route.deadline!);
    expect(deadline).toBeGreaterThan(new Date("2026-05-11T20:00:00Z").getTime());
  });
});

describe("quoteToDispatch — fail-closed", () => {
  it("rejects no_liquidity", () => {
    const result = convert(baseQuote({ liquidityAvailable: false }));
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("no_liquidity");
  });

  it("rejects synthetic 0xdeadbeef calldata", () => {
    const result = convert(
      baseQuote({ transaction: { to: ROUTER, data: "0xdeadbeef", value: "0" } }),
    );
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("synthetic_calldata_rejected");
  });

  it("rejects empty calldata", () => {
    const result = convert(
      baseQuote({ transaction: { to: ROUTER, data: "", value: "0" } }),
    );
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("missing_calldata");
  });

  it("rejects missing transaction block entirely", () => {
    const q = baseQuote();
    delete q.transaction;
    const result = convert(q);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("missing_transaction");
  });

  it("rejects missing allowanceTarget (spender)", () => {
    const result = convert(baseQuote({ allowanceTarget: "" }));
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("missing_spender");
  });

  it("rejects missing target (transaction.to)", () => {
    const result = convert(
      baseQuote({ transaction: { to: "", data: REAL_CALLDATA, value: "0" } }),
    );
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("missing_target");
  });

  it("rejects source token mismatch (anti-tamper guard)", () => {
    const result = convert(baseQuote({ sellToken: USDT_BASE }));
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("source_token_mismatch");
  });

  it("rejects destination token mismatch (anti-tamper guard)", () => {
    const result = convert(baseQuote({ buyToken: USDC_BASE }));
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("destination_token_mismatch");
  });

  it("rejects unsupported input asset", () => {
    const result = convert(baseQuote(), { inputAsset: "DAI" as never });
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("unsupported_input_asset");
  });

  it("rejects missing sell/buy/min amounts", () => {
    expect(convert(baseQuote({ sellAmount: undefined })).ok).toBe(false);
    expect(convert(baseQuote({ buyAmount: undefined })).ok).toBe(false);
    expect(convert(baseQuote({ minBuyAmount: undefined })).ok).toBe(false);
  });

  it("rejects unparseable input_amount", () => {
    const result = convert(baseQuote(), { inputAmount: "not-a-number" });
    expect(result.ok).toBe(false);
  });
});

describe("quoteToDispatch — base-units conversion edge cases", () => {
  it("handles small amounts without losing precision", () => {
    const q = baseQuote({ buyAmount: "1", minBuyAmount: "1" });
    const result = convert(q);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.dispatch.expected_output).toBe("0.000001");
    expect(result.dispatch.route.minimum_output_amount).toBe("0.000001");
  });

  it("handles round amounts", () => {
    const q = baseQuote({ buyAmount: "1000000", minBuyAmount: "1000000" });
    const result = convert(q);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.dispatch.expected_output).toBe("1");
    expect(result.dispatch.route.minimum_output_amount).toBe("1");
  });
});
