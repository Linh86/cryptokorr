/**
 * Asset config utility tests.
 */

import { describe, it, expect } from "vitest";
import { parseAmount, isSupportedAsset } from "../src/config/assets.js";
import {
  isSupportedChain,
  isSupportedSwapChain,
} from "../src/config/chains.js";

describe("parseAmount", () => {
  it("parses whole numbers", () => {
    // 50 USDC (6 decimals) = 50_000_000
    expect(parseAmount("50", 6)).toBe(50_000_000n);
  });

  it("parses decimals", () => {
    // 1.5 USDC = 1_500_000
    expect(parseAmount("1.5", 6)).toBe(1_500_000n);
  });

  it("parses amounts with more decimals than the token (truncates)", () => {
    // 1.1234567 USDC truncated to 6 decimals = 1_123_456
    expect(parseAmount("1.1234567", 6)).toBe(1_123_456n);
  });

  it("parses zero", () => {
    expect(parseAmount("0", 6)).toBe(0n);
  });

  it("parses large amounts", () => {
    // 1,000,000 USDC
    expect(parseAmount("1000000", 6)).toBe(1_000_000_000_000n);
  });

  it("handles 18-decimal tokens", () => {
    // 1 WETH (18 decimals)
    expect(parseAmount("1", 18)).toBe(1_000_000_000_000_000_000n);
  });
});

describe("isSupportedAsset", () => {
  it("accepts USDC", () => {
    expect(isSupportedAsset("USDC")).toBe(true);
  });

  it("rejects unsupported assets", () => {
    expect(isSupportedAsset("DAI")).toBe(false);
    expect(isSupportedAsset("WETH")).toBe(false);
    expect(isSupportedAsset("")).toBe(false);
  });
});

describe("isSupportedChain", () => {
  it("accepts base", () => {
    expect(isSupportedChain("base")).toBe(true);
  });

  it("accepts base-sepolia", () => {
    expect(isSupportedChain("base-sepolia")).toBe(true);
  });

  it("rejects unsupported chains", () => {
    expect(isSupportedChain("ethereum")).toBe(false);
    expect(isSupportedChain("arbitrum")).toBe(false);
    expect(isSupportedChain("")).toBe(false);
  });
});

describe("isSupportedSwapChain (#192 P2)", () => {
  // The swap MVP is Base Sepolia ONLY — mainnet swap is post-MVP.
  // This is a narrower allowlist than the generic `isSupportedChain`
  // (which still admits both for the legacy transfer path) so a
  // `chain: "base"` swap dispatch fails closed at the adapter
  // boundary instead of broadcasting a mainnet UserOperation.

  it("accepts base-sepolia", () => {
    expect(isSupportedSwapChain("base-sepolia")).toBe(true);
  });

  it("rejects base mainnet for swap dispatch", () => {
    expect(isSupportedSwapChain("base")).toBe(false);
  });

  it("rejects unsupported chains", () => {
    expect(isSupportedSwapChain("ethereum")).toBe(false);
    expect(isSupportedSwapChain("arbitrum")).toBe(false);
    expect(isSupportedSwapChain("")).toBe(false);
  });
});
