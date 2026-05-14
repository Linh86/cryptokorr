/**
 * Convert a real 0x v2 `/swap/permit2/quote` response into a
 * `DispatchSwap` envelope (the same shape Phoenix posts to
 * `POST /dispatch/swap`).
 *
 * This module is used by `fork-proof-swap.ts` to drive
 * `executeSwap()` against a Base mainnet fork without going through
 * Phoenix. It is also covered by unit tests so the conversion
 * stays in lockstep with the live 0x response shape.
 *
 * ## What it accepts
 *
 * A `ZeroXQuoteResponse` matching the shape returned by 0x v2 (see
 * https://0x.org/docs/api#tag/Swap/operation/swap_permit2_getQuote).
 * The required fields are:
 *
 *   * `transaction.to`     — the 0x router / AllowanceHolder
 *   * `transaction.data`   — executable calldata (NOT `0xdeadbeef`)
 *   * `transaction.value`  — native value (`"0"` for ERC-20 → ERC-20)
 *   * `sellAmount` / `buyAmount` / `minBuyAmount` — base-unit strings
 *   * `allowanceTarget`    — Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`)
 *                            on the v2 endpoint, or the legacy router on v1
 *
 * ## What it rejects
 *
 *   * Missing or empty `transaction.data`
 *   * The synthetic sentinel `"0xdeadbeef"`
 *   * Missing `transaction.to` / `allowanceTarget`
 *   * Source / destination addresses that don't match the operator-
 *     supplied token addresses (sanity check against quote tampering)
 *
 * ## Secret hygiene
 *
 * The converter never logs calldata, raw HTTP body, or any secret.
 * Failures are stable error codes; the orchestration script decides
 * how to surface them.
 */

import { decimalsForSwapAsset, parseAmount } from "../src/config/assets.js";
import type { DispatchSwap } from "../src/contracts/schemas.js";

/** Minimal subset of a 0x v2 `/swap/permit2/quote` response. */
export interface ZeroXQuoteResponse {
  liquidityAvailable?: boolean;
  sellAmount?: string;
  buyAmount?: string;
  minBuyAmount?: string;
  allowanceTarget?: string;
  sellToken?: string;
  buyToken?: string;
  transaction?: {
    to?: string;
    data?: string;
    value?: string;
    gas?: string | number;
    gasPrice?: string | number;
  };
  permit2?: unknown;
}

export interface QuoteInputs {
  /** Logical chain label. Must be `"base"` for the fork proof. */
  chain: "base";
  /** Source asset symbol — `"USDC"` for the canonical fork proof. */
  inputAsset: "USDC" | "USDT";
  /** Destination asset symbol. */
  outputAsset: "USDC" | "USDT";
  /** Source token address on `chain` (lowercased 0x + 40 hex). */
  sourceTokenAddress: string;
  /** Destination token address on `chain`. */
  destinationTokenAddress: string;
  /** Slippage cap in bps (operator-supplied). */
  slippageBps: number;
  /** Decimal-string sell amount, e.g. "10.0". */
  inputAmount: string;
  /** Phoenix smart-account UUID — propagated to the dispatch envelope. */
  smartAccountId: string;
  /** Operator-bound delegation ID for the `signing_requirements` block. */
  delegationId: string;
  /** Optional clock injection for deterministic tests. */
  now?: Date;
  /**
   * Optional explicit deadline override in seconds from `now`. Defaults
   * to 600s, matching the Phoenix resolver. The on-chain calldata
   * already encodes its own deadline; this is the envelope-level
   * stale-route guard.
   */
  deadlineSeconds?: number;
}

export type ConverterError =
  | "no_liquidity"
  | "missing_transaction"
  | "missing_calldata"
  | "synthetic_calldata_rejected"
  | "missing_target"
  | "missing_spender"
  | "missing_sell_amount"
  | "missing_buy_amount"
  | "missing_min_buy_amount"
  | "source_token_mismatch"
  | "destination_token_mismatch"
  | "unsupported_input_asset"
  | "unsupported_output_asset";

export type ConverterResult =
  | { ok: true; dispatch: DispatchSwap }
  | { ok: false; reason: ConverterError; detail?: string };

const SYNTHETIC_CALLDATA = "0xdeadbeef";

/**
 * Convert a real 0x v2 quote response + operator inputs into a
 * `DispatchSwap` envelope. The script that calls `executeSwap()`
 * directly passes the result through `DispatchSwapSchema.parse`
 * for one final schema check before dispatch.
 */
export function quoteToDispatch(
  quote: ZeroXQuoteResponse,
  inputs: QuoteInputs,
  executionPlanId: string,
  intentId: string,
  correlationId: string,
): ConverterResult {
  if (quote.liquidityAvailable === false) {
    return { ok: false, reason: "no_liquidity" };
  }

  const inputDecimals = decimalsForSwapAsset(inputs.inputAsset);
  if (inputDecimals === undefined) {
    return { ok: false, reason: "unsupported_input_asset", detail: inputs.inputAsset };
  }
  const outputDecimals = decimalsForSwapAsset(inputs.outputAsset);
  if (outputDecimals === undefined) {
    return { ok: false, reason: "unsupported_output_asset", detail: inputs.outputAsset };
  }

  const transaction = quote.transaction;
  if (!transaction || typeof transaction !== "object") {
    return { ok: false, reason: "missing_transaction" };
  }

  const data = transaction.data;
  if (!data || data === "" || data === "0x") {
    return { ok: false, reason: "missing_calldata" };
  }
  if (data.toLowerCase() === SYNTHETIC_CALLDATA) {
    return { ok: false, reason: "synthetic_calldata_rejected" };
  }

  const to = transaction.to;
  if (!to || to === "") {
    return { ok: false, reason: "missing_target" };
  }

  const spender = quote.allowanceTarget;
  if (!spender || spender === "") {
    return { ok: false, reason: "missing_spender" };
  }

  if (
    quote.sellToken &&
    quote.sellToken.toLowerCase() !== inputs.sourceTokenAddress.toLowerCase()
  ) {
    return {
      ok: false,
      reason: "source_token_mismatch",
      detail: `quote sellToken=${quote.sellToken}, expected=${inputs.sourceTokenAddress}`,
    };
  }
  if (
    quote.buyToken &&
    quote.buyToken.toLowerCase() !== inputs.destinationTokenAddress.toLowerCase()
  ) {
    return {
      ok: false,
      reason: "destination_token_mismatch",
      detail: `quote buyToken=${quote.buyToken}, expected=${inputs.destinationTokenAddress}`,
    };
  }

  if (!quote.sellAmount) return { ok: false, reason: "missing_sell_amount" };
  if (!quote.buyAmount) return { ok: false, reason: "missing_buy_amount" };
  if (!quote.minBuyAmount) return { ok: false, reason: "missing_min_buy_amount" };

  const now = inputs.now ?? new Date();
  const deadlineSeconds = inputs.deadlineSeconds ?? 600;
  const deadline = new Date(now.getTime() + deadlineSeconds * 1000);

  const expectedOutputDecimal = baseUnitsToDecimal(quote.buyAmount, outputDecimals);
  const minimumOutputDecimal = baseUnitsToDecimal(quote.minBuyAmount, outputDecimals);
  const valueDecimal = transaction.value ? hexOrIntToDecimalString(transaction.value, 18) : "0";

  const dispatch: DispatchSwap = {
    contract_version: 1,
    action: "swap",
    execution_plan_id: executionPlanId,
    intent_id: intentId,
    smart_account_id: inputs.smartAccountId,
    chain: inputs.chain,
    input_asset: inputs.inputAsset,
    output_asset: inputs.outputAsset,
    input_amount: inputs.inputAmount,
    expected_output: expectedOutputDecimal,
    slippage_bps: inputs.slippageBps,
    route: {
      venue: "zerox",
      path: [inputs.sourceTokenAddress, inputs.destinationTokenAddress],
      swap_target_contract: normaliseAddress(to),
      calldata: data as `0x${string}`,
      spender: normaliseAddress(spender),
      source_token_address: normaliseAddress(inputs.sourceTokenAddress),
      destination_token_address: normaliseAddress(inputs.destinationTokenAddress),
      minimum_output_amount: minimumOutputDecimal,
      value: valueDecimal,
      route_provider: "zerox",
      deadline: deadline.toISOString(),
    },
    signing_requirements: {
      delegation_id: inputs.delegationId,
      scope: {},
    },
    correlation_id: correlationId,
    emitted_at: now.toISOString(),
  };

  // Defense-in-depth: re-parse the operator-supplied input_amount
  // so the converter rejects malformed decimal strings before the
  // adapter's envelope check fires.
  try {
    const parsed = parseAmount(inputs.inputAmount, inputDecimals);
    if (parsed <= 0n) {
      return { ok: false, reason: "missing_sell_amount", detail: "input_amount <= 0" };
    }
  } catch {
    return { ok: false, reason: "missing_sell_amount", detail: "unparseable input_amount" };
  }

  return { ok: true, dispatch };
}

function normaliseAddress(addr: string): `0x${string}` {
  return addr.toLowerCase() as `0x${string}`;
}

function baseUnitsToDecimal(raw: string, decimals: number): string {
  // Convert a base-units integer string (e.g. "9950000") into a
  // human decimal string (e.g. "9.95") without going through
  // floating point.
  if (!/^-?\d+$/.test(raw)) {
    throw new Error(`base-units must be an integer string, got ${raw}`);
  }
  const negative = raw.startsWith("-");
  const digits = negative ? raw.slice(1) : raw;
  const padded = digits.padStart(decimals + 1, "0");
  const whole = padded.slice(0, padded.length - decimals);
  const frac = padded.slice(padded.length - decimals).replace(/0+$/, "");
  const body = frac.length === 0 ? whole : `${whole}.${frac}`;
  return negative ? `-${body}` : body;
}

function hexOrIntToDecimalString(value: string | number, _decimals: number): string {
  // Native value is in wei; we just need a decimal-string
  // representation in wei (not ETH) — the adapter parses this with
  // 18-decimal scaling and refuses non-zero for ERC-20 input. The
  // simplest correct shape: emit the integer in base-18 decimal form,
  // i.e. zero or "0.000000000000000001" etc. For the ERC-20 swap the
  // value is always 0, so we keep this tight.
  if (typeof value === "number") {
    if (value === 0) return "0";
    return baseUnitsToDecimal(String(value), 18);
  }
  if (value === "0" || value === "0x" || value === "0x0") return "0";
  if (value.startsWith("0x")) {
    const n = BigInt(value);
    return baseUnitsToDecimal(n.toString(), 18);
  }
  return baseUnitsToDecimal(value, 18);
}
