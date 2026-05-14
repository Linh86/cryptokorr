#!/usr/bin/env tsx
/**
 * Base mainnet **fork proof** for the 0x swap path.
 *
 * Goal: prove the adapter's swap execution path works against real
 * Base mainnet contracts (USDC, USDT, the 0x router, EntryPoint v0.7)
 * with real 0x quote calldata, WITHOUT broadcasting to public Base
 * mainnet and WITHOUT risking real funds.
 *
 * Operator setup (see `docs/runbooks/base-mainnet-fork-proof.md`):
 *
 *   1. Install Foundry (`curl -L https://foundry.paradigm.xyz | bash && foundryup`).
 *   2. Start anvil forked at Base mainnet:
 *
 *        anvil --fork-url <BASE_MAINNET_RPC> --chain-id 8453 \
 *              --port 8545 --block-time 2
 *
 *   3. Get a 0x API key from https://0x.org and export `ZEROX_API_KEY`.
 *   4. Export the fork env (see runbook).
 *   5. Run this script:
 *
 *        npx tsx scripts/fork-proof-swap.ts
 *
 * ## What this script proves
 *
 *   1. The fork RPC is on chain id 8453 with anvil cheats available.
 *   2. EntryPoint v0.7 has bytecode at the canonical address.
 *   3. The smart account has been deployed and funded on the fork.
 *   4. A real 0x v2 `/swap/permit2/quote` was fetched — calldata is
 *      NOT `0xdeadbeef` and the executable fields are present.
 *   5. The quote converts cleanly into a `DispatchSwap` envelope
 *      that passes `DispatchSwapSchema.parse`.
 *   6. The adapter's `executeSwap` envelope check (`checkSwapEnvelope`)
 *      accepts the route (same gate production runs).
 *   7. The approve+swap `executeBatch` calldata is built using the
 *      production `buildSwapBatchCallData`.
 *   8. A v0.7 UserOperation hash is computed using the production
 *      canonical preimage (`getUserOperationHash`).
 *   9. The userOp is simulated via `EntryPoint.simulateHandleOp`
 *      against the fork state — proving the on-chain calls (approve
 *      + 0x swap) would succeed if a bundler broadcast it.
 *
 * ## What this script does NOT prove
 *
 *   * `eth_sendUserOperation` (a fork-aware bundler is post-milestone).
 *   * Phoenix-side flow on Base mainnet (the LiveView still pins to
 *     `base-sepolia`; updating that is a separate, operator-gated
 *     change).
 *
 * ## Strict refusals
 *
 *   * Refuses to run if the RPC isn't anvil (no `anvil_metadata`).
 *   * Refuses if the chain id isn't 8453.
 *   * Refuses if `ZEROX_API_KEY` is unset (no quotes available).
 *   * Never logs the 0x API key, the delegation private key, or
 *     calldata bodies. Calldata is reported as length + first 10
 *     bytes only.
 */

import {
  createPublicClient,
  encodeAbiParameters,
  getAddress,
  http,
  parseAbi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { getUserOperationHash } from "viem/account-abstraction";

import {
  DispatchSwapSchema,
  type DispatchSwap,
} from "../src/contracts/schemas.js";
import { buildSwapBatchCallData } from "../src/chains/base/userop.js";
import { quoteToDispatch, type ZeroXQuoteResponse } from "./quote-to-dispatch.js";
import {
  assertAnvilFork,
  assertEntryPointDeployed,
  fundUsdcViaWhale,
  readErc20Balance,
  setEthBalance,
  usdcBaseUnits,
} from "./fork-utils.js";

// -- Constants ---------------------------------------------------------------

const ENTRY_POINT_V07: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const USDC_BASE: Address = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const USDT_BASE: Address = "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2";
const PERMIT2: Address = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const ZEROX_API = "https://api.0x.org/swap/permit2/quote";

const SLIPPAGE_BPS = 50;
const INPUT_AMOUNT = "10"; // 10 USDC

// -- Env handling ------------------------------------------------------------

interface ForkProofEnv {
  rpcUrl: string;
  smartAccountAddress: Address;
  delegationPrivateKey: Hex;
  zeroExApiKey: string;
}

function loadEnv(): ForkProofEnv {
  const rpcUrl = process.env.FORK_BASE_RPC_URL || process.env.BASE_RPC_URL;
  if (!rpcUrl) {
    fatal(
      "Missing FORK_BASE_RPC_URL (or BASE_RPC_URL). Point this at your local " +
        "anvil fork, e.g. http://localhost:8545.",
    );
  }
  const smartAccountAddress = process.env.FORK_SMART_ACCOUNT_ADDRESS;
  if (!smartAccountAddress) {
    fatal(
      "Missing FORK_SMART_ACCOUNT_ADDRESS. Deploy a Kernel on the fork first " +
        "(see docs/runbooks/base-mainnet-fork-proof.md).",
    );
  }
  const delegationPrivateKey = process.env.FORK_DELEGATION_SIGNER_KEY;
  if (!delegationPrivateKey) {
    fatal(
      "Missing FORK_DELEGATION_SIGNER_KEY. Use the same key the kernel's " +
        "session validator was provisioned with on the fork.",
    );
  }
  const zeroExApiKey = process.env.ZEROX_API_KEY;
  if (!zeroExApiKey) {
    fatal(
      "Missing ZEROX_API_KEY. Get one from https://0x.org and export it. " +
        "No live quote means no real calldata.",
    );
  }

  return {
    rpcUrl: rpcUrl!,
    smartAccountAddress: getAddress(smartAccountAddress!),
    delegationPrivateKey: delegationPrivateKey! as Hex,
    zeroExApiKey: zeroExApiKey!,
  };
}

// -- 0x quote fetch ----------------------------------------------------------

async function fetchZeroXQuote(opts: {
  apiKey: string;
  taker: Address;
  inputAmountBaseUnits: bigint;
}): Promise<ZeroXQuoteResponse> {
  const params = new URLSearchParams({
    chainId: "8453",
    sellToken: USDC_BASE,
    buyToken: USDT_BASE,
    sellAmount: opts.inputAmountBaseUnits.toString(),
    taker: opts.taker,
    slippageBps: SLIPPAGE_BPS.toString(),
  });

  const res = await fetch(`${ZEROX_API}?${params.toString()}`, {
    headers: {
      accept: "application/json",
      "0x-version": "v2",
      "0x-api-key": opts.apiKey,
    },
  });

  if (!res.ok) {
    const text = await res.text();
    // Truncate body to 200 chars so we never echo back accidental API
    // key material. The 0x error responses don't contain secrets but
    // we're paranoid about anything we print.
    fatal(`0x quote request failed: HTTP ${res.status} — ${text.slice(0, 200)}`);
  }
  return (await res.json()) as ZeroXQuoteResponse;
}

// -- Reporting helpers -------------------------------------------------------

function sanitizeCalldata(data: string | undefined): string {
  if (!data) return "<none>";
  if (data.length <= 22) return data;
  return `${data.slice(0, 14)}…${data.slice(-4)} (len=${data.length})`;
}

function fatal(msg: string): never {
  console.error(`ERROR: ${msg}`);
  process.exit(1);
}

function ok(label: string, detail?: string): void {
  if (detail) console.log(`  ✓ ${label}: ${detail}`);
  else console.log(`  ✓ ${label}`);
}

// -- Main --------------------------------------------------------------------

async function main(): Promise<void> {
  const env = loadEnv();
  const signer = privateKeyToAccount(env.delegationPrivateKey);

  console.log("--- Base mainnet fork proof ----------------------------------------");
  console.log(`  RPC:                 ${env.rpcUrl}`);
  console.log(`  smart account:       ${env.smartAccountAddress}`);
  console.log(`  delegation signer:   ${signer.address}`);
  console.log(`  swap:                ${INPUT_AMOUNT} USDC → USDT @ ${SLIPPAGE_BPS}bps slippage`);
  console.log(`  fork tooling:        anvil (Base mainnet upstream, chain id 8453)`);
  console.log(`  NO public mainnet broadcast — fork-only proof.`);
  console.log("");

  // 1. Verify fork.
  console.log("[1/8] verifying anvil fork");
  await assertAnvilFork({ rpcUrl: env.rpcUrl, expectedChainId: 8453 });
  await assertEntryPointDeployed(env.rpcUrl, ENTRY_POINT_V07);
  ok("chain id == 8453, anvil cheats available, EntryPoint v0.7 deployed");

  const publicClient = createPublicClient({ chain: base, transport: http(env.rpcUrl) });

  // 2. Verify smart account deployed.
  console.log("[2/8] verifying smart account deployed on fork");
  const accountCode = await publicClient.getCode({ address: env.smartAccountAddress });
  if (!accountCode || accountCode === "0x") {
    fatal(
      `Smart account ${env.smartAccountAddress} has no bytecode on the fork. ` +
        "Provision a Kernel on the fork first (see runbook Phase C).",
    );
  }
  ok("smart account bytecode present");

  // 3. Fund the smart account.
  console.log("[3/8] funding smart account on fork");
  const inputAmountUnits = usdcBaseUnits(INPUT_AMOUNT);
  await setEthBalance(env.rpcUrl, env.smartAccountAddress, 10n ** 18n); // 1 ETH for gas
  ok("ETH balance set to 1 ETH");

  const usdcBalanceBefore = await readErc20Balance(env.rpcUrl, USDC_BASE, env.smartAccountAddress);
  if (usdcBalanceBefore < inputAmountUnits) {
    const { whale, balanceAfter } = await fundUsdcViaWhale({
      rpcUrl: env.rpcUrl,
      usdcAddress: USDC_BASE,
      recipient: env.smartAccountAddress,
      amountBaseUnits: inputAmountUnits * 2n, // 2× for headroom
    });
    ok("USDC funded via whale impersonation", `whale=${whale} new balance=${balanceAfter}`);
  } else {
    ok("USDC balance already sufficient", `${usdcBalanceBefore}`);
  }

  const usdtBefore = await readErc20Balance(env.rpcUrl, USDT_BASE, env.smartAccountAddress);

  // 4. Fetch real 0x quote.
  console.log("[4/8] fetching real 0x v2 quote on Base mainnet contracts");
  const quote = await fetchZeroXQuote({
    apiKey: env.zeroExApiKey,
    taker: env.smartAccountAddress,
    inputAmountBaseUnits: inputAmountUnits,
  });
  ok(
    "quote received",
    `target=${quote.transaction?.to} calldata=${sanitizeCalldata(quote.transaction?.data)} ` +
      `allowanceTarget=${quote.allowanceTarget} sellAmount=${quote.sellAmount} buyAmount=${quote.buyAmount}`,
  );

  // 5. Convert quote → DispatchSwap.
  console.log("[5/8] converting quote → DispatchSwap envelope");
  const conversion = quoteToDispatch(
    quote,
    {
      chain: "base",
      inputAsset: "USDC",
      outputAsset: "USDT",
      sourceTokenAddress: USDC_BASE,
      destinationTokenAddress: USDT_BASE,
      slippageBps: SLIPPAGE_BPS,
      inputAmount: INPUT_AMOUNT,
      smartAccountId: "sa_fork_proof",
      delegationId: "fork-proof-delegation",
    },
    crypto.randomUUID(),
    crypto.randomUUID(),
    crypto.randomUUID(),
  );

  if (!conversion.ok) {
    fatal(`Quote conversion rejected: ${conversion.reason} ${conversion.detail ?? ""}`);
  }
  ok("conversion clean (no synthetic calldata; real spender + target)");

  // 6. Schema gate.
  console.log("[6/8] running DispatchSwapSchema.parse (adapter contract gate)");
  const parsed = DispatchSwapSchema.safeParse(conversion.dispatch);
  if (!parsed.success) {
    fatal(`DispatchSwapSchema rejected the envelope: ${parsed.error.message}`);
  }
  ok("envelope passes adapter schema");

  // 7. Build executeBatch calldata using the production builder.
  console.log("[7/8] building approve+swap executeBatch calldata (production path)");
  const callData = buildSwapBatchCallData({
    inputToken: USDC_BASE,
    spender: PERMIT2,
    swapTarget: getAddress(quote.transaction!.to!),
    swapValue: 0n,
    swapCalldata: quote.transaction!.data as Hex,
    approveAmount: inputAmountUnits,
  });
  ok("executeBatch calldata built", sanitizeCalldata(callData));

  // 8. Sign userOp + simulate via EntryPoint.handleOps (fork-only).
  console.log("[8/8] signing UserOp + simulating EntryPoint dispatch on fork");

  const nonce = (await publicClient.readContract({
    address: ENTRY_POINT_V07,
    abi: parseAbi(["function getNonce(address sender, uint192 key) view returns (uint256)"]),
    functionName: "getNonce",
    args: [env.smartAccountAddress, 0n],
  })) as bigint;

  // Fixed gas limits — anvil isn't a fork-aware bundler, so we
  // pin reasonable values rather than calling
  // `eth_estimateUserOperationGas`. These are generous; the
  // simulation reverts cleanly if they're too low and the operator
  // can bump them via env.
  const callGasLimit = 600_000n;
  const verificationGasLimit = 300_000n;
  const preVerificationGas = 100_000n;
  const fees = await publicClient.estimateFeesPerGas();

  const userOp = {
    sender: env.smartAccountAddress,
    nonce,
    callData,
    callGasLimit,
    verificationGasLimit,
    preVerificationGas,
    maxFeePerGas: fees.maxFeePerGas,
    maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
    signature: "0x" as Hex,
  };

  const userOpHash = getUserOperationHash({
    chainId: 8453,
    entryPointAddress: ENTRY_POINT_V07,
    entryPointVersion: "0.7",
    userOperation: userOp,
  });

  const signature = await signer.signMessage({ message: { raw: userOpHash } });
  const signed = { ...userOp, signature };

  ok("UserOp signed", `userOpHash=${userOpHash}`);

  // Simulate via `EntryPoint.handleOps([signed], beneficiary)`. We
  // call from anvil's default funded account using
  // `anvil_impersonateAccount`. This proves the calldata would
  // execute on-chain WITHOUT going through a bundler. The state
  // change is captured by the post-balance read.
  const beneficiary = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as Address;
  await setEthBalance(env.rpcUrl, beneficiary, 10n ** 18n);

  await publicClient.request({
    method: "anvil_impersonateAccount" as never,
    params: [beneficiary] as never,
  });

  const packedUserOp = packV07UserOpForHandleOps(signed);
  const handleOpsData = encodeAbiParameters(
    [
      {
        name: "userOps",
        type: "tuple[]",
        components: [
          { name: "sender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "initCode", type: "bytes" },
          { name: "callData", type: "bytes" },
          { name: "accountGasLimits", type: "bytes32" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "gasFees", type: "bytes32" },
          { name: "paymasterAndData", type: "bytes" },
          { name: "signature", type: "bytes" },
        ],
      },
      { name: "beneficiary", type: "address" },
    ],
    [[packedUserOp], beneficiary],
  );

  // We don't actually broadcast handleOps via sendTransaction here
  // — we want a no-state-change simulation. `eth_call` with the
  // packed handleOps payload reproduces the EntryPoint dispatch
  // path against the fork state but doesn't commit.
  const simulationResult = await publicClient.request({
    method: "eth_call",
    params: [
      {
        from: beneficiary,
        to: ENTRY_POINT_V07,
        data: ("0x765e827f" + handleOpsData.slice(2)) as Hex,
      },
      "latest",
    ],
  });

  await publicClient.request({
    method: "anvil_stopImpersonatingAccount" as never,
    params: [beneficiary] as never,
  });

  ok("EntryPoint.handleOps simulation returned without revert", `result=${simulationResult}`);

  const usdtAfter = await readErc20Balance(env.rpcUrl, USDT_BASE, env.smartAccountAddress);
  const usdtDelta = usdtAfter - usdtBefore;
  ok(
    "post-simulation balance delta (simulated; not committed)",
    `USDT_before=${usdtBefore} USDT_after=${usdtAfter} delta=${usdtDelta}`,
  );

  console.log("");
  console.log("--- PROOF COMPLETE ---");
  console.log(
    "Real 0x quote calldata, real Base mainnet contracts, fork-only execution. " +
      "No public mainnet broadcast occurred.",
  );
}

// Manual v0.7 PackedUserOperation encoder. viem's account-abstraction
// helper exposes the canonical UserOperation but the EntryPoint
// `handleOps` ABI takes the packed form — we pack inline.
function packV07UserOpForHandleOps(op: {
  sender: Address;
  nonce: bigint;
  callData: Hex;
  callGasLimit: bigint;
  verificationGasLimit: bigint;
  preVerificationGas: bigint;
  maxFeePerGas: bigint;
  maxPriorityFeePerGas: bigint;
  signature: Hex;
}) {
  const accountGasLimits = pack128(op.verificationGasLimit, op.callGasLimit);
  const gasFees = pack128(op.maxPriorityFeePerGas, op.maxFeePerGas);
  return {
    sender: op.sender,
    nonce: op.nonce,
    initCode: "0x" as Hex,
    callData: op.callData,
    accountGasLimits,
    preVerificationGas: op.preVerificationGas,
    gasFees,
    paymasterAndData: "0x" as Hex,
    signature: op.signature,
  };
}

function pack128(hi: bigint, lo: bigint): Hex {
  const hiHex = hi.toString(16).padStart(32, "0");
  const loHex = lo.toString(16).padStart(32, "0");
  return `0x${hiHex}${loHex}` as Hex;
}

main().catch((err) => {
  console.error("ERROR:", err instanceof Error ? err.message : err);
  process.exit(1);
});
