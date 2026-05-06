/**
 * Asset configuration — USDC on Base in v0.1.
 *
 * First-class support for USDC only. Other assets can be modeled
 * later without changing the dispatch or callback shapes.
 */

export interface AssetConfig {
  symbol: string;
  contractAddress: `0x${string}`;
  decimals: number;
  chain: string;
}

/** USDC on Base mainnet. */
export const USDC_BASE: AssetConfig = {
  symbol: "USDC",
  contractAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  decimals: 6,
  chain: "base",
};

export type SupportedAsset = "USDC";

export function isSupportedAsset(asset: string): asset is SupportedAsset {
  return asset === "USDC";
}

/**
 * Decimals lookup for assets the swap path (#192) supports as input
 * or output. Restricted to the MVP set: USDC ↔ USDT and USDC ↔ ETH /
 * WETH. Anything else falls through to `decimalsForSwapAsset/1`
 * returning `undefined`, which the swap dispatch fail-closes on
 * with `unsupported_input_asset` / `unsupported_output_asset`.
 *
 * `ETH` and `WETH` share 18 decimals — `ETH` is the human label, `WETH`
 * is the underlying ERC-20 the 0x router consumes / produces.
 */
export const SWAP_ASSET_DECIMALS: Record<string, number> = {
  USDC: 6,
  USDT: 6,
  ETH: 18,
  WETH: 18,
};

export type SwapAsset = keyof typeof SWAP_ASSET_DECIMALS;

export function decimalsForSwapAsset(asset: string): number | undefined {
  return SWAP_ASSET_DECIMALS[asset.toUpperCase()];
}

/**
 * Parse a decimal string amount into the token's base units (bigint).
 *
 * "50" USDC (6 decimals) -> 50_000_000n
 */
export function parseAmount(amount: string, decimals: number): bigint {
  const parts = amount.split(".");
  const whole = parts[0] ?? "0";
  const frac = (parts[1] ?? "").padEnd(decimals, "0").slice(0, decimals);
  return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(frac);
}
