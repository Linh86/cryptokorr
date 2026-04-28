/**
 * Bundler client for ERC-4337 v0.7 UserOperations.
 *
 * Thin wrapper around viem's `createBundlerClient`. Exposes only the
 * actions the adapter actually uses:
 *
 *   - `estimateUserOperationGas` — for the three v0.7 gas limits.
 *   - `sendUserOperation` — broadcast to the bundler, returns userop hash.
 *   - `waitForUserOperationReceipt` — wait for the bundler to confirm
 *     the UserOperation was included, returns the on-chain tx receipt.
 *   - `getChainId` — startup-time check that the bundler endpoint is
 *     actually on the expected chain (see `assertBaseChainIdentity`
 *     in `client.ts`). The signed user-op hash is bound to the chain
 *     id; a mismatched bundler would produce signatures the chain
 *     can never validate.
 *
 * The bundler endpoint is a distinct JSON-RPC URL from the chain RPC;
 * production deployments point at a dedicated bundler service (Pimlico,
 * Alchemy AA, Stackup, etc.). See `src/config/index.ts`.
 *
 * The adapter stays close to viem's raw API here rather than inventing a
 * custom wrapper type — the indirection is just a seam for tests to
 * substitute a mock bundler without mocking an HTTP transport.
 */

import { http, type Chain } from "viem";
import { createBundlerClient } from "viem/account-abstraction";

/**
 * Full typed bundler client as returned by viem. Kept as a
 * `ReturnType` alias so callers can depend on this module rather than
 * reach into `viem/account-abstraction` for the type.
 */
export type BundlerClient = ReturnType<typeof createBaseBundlerClient>;

function createBaseBundlerClient(bundlerRpcUrl: string, chain: Chain) {
  return createBundlerClient({
    chain,
    transport: http(bundlerRpcUrl),
  });
}

/** Creates a Base bundler client from a raw JSON-RPC URL. */
export function createBaseBundler(
  bundlerRpcUrl: string,
  chain: Chain,
): BundlerClient {
  return createBaseBundlerClient(bundlerRpcUrl, chain);
}
