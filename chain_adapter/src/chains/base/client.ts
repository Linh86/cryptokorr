/**
 * Base chain clients — viem public + bundler + delegation signer.
 *
 * v0.1 uses the ERC-4337 v0.7 path: the delegation key signs
 * UserOperation hashes, the bundler broadcasts them through the
 * EntryPoint. The raw `walletClient` is kept only for adapter paths
 * that still require an EOA-signed tx (none in v0.1 beyond tests).
 */

import {
  createPublicClient,
  createWalletClient,
  http,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import type { AdapterConfig } from "../../config/index.js";
import { createBaseBundler, type BundlerClient } from "./bundler.js";

/**
 * Typed clients for Base chain.
 *
 * `ReturnType` captures the exact viem return types rather than
 * fighting generic type parameters for chain-specific transaction
 * types (Base has `deposit` tx type, etc.).
 */
export interface BaseClients {
  publicClient: ReturnType<typeof createBasePublicClient>;
  walletClient: ReturnType<typeof createBaseWalletClient>;
  bundlerClient: BundlerClient;
  /** Delegation signer — signs UserOperation hashes on behalf of the smart account. */
  account: ReturnType<typeof privateKeyToAccount>;
  /** Address of the smart account (`sender` of every UserOperation). */
  smartAccountAddress: `0x${string}`;
  /** EntryPoint v0.7 address configured for this adapter instance. */
  entryPointAddress: `0x${string}`;
}

function createBasePublicClient(rpcUrl: string) {
  return createPublicClient({
    chain: base,
    transport: http(rpcUrl),
  });
}

function createBaseWalletClient(
  rpcUrl: string,
  account: ReturnType<typeof privateKeyToAccount>,
) {
  return createWalletClient({
    chain: base,
    transport: http(rpcUrl),
    account,
  });
}

export function createBaseClients(config: AdapterConfig): BaseClients {
  const account = privateKeyToAccount(
    config.delegationSignerKey as `0x${string}`,
  );

  const publicClient = createBasePublicClient(config.baseRpcUrl);
  const walletClient = createBaseWalletClient(config.baseRpcUrl, account);
  const bundlerClient = createBaseBundler(config.bundlerRpcUrl);

  return {
    publicClient,
    walletClient,
    bundlerClient,
    account,
    smartAccountAddress: config.smartAccountAddress,
    entryPointAddress: config.entryPointAddress,
  };
}

/**
 * Verify the configured RPC and bundler endpoints are actually on the
 * expected chain. Run once at startup, before the service accepts any
 * dispatch.
 *
 * The user-op hash binds the chain id (`getUserOperationHash` includes
 * `chainId` in the canonical preimage). If the bundler is silently
 * pointed at a different chain than `publicClient`, every signature
 * the adapter produces will be valid for the wrong chain — Phoenix
 * would track operations that cannot be resolved on Base, and a
 * paranoid bundler would reject every send. Cheaper to detect at
 * startup than per request.
 *
 * Throws on mismatch. The caller (server.ts) is expected to log + exit.
 */
export async function assertBaseChainIdentity(
  clients: BaseClients,
  expectedChainId: number,
): Promise<void> {
  const [publicChainId, bundlerChainId] = await Promise.all([
    clients.publicClient.getChainId(),
    clients.bundlerClient.getChainId(),
  ]);

  if (publicChainId !== expectedChainId) {
    throw new Error(
      `Base RPC chain id mismatch: BASE_RPC_URL reports chain ${publicChainId}, ` +
        `expected ${expectedChainId}. Refusing to start.`,
    );
  }

  if (bundlerChainId !== expectedChainId) {
    throw new Error(
      `Bundler chain id mismatch: BUNDLER_RPC_URL reports chain ${bundlerChainId}, ` +
        `expected ${expectedChainId}. Refusing to start.`,
    );
  }
}
