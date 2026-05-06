/**
 * Chain configuration — Base mainnet + Base Sepolia.
 *
 * Both chain *labels* are accepted on the dispatch envelope. Which
 * actual network the adapter operates on is determined by the
 * deployment's `BASE_CHAIN_ID` env var (8453 mainnet / 84532 sepolia)
 * plus the matching `BASE_RPC_URL` / `BUNDLER_RPC_URL`. Accepting both
 * labels keeps the adapter compatible with the v0.1 mainnet transfer
 * path AND the #192 MVP testnet 0x swap path without requiring two
 * separate deployments to share the same code base.
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

export const BASE_SEPOLIA_CHAIN = {
  id: 84532,
  name: "base-sepolia",
  confirmations: 2,
  blockTimeSeconds: 2,
  maxGasPriceGwei: 5n,
} as const;

export type SupportedChain = "base" | "base-sepolia";

export function isSupportedChain(chain: string): chain is SupportedChain {
  return chain === "base" || chain === "base-sepolia";
}
