/**
 * Startup-time chain identity check (`assertBaseChainIdentity`).
 *
 * The adapter MUST refuse to start if either the configured Base RPC
 * endpoint or the bundler endpoint reports a chain id that disagrees
 * with the expected value. Two reasons:
 *
 *   - User-op hashes bind chain id (`getUserOperationHash` includes
 *     `chainId` in the canonical preimage). A mismatched bundler would
 *     return signatures that no chain can validate.
 *   - Phoenix's audit trail anchors `userop_hash` as identity; if the
 *     bundler is silently on a different network than the public RPC,
 *     the hashes Phoenix records correspond to operations on the wrong
 *     chain.
 *
 * Failing closed at startup is much cheaper than per-request: the
 * mismatch is a config error, not a runtime condition.
 */

import { describe, it, expect } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { assertBaseChainIdentity } from "../src/chains/base/client.js";
import type { BaseClients } from "../src/chains/base/client.js";

const SMART_ACCOUNT =
  "0x000000000000000000000000000000000000a11c" as const;
const ENTRY_POINT = "0x0000000071727de22e5e9d8baf0edac6f37da032" as const;
const SIGNER_KEY = ("0x" + "ab".repeat(32)) as `0x${string}`;

interface ChainIds {
  publicChainId: number;
  bundlerChainId: number;
}

function clientsWithChainIds({
  publicChainId,
  bundlerChainId,
}: ChainIds): BaseClients {
  return {
    publicClient: {
      chain: { id: publicChainId },
      getChainId: async () => publicChainId,
    },
    walletClient: {},
    bundlerClient: {
      getChainId: async () => bundlerChainId,
    },
    account: privateKeyToAccount(SIGNER_KEY),
    smartAccountAddress: SMART_ACCOUNT,
    entryPointAddress: ENTRY_POINT,
  } as unknown as BaseClients;
}

describe("assertBaseChainIdentity", () => {
  const BASE_CHAIN_ID = 8453;

  it("returns successfully when both endpoints report the expected chain id", async () => {
    const clients = clientsWithChainIds({
      publicChainId: BASE_CHAIN_ID,
      bundlerChainId: BASE_CHAIN_ID,
    });

    await expect(
      assertBaseChainIdentity(clients, BASE_CHAIN_ID),
    ).resolves.toBeUndefined();
  });

  it("throws when the public RPC reports a wrong chain id", async () => {
    // Common operator footgun: BASE_RPC_URL accidentally points at a
    // testnet (Base Sepolia, 84532) while the rest of the config
    // expects mainnet.
    const clients = clientsWithChainIds({
      publicChainId: 84532,
      bundlerChainId: BASE_CHAIN_ID,
    });

    await expect(
      assertBaseChainIdentity(clients, BASE_CHAIN_ID),
    ).rejects.toThrow(/BASE_RPC_URL reports chain 84532/);
  });

  it("throws when the bundler reports a wrong chain id", async () => {
    // Equally common: bundler subscription was provisioned for the
    // wrong network. Without this check the adapter would still sign
    // user-ops bound to BASE_CHAIN_ID and the bundler would either
    // drop them silently or relay them on the wrong chain.
    const clients = clientsWithChainIds({
      publicChainId: BASE_CHAIN_ID,
      bundlerChainId: 1, // ethereum mainnet
    });

    await expect(
      assertBaseChainIdentity(clients, BASE_CHAIN_ID),
    ).rejects.toThrow(/BUNDLER_RPC_URL reports chain 1/);
  });

  it("throws when both endpoints disagree with the expected chain id", async () => {
    // The check should still fail loud — it surfaces the public RPC
    // mismatch first because that is what the adapter hashes against.
    const clients = clientsWithChainIds({
      publicChainId: 84532,
      bundlerChainId: 1,
    });

    await expect(
      assertBaseChainIdentity(clients, BASE_CHAIN_ID),
    ).rejects.toThrow(/chain/);
  });
});
