/**
 * Kernel v3 smart-account provisioning script for Base Sepolia.
 *
 * Two modes:
 *
 *   1. **Dry-run (default).** Pure-local CREATE2 derivation. NO RPC,
 *      NO secrets, NO funded keys. Reads the operator's PUBLIC EOA
 *      address + a salt index, computes the deterministic Kernel v3
 *      smart-account address, and prints a JSON receipt with the
 *      addresses an operator needs (factory, implementation, ECDSA
 *      validator, expected smart-account address).
 *
 *   2. **Broadcast (`--broadcast`).** Real chain interaction. Requires
 *      an RPC URL, a bundler URL, and a funded operator EOA private
 *      key in env. Sends a no-op UserOp through the bundler; the
 *      kernel account is deployed by the EntryPoint as part of the
 *      first UserOp's initCode. Prints the same JSON receipt augmented
 *      with the broadcast result (userOpHash, txHash, blockNumber).
 *
 * The script does not pin a Permission Validator address — there
 * isn't one in ZeroDev's permissions architecture. See
 * `docs/zerodev-permissions-integration.md` for the corrected model.
 * Per-permission install is part of #58 and out of scope here.
 *
 * Env vars (kept out of stdout JSON receipt, except for public
 * addresses):
 *
 *   - `OPERATOR_ADDRESS`     — required, all paths. Public EOA that
 *                              owns the kernel account (kernel root
 *                              ECDSA validator binds to this).
 *   - `KERNEL_ACCOUNT_INDEX` — optional, default 0. Salt for the
 *                              CREATE2 derivation. Same EOA + same
 *                              index ⇒ same kernel address.
 *   - `BASE_CHAIN_ID`        — optional, default 84532 (Sepolia).
 *                              Only 84532 and 8453 (mainnet) accepted.
 *   - `BASE_RPC_URL`         — required only in `--broadcast`.
 *   - `BUNDLER_RPC_URL`      — required only in `--broadcast`. Must
 *                              be an ERC-4337 v0.7 bundler.
 *   - `OPERATOR_PRIVATE_KEY` — required only in `--broadcast`. The
 *                              0x-prefixed hex private key that signs
 *                              the deploy UserOp. Must correspond to
 *                              `OPERATOR_ADDRESS`.
 *
 * Receipt schema is documented in `dryRunReceiptSchemaV1` /
 * `broadcastReceiptSchemaV1`. Operators record the receipt in the
 * deployment journal and feed `expected_smart_account_address` to
 * the adapter env as `SMART_ACCOUNT_ADDRESS`.
 */

import { fileURLToPath, pathToFileURL } from "node:url";
import {
  type Address,
  type Hex,
  createPublicClient,
  getAddress,
  http,
  isAddress,
  isHex,
} from "viem";
import { baseSepolia, base } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import {
  createKernelAccount,
  createKernelAccountClient,
  type CreateKernelAccountReturnType,
} from "@zerodev/sdk";
import {
  getEntryPoint,
  KERNEL_V3_1,
  KernelVersionToAddressesMap,
} from "@zerodev/sdk/constants";
import { isSmartAccountDeployed } from "@zerodev/sdk/actions";
import {
  getKernelAddressFromECDSA,
  getValidatorAddress,
  signerToEcdsaValidator,
} from "@zerodev/ecdsa-validator";

// ---------------------------------------------------------------------------
// Pure types + constants — testable, no side effects.
// ---------------------------------------------------------------------------

/** Schema version emitted in the JSON receipt. */
export const RECEIPT_SCHEMA_VERSION = 1;

/**
 * Pinned kernel version for #84 provisioning. v0.3.1 is what
 * ZeroDev's own examples target and the lowest version in the
 * `>=0.3.1` ECDSA-validator range, so it's the well-trodden default.
 * Operators who need a different version should pin it deliberately
 * (and update this script) rather than discovering the pin
 * accidentally via env.
 */
export const PINNED_KERNEL_VERSION = KERNEL_V3_1;

/** Allowed chain ids — Base Sepolia (default) + Base mainnet. */
export const ALLOWED_CHAIN_IDS = [84_532, 8453] as const;
export type AllowedChainId = (typeof ALLOWED_CHAIN_IDS)[number];

const PLACEHOLDER_PATTERN = /placeholder|0x_/i;

// ---------------------------------------------------------------------------
// Env parsing
// ---------------------------------------------------------------------------

export interface DryRunEnv {
  ownerAddress: Address;
  kernelAccountIndex: bigint;
  baseChainId: AllowedChainId;
}

export interface BroadcastEnv extends DryRunEnv {
  baseRpcUrl: string;
  bundlerRpcUrl: string;
  operatorPrivateKey: Hex;
}

export class ProvisionEnvError extends Error {
  constructor(
    message: string,
    public readonly key?: string,
  ) {
    super(message);
    this.name = "ProvisionEnvError";
  }
}

function readChainId(env: NodeJS.ProcessEnv): AllowedChainId {
  const raw = env.BASE_CHAIN_ID ?? "84532";
  const parsed = Number.parseInt(raw, 10);
  if (!ALLOWED_CHAIN_IDS.includes(parsed as AllowedChainId)) {
    throw new ProvisionEnvError(
      `BASE_CHAIN_ID must be 84532 (Sepolia) or 8453 (mainnet); got ${raw}`,
      "BASE_CHAIN_ID",
    );
  }
  return parsed as AllowedChainId;
}

function readAddress(value: string | undefined, key: string): Address {
  if (value === undefined || value === "") {
    throw new ProvisionEnvError(`${key} is required`, key);
  }
  if (PLACEHOLDER_PATTERN.test(value)) {
    throw new ProvisionEnvError(
      `${key} still contains a placeholder value: ${value}`,
      key,
    );
  }
  if (!isAddress(value)) {
    throw new ProvisionEnvError(
      `${key} must be a 0x-prefixed 20-byte EVM address; got ${value}`,
      key,
    );
  }
  return getAddress(value);
}

function readIndex(env: NodeJS.ProcessEnv): bigint {
  const raw = env.KERNEL_ACCOUNT_INDEX ?? "0";
  try {
    return BigInt(raw);
  } catch {
    throw new ProvisionEnvError(
      `KERNEL_ACCOUNT_INDEX must be a non-negative integer; got ${raw}`,
      "KERNEL_ACCOUNT_INDEX",
    );
  }
}

function readUrl(value: string | undefined, key: string): string {
  if (value === undefined || value === "") {
    throw new ProvisionEnvError(`${key} is required`, key);
  }
  if (PLACEHOLDER_PATTERN.test(value)) {
    throw new ProvisionEnvError(
      `${key} still contains a placeholder value`,
      key,
    );
  }
  if (!/^https?:\/\//.test(value)) {
    throw new ProvisionEnvError(`${key} must be an http(s) URL`, key);
  }
  return value;
}

function readPrivateKey(value: string | undefined, key: string): Hex {
  if (value === undefined || value === "") {
    throw new ProvisionEnvError(`${key} is required`, key);
  }
  if (PLACEHOLDER_PATTERN.test(value)) {
    throw new ProvisionEnvError(
      `${key} still contains a placeholder value`,
      key,
    );
  }
  if (!isHex(value) || value.length !== 66) {
    throw new ProvisionEnvError(
      `${key} must be a 0x-prefixed 32-byte hex private key`,
      key,
    );
  }
  return value;
}

export function parseDryRunEnv(env: NodeJS.ProcessEnv): DryRunEnv {
  return {
    ownerAddress: readAddress(env.OPERATOR_ADDRESS, "OPERATOR_ADDRESS"),
    kernelAccountIndex: readIndex(env),
    baseChainId: readChainId(env),
  };
}

export function parseBroadcastEnv(env: NodeJS.ProcessEnv): BroadcastEnv {
  const dryRun = parseDryRunEnv(env);
  const operatorPrivateKey = readPrivateKey(
    env.OPERATOR_PRIVATE_KEY,
    "OPERATOR_PRIVATE_KEY",
  );
  // Defense in depth: refuse to broadcast if the configured EOA does
  // not match the public OPERATOR_ADDRESS. Catches paste-mismatches
  // before they hit the bundler.
  const derived = privateKeyToAccount(operatorPrivateKey).address;
  if (getAddress(derived) !== dryRun.ownerAddress) {
    throw new ProvisionEnvError(
      `OPERATOR_PRIVATE_KEY does not match OPERATOR_ADDRESS (key derives ${derived}, env says ${dryRun.ownerAddress})`,
      "OPERATOR_PRIVATE_KEY",
    );
  }
  return {
    ...dryRun,
    baseRpcUrl: readUrl(env.BASE_RPC_URL, "BASE_RPC_URL"),
    bundlerRpcUrl: readUrl(env.BUNDLER_RPC_URL, "BUNDLER_RPC_URL"),
    operatorPrivateKey,
  };
}

// ---------------------------------------------------------------------------
// Pure derivation — zero RPC, zero secrets, deterministic.
// ---------------------------------------------------------------------------

export interface KernelAddresses {
  kernelVersion: string;
  factoryAddress: Address;
  metaFactoryAddress: Address;
  accountImplementationAddress: Address;
  initCodeHash: Hex;
}

export function getKernelAddresses(): KernelAddresses {
  // KernelVersionToAddressesMap is keyed by the literal version
  // string (e.g. "0.3.1"); KERNEL_V3_1 is that literal.
  const entry = KernelVersionToAddressesMap[PINNED_KERNEL_VERSION];
  if (!entry) {
    throw new Error(
      `KernelVersionToAddressesMap missing entry for ${String(PINNED_KERNEL_VERSION)}`,
    );
  }
  return {
    kernelVersion: PINNED_KERNEL_VERSION,
    factoryAddress: entry.factoryAddress,
    metaFactoryAddress: entry.metaFactoryAddress,
    accountImplementationAddress: entry.accountImplementationAddress,
    initCodeHash: entry.initCodeHash,
  };
}

export function getRootEcdsaValidatorAddress(): Address {
  // Pure helper — no client, no RPC. Resolves the well-known
  // ECDSA-validator deployment for `>=0.3.1` (it is the same
  // address on every chain via CREATE2).
  return getValidatorAddress(getEntryPoint("0.7"), PINNED_KERNEL_VERSION);
}

export async function deriveExpectedKernelAddress(
  env: DryRunEnv,
): Promise<Address> {
  const { initCodeHash } = getKernelAddresses();
  // Passing initCodeHash makes this fully local — no publicClient,
  // no RPC. Verified against the ZeroDev SDK source path
  // node_modules/@zerodev/ecdsa-validator/_esm/getAddress.js.
  return await getKernelAddressFromECDSA({
    entryPoint: getEntryPoint("0.7"),
    kernelVersion: PINNED_KERNEL_VERSION,
    eoaAddress: env.ownerAddress,
    index: env.kernelAccountIndex,
    initCodeHash,
  });
}

// ---------------------------------------------------------------------------
// Receipt schemas
// ---------------------------------------------------------------------------

export interface DryRunReceipt {
  schema_version: typeof RECEIPT_SCHEMA_VERSION;
  mode: "dry-run";
  chain_id: AllowedChainId;
  kernel_version: string;
  factory_address: Address;
  meta_factory_address: Address;
  account_implementation_address: Address;
  ecdsa_validator_address: Address;
  init_code_hash: Hex;
  owner_address: Address;
  kernel_account_index: string;
  expected_smart_account_address: Address;
  next_steps: string[];
}

export interface BroadcastReceipt extends Omit<DryRunReceipt, "mode"> {
  mode: "broadcast";
  user_op_hash: Hex;
  transaction_hash: Hex;
  block_number: number;
  bundler_url_host: string; // host only, never the full URL (may carry API keys)
}

export function buildDryRunReceipt(
  env: DryRunEnv,
  expectedSmartAccountAddress: Address,
): DryRunReceipt {
  const addrs = getKernelAddresses();
  return {
    schema_version: RECEIPT_SCHEMA_VERSION,
    mode: "dry-run",
    chain_id: env.baseChainId,
    kernel_version: addrs.kernelVersion,
    factory_address: addrs.factoryAddress,
    meta_factory_address: addrs.metaFactoryAddress,
    account_implementation_address: addrs.accountImplementationAddress,
    ecdsa_validator_address: getRootEcdsaValidatorAddress(),
    init_code_hash: addrs.initCodeHash,
    owner_address: env.ownerAddress,
    kernel_account_index: env.kernelAccountIndex.toString(),
    expected_smart_account_address: expectedSmartAccountAddress,
    next_steps: [
      "1. Fund the OPERATOR_ADDRESS EOA on Base Sepolia (faucet).",
      "2. Re-run with --broadcast to deploy via the bundler. The same OPERATOR_ADDRESS must sign.",
      "3. Set SMART_ACCOUNT_ADDRESS on the adapter host to expected_smart_account_address.",
      "4. The ZeroDev permissions integration (per-permission install + cryptographic revoke) is tracked in docs/zerodev-permissions-integration.md and is NOT part of this script.",
    ],
  };
}

function bundlerHost(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return "unknown";
  }
}

export function buildBroadcastReceipt(
  base: DryRunReceipt,
  args: {
    userOpHash: Hex;
    transactionHash: Hex;
    blockNumber: number;
    bundlerRpcUrl: string;
  },
): BroadcastReceipt {
  return {
    ...base,
    mode: "broadcast",
    user_op_hash: args.userOpHash,
    transaction_hash: args.transactionHash,
    block_number: args.blockNumber,
    bundler_url_host: bundlerHost(args.bundlerRpcUrl),
  };
}

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

export interface ParsedCli {
  broadcast: boolean;
  help: boolean;
}

export function parseCli(argv: string[]): ParsedCli {
  const broadcast = argv.includes("--broadcast");
  const help = argv.includes("--help") || argv.includes("-h");
  return { broadcast, help };
}

const HELP_TEXT = `Usage:

  npx tsx scripts/provision-kernel.ts                # dry-run (default)
  npx tsx scripts/provision-kernel.ts --broadcast    # deploy on chain

Required env (always):
  OPERATOR_ADDRESS         Public EOA address that owns the kernel account.
  KERNEL_ACCOUNT_INDEX     Optional. Salt index (default 0).
  BASE_CHAIN_ID            Optional. 84532 (Sepolia, default) or 8453 (mainnet).

Required env (--broadcast only):
  BASE_RPC_URL             Base RPC endpoint (https://...).
  BUNDLER_RPC_URL          ERC-4337 v0.7 bundler endpoint (https://...).
  OPERATOR_PRIVATE_KEY     0x-prefixed 32-byte hex; must derive to OPERATOR_ADDRESS.

Output:
  A JSON receipt on stdout. See dryRunReceiptSchemaV1 /
  broadcastReceiptSchemaV1 in scripts/provision-kernel.ts.

The dry-run path makes NO RPC calls and reads NO secrets. The
script writes nothing to disk.`;

// ---------------------------------------------------------------------------
// Broadcast path — RPC + bundler + signed UserOp.
// ---------------------------------------------------------------------------

interface BroadcastResult {
  userOpHash: Hex;
  transactionHash: Hex;
  blockNumber: number;
}

async function broadcastDeploy(env: BroadcastEnv): Promise<BroadcastResult> {
  const chain = env.baseChainId === 84_532 ? baseSepolia : base;
  const publicClient = createPublicClient({
    chain,
    transport: http(env.baseRpcUrl),
  });

  // Refuse to redeploy. The kernel account is deterministic by
  // (owner, factory, index); if it already has bytecode the operator
  // doesn't need a deploy UserOp — they need to skip to setting
  // SMART_ACCOUNT_ADDRESS.
  const expectedAddress = await deriveExpectedKernelAddress(env);
  // viem's `createPublicClient` returns a `PublicClient` whose
  // generic-parameterised type drifts between the version we depend
  // on directly and the version `@zerodev/sdk` was compiled
  // against. `isSmartAccountDeployed` accepts a bare `Client`, which
  // both types satisfy structurally; the cast is at the type
  // boundary and does not alter runtime behaviour.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const sdkClient = publicClient as any;
  const alreadyDeployed = await isSmartAccountDeployed(
    sdkClient,
    expectedAddress,
  );
  if (alreadyDeployed) {
    throw new ProvisionEnvError(
      `Kernel account ${expectedAddress} is already deployed on chain ${env.baseChainId}; nothing to broadcast.`,
    );
  }

  const signer = privateKeyToAccount(env.operatorPrivateKey);
  const ecdsaValidator = await signerToEcdsaValidator(sdkClient, {
    signer,
    entryPoint: getEntryPoint("0.7"),
    kernelVersion: PINNED_KERNEL_VERSION,
  });
  const account: CreateKernelAccountReturnType<"0.7"> = await createKernelAccount(
    sdkClient,
    {
      plugins: { sudo: ecdsaValidator },
      entryPoint: getEntryPoint("0.7"),
      kernelVersion: PINNED_KERNEL_VERSION,
      index: env.kernelAccountIndex,
      // We already derived this off-chain; passing it skips the
      // EntryPoint.getSenderAddress RPC roundtrip.
      address: expectedAddress,
    },
  );

  const kernelClient = createKernelAccountClient({
    account,
    chain,
    bundlerTransport: http(env.bundlerRpcUrl),
  });

  // Trivial deploy: a no-op self-call. The bundler picks up the
  // initCode from the kernel account and deploys via EntryPoint.
  // The `kernelClient.sendUserOperation` runtime auto-fills gas /
  // nonce from the bundler; the SDK's published types still demand
  // them as required, so the call site is cast to keep
  // typecheck:scripts honest about what's actually being sent.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const sender = kernelClient.sendUserOperation as (args: {
    callData: Hex;
  }) => Promise<Hex>;
  const userOpHash = await sender({
    callData: await account.encodeCalls([
      { to: account.address, value: 0n, data: "0x" },
    ]),
  });
  const receipt = await kernelClient.waitForUserOperationReceipt({
    hash: userOpHash,
  });

  return {
    userOpHash,
    transactionHash: receipt.receipt.transactionHash as Hex,
    blockNumber: Number(receipt.receipt.blockNumber),
  };
}

// ---------------------------------------------------------------------------
// CLI entry
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const cli = parseCli(process.argv.slice(2));
  if (cli.help) {
    process.stdout.write(HELP_TEXT + "\n");
    return;
  }

  if (cli.broadcast) {
    const env = parseBroadcastEnv(process.env);
    const expectedAddress = await deriveExpectedKernelAddress(env);
    const dryRun = buildDryRunReceipt(env, expectedAddress);
    const broadcast = await broadcastDeploy(env);
    const receipt = buildBroadcastReceipt(dryRun, {
      ...broadcast,
      bundlerRpcUrl: env.bundlerRpcUrl,
    });
    process.stdout.write(JSON.stringify(receipt, null, 2) + "\n");
    return;
  }

  const env = parseDryRunEnv(process.env);
  const expectedAddress = await deriveExpectedKernelAddress(env);
  const receipt = buildDryRunReceipt(env, expectedAddress);
  process.stdout.write(JSON.stringify(receipt, null, 2) + "\n");
}

const invokedDirectly =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) {
  main().catch((err: unknown) => {
    if (err instanceof ProvisionEnvError) {
      process.stderr.write(`provision-kernel: ${err.message}\n`);
    } else {
      const msg = err instanceof Error ? err.message : String(err);
      process.stderr.write(`provision-kernel: ${msg}\n`);
    }
    process.exit(1);
  });
}

// Make `fileURLToPath` available as an export so the CLI guard can
// be tested on different platforms; otherwise unused at runtime.
export const _internal = { fileURLToPath };
