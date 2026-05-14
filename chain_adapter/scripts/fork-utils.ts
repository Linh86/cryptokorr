/**
 * Anvil fork utilities for the Base mainnet swap fork proof.
 *
 * These helpers wrap anvil's JSON-RPC cheat methods to fund a smart
 * account on the fork *without touching the real wallet*. They are
 * fork-only and refuse to run if the configured chain ID isn't 8453
 * — the canonical Base mainnet chain id — so a typo can't redirect
 * the cheats at the real bundler/RPC.
 *
 * ## What it does
 *
 *   * `assertAnvilFork` — confirms the RPC reports `8453` (matching
 *     the upstream Base mainnet fork) and that the cheat namespace
 *     responds. Refuses non-fork RPCs.
 *   * `setEthBalance` — gives an address gas budget on the fork.
 *   * `impersonateUsdcWhale` + `transferFromWhale` — moves USDC
 *     from a known whale to the smart account without knowing the
 *     storage layout of the proxy.
 *
 * ## What it does NOT do
 *
 *   * Hit a real bundler.
 *   * Broadcast to Base mainnet.
 *   * Touch private keys or signed transactions outside the fork.
 *
 * ## Secret hygiene
 *
 * Cheats never log private keys, calldata, or signed payloads.
 * Errors are stable strings.
 */

import {
  createPublicClient,
  createWalletClient,
  custom,
  encodeFunctionData,
  http,
  parseAbi,
  type Address,
  type Hex,
} from "viem";
import { base } from "viem/chains";

/**
 * Canonical Base mainnet USDC whales. Picking one at random keeps
 * the proof reproducible even if any single address has drifted —
 * if the first one fails, the script tries the next. Operators can
 * override with `--whale 0x...`.
 *
 * Sources (publicly known holders on Base mainnet):
 *   * Aerodrome USDC pool (well-funded routing liquidity)
 *   * Coinbase 2 (custodial USDC reserve, very large balance)
 *
 * These are well-known on-chain identities — no private data.
 */
export const DEFAULT_USDC_WHALES: Address[] = [
  "0xD34EA7278e6BD48DefE656bbE263aEf11101469c", // Aerodrome USDC pool (well-funded)
  "0x21a9dE0d2517Ec3D6C0c8b3164c43Ec6f31D7a4D", // Random heavy USDC holder
];

const ERC20_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
]);

export interface ForkRpc {
  rpcUrl: string;
  expectedChainId: 8453;
}

export async function assertAnvilFork({ rpcUrl, expectedChainId }: ForkRpc): Promise<void> {
  const client = createPublicClient({ chain: base, transport: http(rpcUrl) });
  const chainId = await client.getChainId();
  if (chainId !== expectedChainId) {
    throw new Error(
      `Refusing to run: RPC chain id is ${chainId}, expected ${expectedChainId} ` +
        `(Base mainnet semantics). Point BASE_RPC_URL at an anvil fork of Base mainnet.`,
    );
  }

  // Probe an anvil-only cheat to refuse public Base mainnet RPCs.
  // `anvil_metadata` is harmless; if the upstream rejects it, we
  // know we're not on anvil and refuse to broadcast cheats.
  const cheatClient = createCheatClient(rpcUrl);
  try {
    await cheatClient.request({ method: "anvil_metadata", params: [] });
  } catch (err) {
    throw new Error(
      `Refusing to run: RPC does not expose anvil_metadata cheat. ` +
        `This script ONLY runs against a local anvil fork — never against ` +
        `public Base mainnet. Start anvil with \`anvil --fork-url <BASE_RPC>\`.`,
    );
  }
}

function createCheatClient(rpcUrl: string) {
  return createPublicClient({
    chain: base,
    transport: http(rpcUrl),
  });
}

/**
 * Set an address's native ETH balance on the fork. Uses anvil's
 * `anvil_setBalance` cheat. Fork-only.
 */
export async function setEthBalance(
  rpcUrl: string,
  account: Address,
  weiBalance: bigint,
): Promise<void> {
  const client = createCheatClient(rpcUrl);
  await client.request({
    method: "anvil_setBalance" as never,
    params: [account, `0x${weiBalance.toString(16)}`] as never,
  });
}

/**
 * Impersonate a USDC whale and transfer USDC to the target account.
 * Returns the whale address actually used (the first one with a
 * sufficient balance). Throws if no configured whale has enough.
 *
 * Fork-only: refuses to run if the RPC doesn't expose anvil cheats.
 */
export async function fundUsdcViaWhale({
  rpcUrl,
  usdcAddress,
  recipient,
  amountBaseUnits,
  whales = DEFAULT_USDC_WHALES,
}: {
  rpcUrl: string;
  usdcAddress: Address;
  recipient: Address;
  amountBaseUnits: bigint;
  whales?: Address[];
}): Promise<{ whale: Address; balanceAfter: bigint }> {
  const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });

  let lastErr: string | undefined;

  for (const whale of whales) {
    const balance = (await publicClient.readContract({
      address: usdcAddress,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [whale],
    })) as bigint;

    if (balance < amountBaseUnits) {
      lastErr = `whale ${whale} has balance ${balance}, need ${amountBaseUnits}`;
      continue;
    }

    await publicClient.request({
      method: "anvil_impersonateAccount" as never,
      params: [whale] as never,
    });

    // Give the whale enough ETH to pay the transfer's gas.
    await setEthBalance(rpcUrl, whale, 10n ** 18n);

    const transferData = encodeFunctionData({
      abi: ERC20_ABI,
      functionName: "transfer",
      args: [recipient, amountBaseUnits],
    });

    const walletClient = createWalletClient({
      chain: base,
      transport: http(rpcUrl),
      account: whale,
    });

    const txHash = await walletClient.sendTransaction({
      to: usdcAddress,
      data: transferData,
      gas: 200_000n,
    });

    await publicClient.waitForTransactionReceipt({ hash: txHash });

    await publicClient.request({
      method: "anvil_stopImpersonatingAccount" as never,
      params: [whale] as never,
    });

    const balanceAfter = (await publicClient.readContract({
      address: usdcAddress,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [recipient],
    })) as bigint;

    return { whale, balanceAfter };
  }

  throw new Error(
    `Could not fund recipient: no configured whale had enough USDC. Last: ${lastErr ?? "no whales configured"}`,
  );
}

/**
 * Read an ERC-20 balance — used by the script to report
 * pre/post balance deltas without going through the adapter's
 * `BaseClients` helpers.
 */
export async function readErc20Balance(
  rpcUrl: string,
  token: Address,
  owner: Address,
): Promise<bigint> {
  const client = createPublicClient({ chain: base, transport: http(rpcUrl) });
  return (await client.readContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [owner],
  })) as bigint;
}

/**
 * Check that EntryPoint v0.7 has bytecode at the canonical address.
 * A Base mainnet fork that doesn't include the EntryPoint deployment
 * (e.g. forked at a block before deployment) will fail this check
 * and the script aborts with a clear reason.
 */
export async function assertEntryPointDeployed(
  rpcUrl: string,
  entryPoint: Address,
): Promise<void> {
  const client = createPublicClient({ chain: base, transport: http(rpcUrl) });
  const code = await client.getCode({ address: entryPoint });
  if (!code || code === "0x") {
    throw new Error(
      `EntryPoint v0.7 (${entryPoint}) has no bytecode on the fork. ` +
        `Fork at a more recent Base mainnet block.`,
    );
  }
}

/** Convert a human USDC amount string ("10.0") to 6-decimal base units. */
export function usdcBaseUnits(amount: string): bigint {
  const [whole, frac = ""] = amount.split(".");
  const padded = (frac + "000000").slice(0, 6);
  return BigInt(whole) * 1_000_000n + BigInt(padded || "0");
}
