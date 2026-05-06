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

/**
 * Swap-specific chain allowlist (#192 P2).
 *
 * The MVP plan keeps live swap execution on Base Sepolia ONLY —
 * mainnet swap dispatch is post-MVP. The generic `isSupportedChain`
 * still admits both `"base"` and `"base-sepolia"` for the legacy
 * transfer path; swap dispatch must NOT silently fall through to
 * mainnet broadcast.
 *
 * The dispatch swap handler calls this helper before delegating to
 * `executeSwap`. A `chain: "base"` envelope fails closed with
 * `UnsupportedError` so Phoenix sees a 422 + `unsupported` error
 * code, not a successful broadcast.
 */
export type SupportedSwapChain = "base-sepolia";

export function isSupportedSwapChain(chain: string): chain is SupportedSwapChain {
  return chain === "base-sepolia";
}

/**
 * Morpho-deposit-specific chain allowlist (#206).
 *
 * MVP plan: Morpho ERC-4626 USDC deposits are Base Sepolia only.
 * Mainnet Morpho is post-MVP and depends on #166/#178 plus the
 * exposure / concentration engine that was explicitly deferred.
 * The generic `isSupportedChain` still admits `"base"` for the
 * legacy transfer path; the morpho dispatch handler calls this
 * helper to fail closed if a `chain: "base"` envelope ever reaches
 * the adapter. Belt-and-suspenders with the Phoenix boundary gate
 * in `Bank.Intents.normalize/1` (#203 P2).
 */
export type SupportedMorphoDepositChain = "base-sepolia";

export function isSupportedMorphoDepositChain(
  chain: string,
): chain is SupportedMorphoDepositChain {
  return chain === "base-sepolia";
}
