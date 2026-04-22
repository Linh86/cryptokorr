/**
 * Chain configuration — Base only in v0.1.
 *
 * No multi-chain abstraction. This module is deliberately narrow:
 * one chain, one set of constants.
 */

export const BASE_CHAIN = {
  id: 8453,
  name: "base",
  /** Confirmations required before a tx is considered final. */
  confirmations: 2,
  /** Block time in seconds (Base L2). */
  blockTimeSeconds: 2,
  /** Max gas price (in gwei) before the adapter refuses to broadcast. */
  maxGasPriceGwei: 5n,
} as const;

export type SupportedChain = "base";

export function isSupportedChain(chain: string): chain is SupportedChain {
  return chain === "base";
}
